import AppKit
import Combine
import Foundation
import Photos
import Security
import SwiftUI

@MainActor
final class PhotoBackupViewModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case originals, edited, both
        var id: String { rawValue }
    }

    enum Media: String, CaseIterable, Identifiable {
        case all, images, videos
        var id: String { rawValue }
    }

    enum Order: String, CaseIterable, Identifiable {
        case oldest, newest
        var id: String { rawValue }
    }

    enum DestinationMode: String, CaseIterable, Identifiable {
        case folder
        case immich
        case both
        var id: String { rawValue }
    }

    enum SourceMode: String, CaseIterable, Identifiable {
        case photos
        case files
        case both
        var id: String { rawValue }
    }

    enum AlbumSource: String, CaseIterable, Identifiable {
        case allPhotos
        case selectedAlbums
        var id: String { rawValue }
    }

    enum BackupModeUI: String, CaseIterable, Identifiable {
        case smartIncremental
        case full
        case mirror
        var id: String { rawValue }

        var coreValue: BackupMode {
            switch self {
            case .smartIncremental: return .smartIncremental
            case .full: return .full
            case .mirror: return .mirror
            }
        }
    }

    enum LibraryScope: String, CaseIterable, Identifiable {
        case personalOnly
        case personalAndShared
        case sharedOnly
        var id: String { rawValue }

        var coreValue: PhotoBackupOptions.LibraryScope {
            PhotoBackupOptions.LibraryScope(rawValue: rawValue) ?? .personalOnly
        }
    }

    struct AlbumRow: Identifiable, Hashable {
        var id: String { localIdentifier }
        let localIdentifier: String
        let title: String
        let estimatedCount: Int
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let text: String
    }

    struct FailedUploadRecord: Codable {
        let savedAt: Date
        let deviceId: String
        let deviceAssetId: String
        let phAssetLocalIdentifier: String?
        let filename: String
        let fileCreatedAt: Date
        let fileModifiedAt: Date
        let durationSeconds: Double?
        let isFavorite: Bool?
        let livePhotoVideoId: String?
        let metadataJSON: Data
        let errorDescription: String
    }

    @Published var destinationMode: DestinationMode = .immich
    @Published var sourceMode: SourceMode = .photos
    @Published var destinationPath: String = ""
    @Published var mode: Mode = .originals
    @Published var media: Media = .all
    @Published var order: Order = .oldest
    @Published var albumSource: AlbumSource = .allPhotos
    @Published var selectedAlbumIds: Set<String> = []
    @Published private(set) var availableAlbums: [AlbumRow] = []
    @Published var showAlbumPicker: Bool = false
    @Published var backupMode: BackupModeUI = .smartIncremental
    @Published var libraryScope: LibraryScope = .personalOnly
    @Published var includeAdjustmentData: Bool = true
    @Published var allowNetwork: Bool = true
    @Published var dryRun: Bool = false
    @Published var limit: Int? = nil
    @Published var timeoutSeconds: Double = 300

    @Published var immichServerURL: String = ""
    @Published var immichApiKey: String = ""
    @Published private(set) var immichDeviceId: String = ""
    @Published var immichUploadConcurrency: Int = 1
    @Published private(set) var immichTestStatus: String = "Not tested"
    @Published private(set) var immichIsConnected: Bool = false
    @Published var showImmichConnectionError: Bool = false
    @Published var immichConnectionErrorMessage: String = ""
    @Published var showLocalNetworkPermissionNeeded: Bool = false
    @Published var immichSyncAlbums: Bool = false
    @Published var immichUpdateChangedAssets: Bool = false

    @Published private(set) var photosIsConnected: Bool = false
    @Published private(set) var photosConnectionText: String = "Checking…"
    @Published var shouldShowSetupWizard: Bool = false

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var statusText: String = "Idle"
    @Published private(set) var progressValue: Double = 0
    @Published private(set) var progressTotal: Double = 0
    @Published private(set) var logLines: [LogLine] = []
    @Published private(set) var errorLines: [LogLine] = []
    @Published private(set) var thumbnail: NSImage? = nil
    @Published private(set) var thumbnailCaption: String = ""
    @Published private(set) var currentAssetName: String = ""
    @Published private(set) var uploadedCount: Int = 0
    @Published private(set) var skippedCount: Int = 0
    @Published private(set) var errorCount: Int = 0
    @Published private(set) var failedUploadCount: Int = 0
    @Published private(set) var isExportingFailedUploads: Bool = false
    @Published private(set) var immichExistChecked: Int = 0
    @Published private(set) var immichExistTotal: Int = 0
    @Published private(set) var immichSyncInProgress: Bool = false
    @Published private(set) var lastDryRunPlan: DryRunPlan? = nil

    // iCloud download state
    @Published private(set) var isDownloadingFromiCloud: Bool = false
    @Published private(set) var iCloudDownloadAssetName: String = ""
    @Published private(set) var iCloudDownloadProgress: Double = 0
    @Published private(set) var iCloudDownloadAttempt: Int = 1
    private var iCloudDownloadStartTime: Date?

    // Pause/Resume state
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var hasResumableSession: Bool = false
    @Published private(set) var resumableSessionInfo: String = ""

    private let exporter = PhotoBackupExporter()
    private let runState = ManagedBackupRunState()
    private var runningTask: Task<Void, Never>?
    private var currentSessionState: BackupSessionState?
    private var imagesSeen: Int = 0
    private var didShowFirstThumbnail: Bool = false
    private var lastThumbnailRequestId: PHImageRequestID?
    private var skippedAssetIds: Set<String> = []  // Track asset-level skips (not file-level)
    private var countedImmichUploadErrorAssetIds: Set<String> = []
    private var currentFailedUploadsDir: URL? = nil
    private var logBuffer: [LogLine] = []
    private var logFlushTask: Task<Void, Never>?
    private var isLogVisible: Bool = false

    private let defaults = UserDefaults.standard
    private let keychain = KeychainStore(service: "com.emerysilb.immibridge")

    // Security-scoped bookmarks (MAS-friendly)
    @Published private(set) var folderDestinationBookmark: Data? = nil
    @Published private(set) var customFolderBookmarks: [Data] = []
    @Published private(set) var customFolderPaths: [String] = []

    init() {
        immichServerURL = defaults.string(forKey: "immichServerURL") ?? ""
        immichApiKey = keychain.get(account: "immichApiKey") ?? ""
        let storedConcurrency = defaults.integer(forKey: "immichUploadConcurrency")
        if storedConcurrency > 0 {
            immichUploadConcurrency = storedConcurrency
        }

        if let raw = defaults.string(forKey: "destinationMode"),
           let v = DestinationMode(rawValue: raw) {
            destinationMode = v
        }
        if let raw = defaults.string(forKey: "sourceMode"),
           let v = SourceMode(rawValue: raw) {
            sourceMode = v
        }
        if let raw = defaults.string(forKey: "mode"),
           let v = Mode(rawValue: raw) {
            mode = v
        }
        if let raw = defaults.string(forKey: "media"),
           let v = Media(rawValue: raw) {
            media = v
        }
        if let raw = defaults.string(forKey: "order"),
           let v = Order(rawValue: raw) {
            order = v
        }
        destinationPath = defaults.string(forKey: "destinationPath") ?? ""
        folderDestinationBookmark = defaults.data(forKey: "folderDestinationBookmark")
        if let raw = defaults.string(forKey: "albumSource"),
           let v = AlbumSource(rawValue: raw) {
            albumSource = v
        }
        if let ids = defaults.array(forKey: "selectedAlbumIds") as? [String] {
            selectedAlbumIds = Set(ids)
        }
        immichSyncAlbums = defaults.bool(forKey: "immichSyncAlbums")
        immichUpdateChangedAssets = defaults.bool(forKey: "immichUpdateChangedAssets")

        if let raw = defaults.string(forKey: "backupMode"),
           let v = BackupModeUI(rawValue: raw) {
            backupMode = v
        }
        if let raw = defaults.string(forKey: "libraryScope"),
           let v = LibraryScope(rawValue: raw) {
            libraryScope = v
        } else {
            // Backwards-compat: migrate old bool
            let old = defaults.bool(forKey: "includeSharedAlbums")
            libraryScope = old ? .personalAndShared : .personalOnly
        }
        includeAdjustmentData = defaults.object(forKey: "includeAdjustmentData") as? Bool ?? true

        if let arr = defaults.array(forKey: "customFolderBookmarks") as? [Data] {
            customFolderBookmarks = arr
        }
        if let arr = defaults.array(forKey: "customFolderPaths") as? [String] {
            customFolderPaths = arr
        }

        if let id = defaults.string(forKey: "immichDeviceId"), !id.isEmpty {
            immichDeviceId = id
        } else {
            let id = UUID().uuidString
            defaults.set(id, forKey: "immichDeviceId")
            immichDeviceId = id
        }

        // Check if first run - show setup wizard if never completed
        if !defaults.bool(forKey: "hasCompletedSetupWizard") {
            shouldShowSetupWizard = true
        }

        // Only auto-request photos permission if not showing wizard
        refreshPhotosAuthorizationStatus(autoRequest: !shouldShowSetupWizard)
        refreshAlbumsIfPossible()
    }

    func completeSetupWizard() {
        defaults.set(true, forKey: "hasCompletedSetupWizard")
        shouldShowSetupWizard = false
    }

    func refreshPhotosAuthorizationStatus(autoRequest: Bool = false) {
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch auth {
        case .authorized, .limited:
            photosIsConnected = true
            photosConnectionText = "Connected (Library)"
        case .notDetermined:
            photosIsConnected = false
            photosConnectionText = "Permission Needed"
            if autoRequest {
                requestPhotosAccess()
            }
        case .denied, .restricted:
            photosIsConnected = false
            photosConnectionText = "No Access"
        @unknown default:
            photosIsConnected = false
            photosConnectionText = "Unknown"
        }
    }

    func requestPhotosAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPhotosAuthorizationStatus()
                self?.refreshAlbumsIfPossible()
            }
        }
    }

    func refreshAlbumsIfPossible() {
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited else {
            availableAlbums = []
            return
        }

        var rows: [AlbumRow] = []
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        rows.reserveCapacity(collections.count)
        collections.enumerateObjects { collection, _, _ in
            let title = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let albumTitle = (title?.isEmpty == false) ? title! : "Untitled Album"
            let count = collection.estimatedAssetCount
            rows.append(AlbumRow(localIdentifier: collection.localIdentifier, title: albumTitle, estimatedCount: max(0, count)))
        }
        rows.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        availableAlbums = rows
    }

    func openPhotosPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    func setDestinationPath(_ newValue: String) {
        destinationPath = newValue
        defaults.set(destinationPath, forKey: "destinationPath")
    }

    private func setFolderDestination(url: URL) {
        setDestinationPath(url.path)
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            folderDestinationBookmark = data
            defaults.set(data, forKey: "folderDestinationBookmark")
        }
    }

    func setImmichServerURL(_ newValue: String) {
        immichServerURL = newValue
        defaults.set(immichServerURL, forKey: "immichServerURL")
    }

    func normalizeImmichURL() {
        let normalized = normalizeImmichBaseURLString(immichServerURL)
        if !normalized.isEmpty && normalized != immichServerURL {
            immichServerURL = normalized
            defaults.set(immichServerURL, forKey: "immichServerURL")
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            setFolderDestination(url: url)
        }
    }

    func addCustomFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            for url in panel.urls {
                guard let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { continue }
                customFolderBookmarks.append(data)
                customFolderPaths.append(url.path)
            }
            defaults.set(customFolderBookmarks, forKey: "customFolderBookmarks")
            defaults.set(customFolderPaths, forKey: "customFolderPaths")
        }
    }

    func removeCustomFolder(at index: Int) {
        guard index >= 0, index < customFolderBookmarks.count, index < customFolderPaths.count else { return }
        customFolderBookmarks.remove(at: index)
        customFolderPaths.remove(at: index)
        defaults.set(customFolderBookmarks, forKey: "customFolderBookmarks")
        defaults.set(customFolderPaths, forKey: "customFolderPaths")
    }

    func clearCustomFolders() {
        customFolderBookmarks = []
        customFolderPaths = []
        defaults.set(customFolderBookmarks, forKey: "customFolderBookmarks")
        defaults.set(customFolderPaths, forKey: "customFolderPaths")
    }

    private final class SecurityScopedAccess {
        private var urls: [URL] = []

        func add(_ url: URL) {
            if url.startAccessingSecurityScopedResource() {
                urls.append(url)
            }
        }

        func stopAll() {
            for u in urls { u.stopAccessingSecurityScopedResource() }
            urls.removeAll()
        }

        deinit { stopAll() }
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            if folderDestinationBookmark == data {
                folderDestinationBookmark = fresh
                defaults.set(fresh, forKey: "folderDestinationBookmark")
            }
        }
        return url
    }

    var canStart: Bool {
        if isRunning { return false }
        if sourceMode == .photos || sourceMode == .both {
            if albumSource == .selectedAlbums, selectedAlbumIds.isEmpty { return false }
        }
        switch destinationMode {
        case .folder:
            if destinationPath.isEmpty { return false }
            if sourceMode == .files { return !customFolderPaths.isEmpty }
            return true
        case .immich:
            if immichServerURL.isEmpty || immichApiKey.isEmpty { return false }
            if sourceMode == .files { return !customFolderPaths.isEmpty }
            return true
        case .both:
            if destinationPath.isEmpty || immichServerURL.isEmpty || immichApiKey.isEmpty { return false }
            if sourceMode == .files { return !customFolderPaths.isEmpty }
            return true
        }
    }

    var canStartFolderOnly: Bool {
        !isRunning && !destinationPath.isEmpty
    }

    var canStartImmichOnly: Bool {
        !isRunning && !immichServerURL.isEmpty && !immichApiKey.isEmpty
    }

    var canStartBoth: Bool {
        !isRunning && !destinationPath.isEmpty && !immichServerURL.isEmpty && !immichApiKey.isEmpty
    }

    func startFolderExport() {
        destinationMode = .folder
        start()
    }

    func startImmichUpload() {
        destinationMode = .immich
        start()
    }

    func startBoth() {
        destinationMode = .both
        start()
    }

    func start() {
        // Clear any old session when starting fresh
        clearSessionState()
        startWithSession(nil)
    }

    func startDryRun() {
        // Do not clear any resumable session state; this is a plan-only preview.
        dryRun = true
        startWithSession(nil)
    }

    private func startWithSession(_ session: BackupSessionState?) {
        guard canStart else { return }
        isRunning = true
        isPaused = false
        runState.store(.running)
        progressValue = 0
        progressTotal = 0
        statusText = session != nil ? "Resuming…" : "Starting…"
        logLines = []
        logBuffer = []
        errorLines = []
        thumbnail = nil
        thumbnailCaption = ""
        currentAssetName = ""
        imagesSeen = 0
        didShowFirstThumbnail = false

        // Restore counters from session or reset
        if let session = session {
            uploadedCount = session.stats.uploadedCount
            skippedCount = session.stats.skippedCount
            errorCount = session.stats.errorCount
            skippedAssetIds = session.processedAssetIds  // Don't re-count assets from previous session
        } else {
            uploadedCount = 0
            skippedCount = 0
            errorCount = 0
            skippedAssetIds = []
        }
        immichExistChecked = 0
        immichExistTotal = 0
        immichSyncInProgress = false
        lastDryRunPlan = nil

        let normalizedImmichURL = normalizeImmichBaseURLString(immichServerURL)
        if normalizedImmichURL != immichServerURL {
            immichServerURL = normalizedImmichURL
        }

        defaults.set(destinationMode.rawValue, forKey: "destinationMode")
        defaults.set(sourceMode.rawValue, forKey: "sourceMode")
        defaults.set(mode.rawValue, forKey: "mode")
        defaults.set(media.rawValue, forKey: "media")
        defaults.set(order.rawValue, forKey: "order")
        defaults.set(destinationPath, forKey: "destinationPath")
        defaults.set(backupMode.rawValue, forKey: "backupMode")
        defaults.set(libraryScope.rawValue, forKey: "libraryScope")
        defaults.set(includeAdjustmentData, forKey: "includeAdjustmentData")
        defaults.set(immichServerURL, forKey: "immichServerURL")
        defaults.set(immichUploadConcurrency, forKey: "immichUploadConcurrency")
        defaults.set(albumSource.rawValue, forKey: "albumSource")
        defaults.set(Array(selectedAlbumIds), forKey: "selectedAlbumIds")
        defaults.set(immichSyncAlbums, forKey: "immichSyncAlbums")
        defaults.set(immichUpdateChangedAssets, forKey: "immichUpdateChangedAssets")
        keychain.set(immichApiKey, account: "immichApiKey")

        let sortOrder: PhotoBackupOptions.SortOrder = (order == .oldest) ? .oldestFirst : .newestFirst

        // Build config snapshot for session state
        let configSnapshot = BackupConfigSnapshot(
            mode: mode.rawValue,
            media: media.rawValue,
            sortOrder: order.rawValue,
            immichServerURL: immichServerURL.isEmpty ? nil : immichServerURL,
            immichDeviceId: immichDeviceId.isEmpty ? nil : immichDeviceId,
            folderDestination: destinationPath.isEmpty ? nil : destinationPath
        )

        // Create or use existing session
        let sessionToUse = session ?? BackupSessionState(
            sessionId: UUID().uuidString,
            startedAt: Date(),
            lastUpdatedAt: Date(),
            configSnapshot: configSnapshot
        )
        currentSessionState = sessionToUse

        let folderExport: FolderExportOptions?
        switch destinationMode {
        case .folder, .both:
            if let b = folderDestinationBookmark, let url = resolveBookmark(b) {
                folderExport = FolderExportOptions(destination: url)
            } else {
                folderExport = FolderExportOptions(destination: URL(fileURLWithPath: destinationPath, isDirectory: true))
            }
        case .immich:
            folderExport = nil
        }

        let immichUpload: ImmichUploadOptions?
        switch destinationMode {
        case .immich, .both:
            if let url = URL(string: immichServerURL) {
                let needsPrecheck = immichSyncAlbums || immichUpdateChangedAssets
                immichUpload = ImmichUploadOptions(
                    serverURL: url,
                    apiKey: immichApiKey,
                    deviceId: immichDeviceId,
                    checksumPrecheck: needsPrecheck,
                    skipHash: false,          // Always hash for safe duplicate detection
                    uploadConcurrency: immichUploadConcurrency,
                    hashConcurrency: immichUploadConcurrency,
                    syncAlbums: immichSyncAlbums,
                    updateChangedAssets: immichUpdateChangedAssets
                )
            } else {
                immichUpload = nil
            }
        case .folder:
            immichUpload = nil
        }

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let tempDir = caches.appendingPathComponent("com.local.iphoto-backup-ui/tmp", isDirectory: true)
        let failedUploadsDir = failedUploadsDirectoryURL().appendingPathComponent(sessionToUse.sessionId, isDirectory: true)
        currentFailedUploadsDir = failedUploadsDir
        try? FileManager.default.createDirectory(at: failedUploadsDir, withIntermediateDirectories: true, attributes: nil)
        failedUploadCount = countFailedUploadRecords(in: failedUploadsDir)

        countedImmichUploadErrorAssetIds = []
        errorLines = []
        let albumScope: PhotoBackupOptions.AlbumScope = {
            switch albumSource {
            case .allPhotos:
                return .allPhotos
            case .selectedAlbums:
                return .selectedAlbums(localIdentifiers: Array(selectedAlbumIds))
            }
        }()
        let photoOptions = PhotoBackupOptions(
            folderExport: folderExport,
            immichUpload: immichUpload,
            tempDir: tempDir,
            failedUploadsDir: failedUploadsDir,
            backupMode: backupMode.coreValue,
            mode: PhotoBackupOptions.Mode(rawValue: mode.rawValue) ?? .originals,
            media: PhotoBackupOptions.Media(rawValue: media.rawValue) ?? .all,
            sortOrder: sortOrder,
            limit: limit,
            dryRun: dryRun,
            since: nil,
            albumScope: albumScope,
            libraryScope: libraryScope.coreValue,
            includeAdjustmentData: includeAdjustmentData,
            networkAccessAllowed: allowNetwork,
            requestTimeoutSeconds: timeoutSeconds,
            collisionPolicy: .skipIdenticalElseRename
        )

        // Capture references for the detached task
        let runStateRef = runState
        let customBookmarks = customFolderBookmarks
        let backupModeValue = backupMode.coreValue
        let dryRunValue = dryRun
        let timeoutValue = timeoutSeconds
        let sourceModeValue = sourceMode
        let immichUploadConfig = immichUpload
        runningTask = Task.detached(priority: .userInitiated) { [exporter, photoOptions, folderExport, session, sessionToUse, runStateRef, customBookmarks, backupModeValue, dryRunValue, timeoutValue, sourceModeValue, immichUploadConfig, weak self] in
            // Capture self once at the start for Swift 6 compatibility
            let weakSelf = self

            do {
                let result: PhotoBackupResult
                if sourceModeValue == .files {
                    result = PhotoBackupResult(attemptedAssets: 0, completedAssets: 0, skippedAssets: 0, errorCount: 0, wasPaused: false)
                } else {
                    result = try exporter.export(
                        options: photoOptions,
                        progress: { event in
                            Task { @MainActor in
                                weakSelf?.handleProgress(event)
                            }
                        },
                        runState: {
                            runStateRef.load()
                        },
                        sessionState: session
                    )
                }

                var fileSummary: String? = nil
                if !result.wasPaused,
                   runStateRef.load() != .cancelled,
                   sourceModeValue != .photos,
                   !customBookmarks.isEmpty
                {
                    final class ScopedAccess {
                        private var urls: [URL] = []
                        func add(_ url: URL) { if url.startAccessingSecurityScopedResource() { urls.append(url) } }
                        deinit { for u in urls { u.stopAccessingSecurityScopedResource() } }
                    }

                    func resolve(_ data: Data) -> URL? {
                        var stale = false
                        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                    }

                    let access = ScopedAccess()
                    if let dest = folderExport?.destination { access.add(dest) }

                    var sources: [URL] = []
                    for data in customBookmarks {
                        if let url = resolve(data) {
                            access.add(url)
                            sources.append(url)
                        }
                    }

                    if !sources.isEmpty {
                        Task { @MainActor in
                            weakSelf?.appendLog("Files: starting backup of \(sources.count) folder(s)…")
                        }

                        // Folder destination copy (optional)
                        if let dest = folderExport?.destination {
                            let manifestURL = dest
                                .appendingPathComponent(".immibridge", isDirectory: true)
                                .appendingPathComponent("manifest.sqlite", isDirectory: false)
                            if let manifest = try? ManifestStore(sqliteURL: manifestURL) {
                                let fileOpts = FileBackupOptions(
                                    sources: sources,
                                    destination: dest,
                                    mode: backupModeValue,
                                    includeHiddenFiles: false,
                                    followSymlinks: false,
                                    dryRun: dryRunValue,
                                    requestTimeoutSeconds: timeoutValue
                                )
                                let fileExporter = FileBackupExporter()
                                let fileResult = fileExporter.run(
                                    options: fileOpts,
                                    manifest: manifest,
                                    runId: UUID().uuidString,
                                    progress: { event in
                                        Task { @MainActor in
                                            weakSelf?.handleProgress(event)
                                        }
                                    },
                                    runState: {
                                        runStateRef.load()
                                    }
                                )
                                fileSummary = "Files: copied \(fileResult.copiedFiles), skipped \(fileResult.skippedFiles), deleted \(fileResult.deletedFiles), errors \(fileResult.errorCount)"
                                Task { @MainActor in
                                    weakSelf?.appendLog(fileSummary!)
                                }
                            } else {
                                Task { @MainActor in
                                    weakSelf?.appendLog("ERROR Files: could not open manifest; skipping folder file backup.")
                                }
                            }
                        }

                        // Immich sync for files (optional)
                        if let immichUpload = immichUploadConfig {
                            let syncer = FileImmichSyncer()
                            let fileImmich = FileImmichSyncOptions(
                                sources: sources,
                                immich: immichUpload,
                                updateChanged: immichUpload.updateChangedAssets,
                                requestTimeoutSeconds: timeoutValue,
                                includeHiddenFiles: false,
                                followSymlinks: false,
                                dryRun: dryRunValue
                            )
                            let r = syncer.run(
                                options: fileImmich,
                                progress: { event in
                                    Task { @MainActor in weakSelf?.handleProgress(event) }
                                },
                                runState: {
                                    runStateRef.load()
                                }
                            )
                            Task { @MainActor in
                                weakSelf?.appendLog("Immich Files: uploaded \(r.uploadedFiles), skipped \(r.skippedExisting), replaced \(r.replacedFiles), errors \(r.errorCount)")
                            }
                        }
                    }
                }

                let fileSummaryConst = fileSummary
                await MainActor.run { [weakSelf] in
                    guard let self = weakSelf else { return }

                    // Prefer the core result’s count when it is larger (it includes pipeline-level errors
                    // that might not map 1:1 to log lines), while preserving file-backup errors.
                    self.errorCount = max(self.errorCount, result.errorCount)
                    self.failedUploadCount = self.countFailedUploadRecords(in: self.currentFailedUploadsDir)

                    if dryRunValue, let plan = result.dryRunPlan {
                        self.lastDryRunPlan = plan
                        // Reuse the existing summary counters area for the dry-run results.
                        // Note: these counts are "upload items" (still/video/edited), not Photos asset count.
                        self.uploadedCount = max(0, plan.immichPlannedUploads - plan.immichWouldSkipExisting - plan.immichWouldReplaceExisting)
                        self.skippedCount = plan.immichWouldSkipExisting
                        self.statusText = "Dry run (device id): would upload \(self.uploadedCount), skip \(plan.immichWouldSkipExisting), replace \(plan.immichWouldReplaceExisting) (\(plan.assetsScanned) assets scanned)"
                        self.appendLog("Dry run complete: planned \(plan.immichPlannedUploads) uploads — would upload \(self.uploadedCount), skip \(plan.immichWouldSkipExisting), replace \(plan.immichWouldReplaceExisting)")
                        if !plan.notes.isEmpty {
                            for n in plan.notes {
                                self.appendLog("Dry run note: \(n)")
                            }
                        }
                        self.dryRun = false
                        self.checkForResumableSession()
                        self.isRunning = false
                        self.isPaused = false
                        return
                    }

                    if result.wasPaused {
                        // Save session state for resume
                        var updatedSession = sessionToUse
                        updatedSession.lastUpdatedAt = Date()
                        updatedSession.pausedAt = Date()
                        updatedSession.processedAssetIds = result.processedAssetIds
                        updatedSession.errorAssetIds = result.errorAssetIds
                        updatedSession.pauseIndex = result.pauseIndex ?? 0
                        updatedSession.totalAssetsAtPause = Int(self.progressTotal)
                        updatedSession.stats = BackupSessionStats(
                            uploadedCount: self.uploadedCount,
                            skippedCount: self.skippedCount,
                            errorCount: self.errorCount
                        )
                        self.saveSessionState(updatedSession)
                        self.checkForResumableSession()
                        self.statusText = "Paused. \(result.completedAssets) completed."
                    } else {
                        // Completed or cancelled - clear session
                        self.clearSessionState()
                        if let fileSummaryConst {
                            if sourceModeValue == .files {
                                self.statusText = "Done. \(fileSummaryConst)"
                            } else {
                                self.statusText = "Done. Photos: \(result.completedAssets) completed, \(result.skippedAssets) skipped, \(result.errorCount) errors. \(fileSummaryConst)"
                            }
                        } else {
                            if sourceModeValue == .files {
                                self.statusText = "Done."
                            } else {
                                self.statusText = "Done. Completed \(result.completedAssets), skipped \(result.skippedAssets), errors \(result.errorCount)."
                            }
                        }
                    }
                    self.isRunning = false
                    self.isPaused = false
                }
            } catch {
                await MainActor.run { [weakSelf] in
                    weakSelf?.isRunning = false
                    weakSelf?.isPaused = false
                    weakSelf?.statusText = "Error: \(error)"
                    weakSelf?.appendLog("ERROR: \(error)")
                }
            }
        }
    }

    func cancel() {
        // "Stop" should be resumable: request a pause so the core exporter can persist session state.
        // This stops after the current item and saves resume data (vs hard-cancelling and losing state).
        runState.store(.paused)
        isPaused = true
        statusText = "Stopping…"
        appendLog("Stop requested: will pause after current item to allow resume.")
    }

    func pause() {
        runState.store(.paused)
        isPaused = true
        statusText = "Pausing…"
    }

    func resume() {
        guard hasResumableSession else { return }
        guard let session = loadSessionState() else {
            hasResumableSession = false
            resumableSessionInfo = ""
            return
        }
        currentSessionState = session
        startWithSession(session)
    }

    func clearSessionState() {
        let url = sessionStateFileURL()
        try? FileManager.default.removeItem(at: url)
        hasResumableSession = false
        resumableSessionInfo = ""
        currentSessionState = nil
    }

    func checkForResumableSession() {
        if let session = loadSessionState() {
            hasResumableSession = true
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            let pausedDate = session.pausedAt ?? session.lastUpdatedAt
            let remaining = session.totalAssetsAtPause - session.processedAssetIds.count
            resumableSessionInfo = "Paused \(formatter.string(from: pausedDate)) - \(remaining) remaining"
        } else {
            hasResumableSession = false
            resumableSessionInfo = ""
        }
    }

    private func sessionStateFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("com.local.iphoto-backup-ui", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("session_state.json")
    }

    private func saveSessionState(_ state: BackupSessionState) {
        let url = sessionStateFileURL()
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: url)
        } catch {
            appendLog("ERROR saving session state: \(error)")
        }
    }

    private func loadSessionState() -> BackupSessionState? {
        let url = sessionStateFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(BackupSessionState.self, from: data)
        } catch {
            return nil
        }
    }

    func testImmich() {
        guard !immichServerURL.isEmpty, !immichApiKey.isEmpty else { return }
        immichTestStatus = "Testing…"
        immichIsConnected = false
        showImmichConnectionError = false
        immichConnectionErrorMessage = ""

        let normalizedImmichURL = normalizeImmichBaseURLString(immichServerURL)
        if normalizedImmichURL != immichServerURL {
            immichServerURL = normalizedImmichURL
        }

        defaults.set(immichServerURL, forKey: "immichServerURL")
        keychain.set(immichApiKey, account: "immichApiKey")

        guard let base = URL(string: immichServerURL) else {
            immichTestStatus = "Invalid URL"
            immichConnectionErrorMessage = "Invalid Immich server URL."
            showImmichConnectionError = true
            return
        }
        let apiKey = immichApiKey
        let apiBase = (base.lastPathComponent == "api") ? base : base.appendingPathComponent("api")
        var pingReq = URLRequest(url: apiBase.appendingPathComponent("server/ping"))
        pingReq.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        Task.detached { [weak self] in
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    let (pingData, pingResp) = try await URLSession.shared.data(for: pingReq)
                    guard let http = pingResp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        throw NSError(domain: "immich", code: (pingResp as? HTTPURLResponse)?.statusCode ?? -1)
                    }
                    _ = pingData

                    var meReq = URLRequest(url: apiBase.appendingPathComponent("users/me"))
                    meReq.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    let (_, meResp) = try await URLSession.shared.data(for: meReq)
                    guard let http2 = meResp as? HTTPURLResponse, (200...299).contains(http2.statusCode) else {
                        throw NSError(domain: "immich", code: (meResp as? HTTPURLResponse)?.statusCode ?? -2)
                    }

                    // Also test /assets/exist latency (use a random id, should come back quickly).
                    let deviceId = await MainActor.run { [weak self] in
                        self?.immichDeviceId ?? "cli"
                    }
                    let probeId = "probe-\(UUID().uuidString)"
                    let existBody: [String: Any] = [
                        "deviceId": deviceId,
                        "deviceAssetIds": [probeId]
                    ]
                    let existData = try JSONSerialization.data(withJSONObject: existBody, options: [])
                    var existReq = URLRequest(url: apiBase.appendingPathComponent("assets/exist"))
                    existReq.httpMethod = "POST"
                    existReq.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    existReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    existReq.httpBody = existData
                    let start = Date()
                    let (_, existResp) = try await URLSession.shared.data(for: existReq)
                    guard let http3 = existResp as? HTTPURLResponse, (200...299).contains(http3.statusCode) else {
                        throw NSError(domain: "immich", code: (existResp as? HTTPURLResponse)?.statusCode ?? -3)
                    }
                    let ms = Int(Date().timeIntervalSince(start) * 1000)

                    await MainActor.run { [weak self] in
                        self?.immichTestStatus = "Connected (\(ms)ms)"
                        self?.immichIsConnected = true
                        self?.showImmichConnectionError = false
                        self?.immichConnectionErrorMessage = ""
                    }
                    return
                } catch {
                    lastError = error
                    if attempt < 3 {
                        await MainActor.run { [weak self] in
                            self?.immichTestStatus = "Testing… (\(attempt + 1)/3)"
                        }
                        try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s
                        continue
                    }
                }
            }

            let errorText = lastError.map { String(describing: $0) } ?? "Unknown error"
            let serverURL = await MainActor.run { [weak self] in
                self?.immichServerURL ?? ""
            }

            await MainActor.run { [weak self] in
                guard let self = self else { return }

                self.immichTestStatus = "Failed"
                self.immichIsConnected = false

                // Check if this might be a local network permission issue
                if let error = lastError,
                   self.isLocalNetworkURL(serverURL),
                   self.isLocalNetworkPermissionError(error) {
                    self.showLocalNetworkPermissionNeeded = true
                    self.immichConnectionErrorMessage = """
                        Could not connect to your local Immich server.

                        This may be because ImmiBridge needs permission to access your local network.

                        Please go to System Settings → Privacy & Security → Local Network and enable access for ImmiBridge, then try again.

                        Error: \(errorText)
                        """
                } else {
                    self.showLocalNetworkPermissionNeeded = false
                    self.immichConnectionErrorMessage = "Could not connect to Immich after 3 attempts.\n\n\(errorText)"
                }
                self.showImmichConnectionError = true
            }
        }
    }

    func maybeAutoTestImmich() {
        guard !immichServerURL.isEmpty, !immichApiKey.isEmpty else { return }
        testImmich()
    }

    func openImmichApiKeysPage() {
        let normalized = normalizeImmichBaseURLString(immichServerURL)
        guard let base = URL(string: normalized) else { return }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        comps.path = "/user-settings"
        comps.queryItems = [URLQueryItem(name: "isOpen", value: "api-keys")]
        guard let url = comps.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func handleProgress(_ event: PhotoBackupProgress) {
        switch event {
        case .scanning:
            statusText = "Scanning…"
            appendLog("Scanning…")
        case .willExport(let totalAssets):
            progressTotal = Double(totalAssets)
            progressValue = 0
            statusText = "Will export \(totalAssets) asset(s)…"
            appendLog("Will export \(totalAssets) asset(s)…")
        case .exporting(let index, let total, let localIdentifier, let baseName, let mediaTypeRaw):
            progressTotal = Double(total)
            progressValue = Double(index)
            currentAssetName = baseName
            statusText = "Exporting \(index)/\(total): \(baseName)"
            // Avoid flooding the log (and pushing out Immich upload messages).
            if index <= 25 || index == total || (index % 250 == 0) {
                appendLog("[\(index)/\(total)] \(baseName)")
            }

            let isImage = mediaTypeRaw == PHAssetMediaType.image.rawValue
            let isVideo = mediaTypeRaw == PHAssetMediaType.video.rawValue

            if isImage {
                imagesSeen += 1
            }

            if isImage || isVideo {
                didShowFirstThumbnail = true
                let kind = isVideo ? "video" : "image"
                fetchThumbnail(localIdentifier: localIdentifier, label: "Preview (\(kind) \(index)/\(total))")
            }

            // Clear iCloud download state when moving to a new asset
            isDownloadingFromiCloud = false
            iCloudDownloadStartTime = nil
        case .message(let msg):
            appendLog(msg)
            // Only show errors in status text during Immich sync (progress row handles the rest)
            if msg.hasPrefix("ERROR Immich existing check failed")
                || msg.hasPrefix("ERROR Immich: /assets/exist")
                || msg.hasPrefix("ERROR Immich: could not fetch statistics")
                || msg.hasPrefix("ERROR Immich: exists sync failed")
            {
                statusText = msg
            }

            if msg.hasPrefix("Immich: preparing exists sync") || msg.hasPrefix("Immich: syncing existing assets") {
                immichSyncInProgress = true
            }
            if msg.hasPrefix("Immich: exists sync complete")
                || msg.hasPrefix("ERROR Immich: exists sync failed")
            {
                immichSyncInProgress = false
                immichExistChecked = 0
                immichExistTotal = 0
            }
            // Track upload/skip/error counts from messages
            // Count at asset level, not file level (Live Photos have multiple files per asset)
            if msg.hasPrefix("ERROR") {
                appendError(msg)
            }
            if msg.hasPrefix("ERROR Immich upload failed") {
                if let baseAssetId = extractBaseAssetId(from: msg) {
                    if !countedImmichUploadErrorAssetIds.contains(baseAssetId) {
                        countedImmichUploadErrorAssetIds.insert(baseAssetId)
                        errorCount += 1
                    }
                } else {
                    errorCount += 1
                }
            } else if msg.hasPrefix("ERROR Immich: upload failed for file") {
                errorCount += 1
            } else if msg.hasPrefix("ERROR processing") || msg.hasPrefix("ERROR exporting") {
                errorCount += 1
            } else if msg.hasPrefix("ERROR Files:") {
                errorCount += 1
            } else if msg.contains("skipping upload") {
                // Messages like "Immich: exists, skipping upload (deviceAssetId)"
                // or "Immich: duplicate, skipping upload (deviceAssetId)"
                if let baseAssetId = extractBaseAssetId(from: msg) {
                    if !skippedAssetIds.contains(baseAssetId) {
                        skippedAssetIds.insert(baseAssetId)
                        skippedCount += 1
                    }
                }
            } else if msg.contains("Immich: upload created") {
                // Actually uploaded to server - "Immich: upload created (deviceAssetId)"
                if let baseAssetId = extractBaseAssetId(from: msg) {
                    if !skippedAssetIds.contains(baseAssetId) {
                        skippedAssetIds.insert(baseAssetId)
                        uploadedCount += 1
                    }
                } else {
                    uploadedCount += 1
                }
            } else if msg.contains("Immich: upload duplicate") {
                // Server found it already exists by checksum - "Immich: upload duplicate (deviceAssetId)"
                if let baseAssetId = extractBaseAssetId(from: msg) {
                    if !skippedAssetIds.contains(baseAssetId) {
                        skippedAssetIds.insert(baseAssetId)
                        skippedCount += 1
                    }
                }
            }

            if msg.hasPrefix("Immich: recorded failed upload") {
                failedUploadCount = countFailedUploadRecords(in: currentFailedUploadsDir)
            }
        case .iCloudDownloading(_, let baseName, let progress, let attempt):
            // Track when download started
            if iCloudDownloadStartTime == nil {
                iCloudDownloadStartTime = Date()
            }
            // Only show UI after 5 seconds of downloading
            let elapsed = Date().timeIntervalSince(iCloudDownloadStartTime ?? Date())
            if elapsed >= 5.0 {
                isDownloadingFromiCloud = true
            }
            iCloudDownloadAssetName = baseName
            iCloudDownloadProgress = progress
            iCloudDownloadAttempt = attempt
        case .retrying(_, let baseName, let attempt, let maxAttempts, let delay, let reason):
            appendLog("Retry \(attempt)/\(maxAttempts) for \(baseName) in \(String(format: "%.1f", delay))s: \(reason)")
            statusText = "Retrying \(baseName)…"
        case .immichExistingCheck(let checked, let total):
            immichExistChecked = checked
            immichExistTotal = total
            immichSyncInProgress = checked < total
        case .paused(let at, let total):
            isPaused = true
            statusText = "Paused at \(at)/\(total)"
            appendLog("Paused at \(at)/\(total)")
        case .fileScanning:
            statusText = "Scanning files…"
            appendLog("Files: scanning…")
        case .fileWillCopy(let totalFiles):
            progressTotal = Double(totalFiles)
            progressValue = 0
            statusText = "Will copy \(totalFiles) file(s)…"
            appendLog("Files: will copy \(totalFiles) file(s)…")
        case .fileCopying(let index, let total, let relativePath):
            progressTotal = Double(total)
            progressValue = Double(index)
            currentAssetName = relativePath
            statusText = "Files \(index)/\(total): \(relativePath)"
            appendLog("Files [\(index)/\(total)] \(relativePath)")
        }
    }

    private func appendLog(_ line: String) {
        let maxBufferLines = 10_000
        let trimBatch = 500
        logBuffer.append(LogLine(text: line))
        if logBuffer.count > (maxBufferLines + trimBatch) {
            logBuffer.removeFirst(logBuffer.count - maxBufferLines)
        }
        scheduleLogFlushIfNeeded()
    }

    func setLogVisible(_ isVisible: Bool) {
        isLogVisible = isVisible
        scheduleLogFlushIfNeeded(force: true)
    }

    private func scheduleLogFlushIfNeeded(force: Bool = false) {
        guard isLogVisible || force else { return }
        guard logFlushTask == nil else { return }
        logFlushTask = Task { @MainActor [weak self] in
            // Coalesce many log events into a small number of UI updates.
            try? await Task.sleep(nanoseconds: 150_000_000) // 0.15s
            guard let self else { return }
            self.logLines = Array(self.logBuffer.suffix(500))
            self.logFlushTask = nil
        }
    }

    private func appendError(_ line: String) {
        let maxLines = 5_000
        let trimBatch = 250
        errorLines.append(LogLine(text: line))
        if errorLines.count > (maxLines + trimBatch) {
            errorLines.removeFirst(errorLines.count - maxLines)
        }
    }

    private func appSupportDirectoryURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("com.local.iphoto-backup-ui", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)
        return appDir
    }

    private func failedUploadsDirectoryURL() -> URL {
        let failed = appSupportDirectoryURL().appendingPathComponent("failed_uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true, attributes: nil)
        return failed
    }

    private func countFailedUploadRecords(in dir: URL?) -> Int {
        guard let dir else { return 0 }
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return 0 }
        return urls.filter { $0.lastPathComponent.hasPrefix("failed-upload-") && $0.pathExtension == "json" }.count
    }

    func openFailedUploadsFolder() {
        let dir = currentFailedUploadsDir ?? failedUploadsDirectoryURL()
        NSWorkspace.shared.open(dir)
    }

    func copyErrorsToClipboard() {
        let text = errorLines.map(\.text).joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func exportFailedUploadsToFolder() {
        guard !isRunning else { return }
        guard !isExportingFailedUploads else { return }

        let dir = currentFailedUploadsDir ?? failedUploadsDirectoryURL()
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let recordURLs = urls.filter { $0.lastPathComponent.hasPrefix("failed-upload-") && $0.pathExtension == "json" }
        if recordURLs.isEmpty { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Export Folder"
        if panel.runModal() != .OK { return }
        guard let destination = panel.url else { return }

        isExportingFailedUploads = true
        appendLog("Export: exporting failed uploads to \(destination.path)")

        let modeRaw = mode.rawValue
        let mediaRaw = media.rawValue
        let orderValue = order
        let includeAdjustments = includeAdjustmentData
        let timeoutValue = timeoutSeconds

        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                Task { @MainActor in
                    self?.isExportingFailedUploads = false
                }
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var ids = Set<String>()
            for recordURL in recordURLs {
                guard let data = try? Data(contentsOf: recordURL) else { continue }
                guard let record = try? decoder.decode(FailedUploadRecord.self, from: data) else { continue }
                if let id = record.phAssetLocalIdentifier, !id.isEmpty {
                    ids.insert(id)
                } else {
                    // Best-effort: strip known suffixes from deviceAssetId.
                    let suffixes = [":edited", ":pairedVideo", ":video"]
                    var base = record.deviceAssetId
                    for s in suffixes {
                        if base.hasSuffix(s) { base = String(base.dropLast(s.count)) }
                    }
                    if !base.isEmpty, !base.hasPrefix("file:") {
                        ids.insert(base)
                    }
                }
            }

            if ids.isEmpty {
                await MainActor.run { self?.appendLog("Export: no Photos asset ids found in failed upload records.") }
                return
            }

            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let tempDir = caches.appendingPathComponent("com.local.iphoto-backup-ui/tmp", isDirectory: true)

            let options = PhotoBackupOptions(
                folderExport: FolderExportOptions(destination: destination),
                immichUpload: nil,
                tempDir: tempDir,
                failedUploadsDir: nil,
                onlyAssetLocalIdentifiers: ids,
                backupMode: .full,
                mode: PhotoBackupOptions.Mode(rawValue: modeRaw) ?? .originals,
                media: PhotoBackupOptions.Media(rawValue: mediaRaw) ?? .all,
                sortOrder: (orderValue == .oldest) ? .oldestFirst : .newestFirst,
                limit: nil,
                dryRun: false,
                since: nil,
                albumScope: .allPhotos,
                libraryScope: .personalAndShared,
                includeAdjustmentData: includeAdjustments,
                networkAccessAllowed: true,
                requestTimeoutSeconds: timeoutValue
            )

            do {
                let exporter = PhotoBackupExporter()
                _ = try exporter.export(
                    options: options,
                    progress: { event in
                        if case .message(let msg) = event {
                            Task { @MainActor in self?.appendLog("Export: \(msg)") }
                        }
                    },
                    runState: { .running },
                    sessionState: nil
                )
                await MainActor.run { self?.appendLog("Export: done") }
            } catch {
                await MainActor.run { self?.appendLog("ERROR Export: \(error)") }
            }
        }
    }

    @MainActor
    func resetAndStartFresh(wipeManifestDatabase: Bool) {
        guard !isRunning else { return }

        var messages: [String] = []

        // Clear resumable session
        do {
            let url = sessionStateFileURL()
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                messages.append("Reset: removed session state")
            }
        } catch {
            messages.append("ERROR Reset: could not remove session state: \(error)")
        }

        // Clear temp cache
        do {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let tmpDir = caches.appendingPathComponent("com.local.iphoto-backup-ui/tmp", isDirectory: true)
            if FileManager.default.fileExists(atPath: tmpDir.path) {
                try FileManager.default.removeItem(at: tmpDir)
                messages.append("Reset: cleared temp cache")
            }
        } catch {
            messages.append("ERROR Reset: could not clear temp cache: \(error)")
        }

        // Optionally wipe the destination manifest DB (incremental/mirror “database”).
        if wipeManifestDatabase {
            if let destination = resolveFolderDestinationURLForReset() {
                let didAccess = destination.startAccessingSecurityScopedResource()
                defer { if didAccess { destination.stopAccessingSecurityScopedResource() } }

                let base = destination
                    .appendingPathComponent(".immibridge", isDirectory: true)
                    .appendingPathComponent("manifest.sqlite", isDirectory: false)
                let candidates = [
                    base,
                    URL(fileURLWithPath: base.path + "-wal"),
                    URL(fileURLWithPath: base.path + "-shm"),
                ]
                var removedAny = false
                for url in candidates {
                    if FileManager.default.fileExists(atPath: url.path) {
                        do {
                            try FileManager.default.removeItem(at: url)
                            removedAny = true
                        } catch {
                            messages.append("ERROR Reset: could not remove \(url.lastPathComponent): \(error)")
                        }
                    }
                }
                if removedAny {
                    messages.append("Reset: wiped manifest database in destination")
                } else {
                    messages.append("Reset: no manifest database found in destination")
                }
            } else {
                messages.append("Reset: no folder destination set; skipping manifest wipe")
            }
        }

        // Reset UI state
        clearSessionState()
        logLines = []
        logBuffer = []
        errorLines = []
        uploadedCount = 0
        skippedCount = 0
        errorCount = 0
        failedUploadCount = 0
        countedImmichUploadErrorAssetIds = []
        immichExistChecked = 0
        immichExistTotal = 0
        immichSyncInProgress = false
        statusText = "Idle"

        // Persist: clear resume info and optionally reset the Immich device id (so deviceAssetIds won’t match).
        defaults.removeObject(forKey: "immichDeviceId")
        immichDeviceId = ""
        messages.append("Reset: cleared Immich device id")

        if messages.isEmpty {
            messages = ["Reset complete"]
        }
        for m in messages {
            appendLog(m)
        }
    }

    private func resolveFolderDestinationURLForReset() -> URL? {
        if let b = folderDestinationBookmark, let url = resolveBookmark(b) {
            return url
        }
        if !destinationPath.isEmpty {
            return URL(fileURLWithPath: destinationPath, isDirectory: true)
        }
        return nil
    }

    /// Extract the base asset ID from a message like "Immich: upload created (deviceAssetId)"
    /// Strips suffixes like ":edited", ":pairedVideo", ":video" to get the base localIdentifier
    private func extractBaseAssetId(from message: String) -> String? {
        // Find content in parentheses at the end: "... (deviceAssetId)"
        guard let openParen = message.lastIndex(of: "("),
              let closeParen = message.lastIndex(of: ")"),
              openParen < closeParen else {
            return nil
        }

        let startIndex = message.index(after: openParen)
        let deviceAssetId = String(message[startIndex..<closeParen])

        // Strip known suffixes to get base asset ID
        // Suffixes: ":edited", ":pairedVideo", ":video"
        let suffixes = [":edited", ":pairedVideo", ":video"]
        for suffix in suffixes {
            if deviceAssetId.hasSuffix(suffix) {
                return String(deviceAssetId.dropLast(suffix.count))
            }
        }

        return deviceAssetId
    }

    private func fetchThumbnail(localIdentifier: String, label: String) {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetch.firstObject else { return }

        let targetSize = CGSize(width: 240, height: 240)
        let opts = PHImageRequestOptions()
        // Never allow iCloud downloads for thumbnails; it can contend with export/download.
        opts.isNetworkAccessAllowed = false
        opts.deliveryMode = .fastFormat

        if let lastThumbnailRequestId {
            PHImageManager.default().cancelImageRequest(lastThumbnailRequestId)
            self.lastThumbnailRequestId = nil
        }

        let requestId = PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: opts
        ) { [weak self] image, _ in
            guard let self else { return }
            Task { @MainActor in
                self.thumbnail = image
                self.thumbnailCaption = label
            }
        }
        lastThumbnailRequestId = requestId
    }

    // MARK: - Local Network Helpers

    /// Check if a URL points to a local network address
    private func isLocalNetworkURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else { return false }

        // Check for .local domains (Bonjour)
        if host.hasSuffix(".local") { return true }

        // Check for localhost
        if host == "localhost" || host == "127.0.0.1" { return true }

        // Check for private IP ranges
        let components = host.split(separator: ".").compactMap { Int($0) }
        if components.count == 4 {
            let (a, b, _, _) = (components[0], components[1], components[2], components[3])
            // 10.x.x.x
            if a == 10 { return true }
            // 172.16.x.x - 172.31.x.x
            if a == 172 && (16...31).contains(b) { return true }
            // 192.168.x.x
            if a == 192 && b == 168 { return true }
        }

        return false
    }

    /// Check if an error indicates local network permission was denied
    private func isLocalNetworkPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError

        // Network permission denied errors
        if nsError.domain == NSURLErrorDomain {
            // -1009: The Internet connection appears to be offline
            // -1004: Could not connect to the server
            // -1001: The request timed out
            if [-1009, -1004, -1001].contains(nsError.code) {
                return true
            }
        }

        // Check error description for common permission-related messages
        let description = error.localizedDescription.lowercased()
        if description.contains("network") && (description.contains("permission") || description.contains("denied")) {
            return true
        }

        return false
    }

    func openLocalNetworkSettings() {
        // Open System Settings to Privacy & Security > Local Network
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }
}

private func normalizeImmichBaseURLString(_ input: String) -> String {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    if let url = URL(string: trimmed), let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
        if let scheme = comps.scheme, let host = comps.host {
            var out = "\(scheme)://\(host)"
            if let port = comps.port {
                out += ":\(port)"
            }
            return out
        }
    }

    // Regex fallback for inputs like "http://host:2283/some/path"
    if let re = try? NSRegularExpression(pattern: #"^(https?://[^/]+)"#, options: [.caseInsensitive]) {
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        if let m = re.firstMatch(in: trimmed, options: [], range: range),
           let r = Range(m.range(at: 1), in: trimmed) {
            return String(trimmed[r])
        }
    }

    return trimmed
}

final class ManagedBackupRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var _state: BackupRunState = .cancelled

    func store(_ newValue: BackupRunState) {
        lock.lock()
        _state = newValue
        lock.unlock()
    }

    func load() -> BackupRunState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }
}

final class KeychainStore {
    private let service: String

    init(service: String) {
        self.service = service
    }

    func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        // First try to delete any existing item
        delete(account: account)
        // Then add the new item
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
