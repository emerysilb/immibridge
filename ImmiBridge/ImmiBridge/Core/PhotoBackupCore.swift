import CryptoKit
import Foundation
import Photos
import UniformTypeIdentifiers

// MARK: - Pause/Resume Support

/// Tri-state control for backup run state
public enum BackupRunState: Int, Sendable {
    case running = 0
    case paused = 1
    case cancelled = 2
}

/// Snapshot of backup configuration for resume validation
public struct BackupConfigSnapshot: Codable, Sendable {
    public var mode: String
    public var media: String
    public var sortOrder: String
    public var immichServerURL: String?
    public var immichDeviceId: String?
    public var folderDestination: String?

    public init(
        mode: String,
        media: String,
        sortOrder: String,
        immichServerURL: String? = nil,
        immichDeviceId: String? = nil,
        folderDestination: String? = nil
    ) {
        self.mode = mode
        self.media = media
        self.sortOrder = sortOrder
        self.immichServerURL = immichServerURL
        self.immichDeviceId = immichDeviceId
        self.folderDestination = folderDestination
    }
}

/// Statistics from a backup session
public struct BackupSessionStats: Codable, Sendable {
    public var uploadedCount: Int
    public var skippedCount: Int
    public var errorCount: Int

    public init(uploadedCount: Int = 0, skippedCount: Int = 0, errorCount: Int = 0) {
        self.uploadedCount = uploadedCount
        self.skippedCount = skippedCount
        self.errorCount = errorCount
    }
}

/// Persisted state for pause/resume functionality
public struct BackupSessionState: Codable, Sendable {
    /// Unique identifier for this session
    public var sessionId: String

    /// When the session started
    public var startedAt: Date

    /// When the session was last updated (paused/saved)
    public var lastUpdatedAt: Date

    /// When the session was paused (nil if never paused)
    public var pausedAt: Date?

    /// Set of localIdentifier strings for assets fully processed
    public var processedAssetIds: Set<String>

    /// Set of localIdentifier strings that had errors (may retry on resume)
    public var errorAssetIds: Set<String>

    /// The index in the sorted asset list where we paused
    public var pauseIndex: Int

    /// Total assets count at time of pause
    public var totalAssetsAtPause: Int

    /// Configuration snapshot for validation on resume
    public var configSnapshot: BackupConfigSnapshot

    /// Statistics from the session so far
    public var stats: BackupSessionStats

    public init(
        sessionId: String = UUID().uuidString,
        startedAt: Date = Date(),
        lastUpdatedAt: Date = Date(),
        pausedAt: Date? = nil,
        processedAssetIds: Set<String> = [],
        errorAssetIds: Set<String> = [],
        pauseIndex: Int = 0,
        totalAssetsAtPause: Int = 0,
        configSnapshot: BackupConfigSnapshot,
        stats: BackupSessionStats = BackupSessionStats()
    ) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.pausedAt = pausedAt
        self.processedAssetIds = processedAssetIds
        self.errorAssetIds = errorAssetIds
        self.pauseIndex = pauseIndex
        self.totalAssetsAtPause = totalAssetsAtPause
        self.configSnapshot = configSnapshot
        self.stats = stats
    }
}

public struct FolderExportOptions: Sendable {
    public var destination: URL

    public init(destination: URL) {
        self.destination = destination
    }
}

public struct ImmichUploadOptions: Sendable {
    public var serverURL: URL
    public var apiKey: String
    public var deviceId: String
    public var checksumPrecheck: Bool
    public var skipHash: Bool
    public var uploadConcurrency: Int
    public var hashConcurrency: Int
    public var bulkCheckBatchSize: Int
    public var existBatchSize: Int
    public var maxInFlight: Int
    public var syncAlbums: Bool
    public var updateChangedAssets: Bool

    public init(
        serverURL: URL,
        apiKey: String,
        deviceId: String,
        checksumPrecheck: Bool = true,
        skipHash: Bool = false,
        uploadConcurrency: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1),
        hashConcurrency: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1),
        bulkCheckBatchSize: Int = 5_000,
        existBatchSize: Int = 5_000,
        maxInFlight: Int? = nil,
        syncAlbums: Bool = false,
        updateChangedAssets: Bool = false
    ) {
        self.serverURL = serverURL
        self.apiKey = apiKey
        self.deviceId = deviceId
        self.checksumPrecheck = checksumPrecheck
        self.skipHash = skipHash
        self.uploadConcurrency = max(1, uploadConcurrency)
        self.hashConcurrency = max(1, hashConcurrency)
        self.bulkCheckBatchSize = max(1, bulkCheckBatchSize)
        self.existBatchSize = max(1, existBatchSize)
        self.maxInFlight = maxInFlight ?? max(8, self.uploadConcurrency * 4)
        self.syncAlbums = syncAlbums
        self.updateChangedAssets = updateChangedAssets
    }
}

public struct PhotoBackupOptions: Sendable {
    public struct AlbumInfo: Codable, Sendable, Hashable {
        public var localIdentifier: String
        public var title: String

        public init(localIdentifier: String, title: String) {
            self.localIdentifier = localIdentifier
            self.title = title
        }
    }

    public enum AlbumScope: Codable, Sendable, Equatable {
        case allPhotos
        case selectedAlbums(localIdentifiers: [String])
    }

    public enum Mode: String, Sendable {
        case originals
        case edited
        case both
    }

    public enum Media: String, Sendable {
        case all
        case images
        case videos
    }

    public enum CollisionPolicy: String, Sendable {
        case skipIdenticalElseRename
    }

    public enum SortOrder: String, Sendable {
        case oldestFirst
        case newestFirst
    }

    public enum LibraryScope: String, Sendable {
        case personalOnly
        case personalAndShared
        case sharedOnly
    }

    public var folderExport: FolderExportOptions?
    public var immichUpload: ImmichUploadOptions?
    public var tempDir: URL
    public var backupMode: BackupMode
    public var mode: Mode
    public var media: Media
    public var sortOrder: SortOrder
    public var limit: Int?
    public var dryRun: Bool
    public var since: Date?
    public var albumScope: AlbumScope
    public var libraryScope: LibraryScope
    public var includeAdjustmentData: Bool
    public var networkAccessAllowed: Bool
    public var requestTimeoutSeconds: TimeInterval
    public var collisionPolicy: CollisionPolicy
    public var retryConfiguration: RetryConfiguration
    public var iCloudTimeoutMultiplier: Double

    public init(
        folderExport: FolderExportOptions? = nil,
        immichUpload: ImmichUploadOptions? = nil,
        tempDir: URL,
        backupMode: BackupMode = .smartIncremental,
        mode: Mode = .originals,
        media: Media = .all,
        sortOrder: SortOrder = .oldestFirst,
        limit: Int? = nil,
        dryRun: Bool = false,
        since: Date? = nil,
        albumScope: AlbumScope = .allPhotos,
        libraryScope: LibraryScope = .personalOnly,
        includeAdjustmentData: Bool = true,
        networkAccessAllowed: Bool = true,
        requestTimeoutSeconds: TimeInterval = 300,
        collisionPolicy: CollisionPolicy = .skipIdenticalElseRename,
        retryConfiguration: RetryConfiguration = .default,
        iCloudTimeoutMultiplier: Double = 2.0
    ) {
        self.folderExport = folderExport
        self.immichUpload = immichUpload
        self.tempDir = tempDir
        self.backupMode = backupMode
        self.mode = mode
        self.media = media
        self.sortOrder = sortOrder
        self.limit = limit
        self.dryRun = dryRun
        self.since = since
        self.albumScope = albumScope
        self.libraryScope = libraryScope
        self.includeAdjustmentData = includeAdjustmentData
        self.networkAccessAllowed = networkAccessAllowed
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.collisionPolicy = collisionPolicy
        self.retryConfiguration = retryConfiguration
        self.iCloudTimeoutMultiplier = iCloudTimeoutMultiplier
    }
}

public enum PhotoBackupProgress: Sendable {
    case scanning
    case willExport(totalAssets: Int)
    case exporting(index: Int, total: Int, localIdentifier: String, baseName: String, mediaTypeRaw: Int)
    case message(String)
    /// Reports iCloud download progress during export
    case iCloudDownloading(localIdentifier: String, baseName: String, progress: Double, attemptNumber: Int)
    /// Reports a retry is about to happen
    case retrying(localIdentifier: String, baseName: String, attemptNumber: Int, maxAttempts: Int, delaySeconds: TimeInterval, reason: String)
    /// Reports progress of background Immich `/assets/exist` checks
    case immichExistingCheck(checked: Int, total: Int)
    /// Reports that the backup was paused
    case paused(at: Int, total: Int)
    // File backups (iCloud Drive / custom folders)
    case fileScanning
    case fileWillCopy(totalFiles: Int)
    case fileCopying(index: Int, total: Int, relativePath: String)
}

public struct PhotoBackupResult: Sendable {
    public var attemptedAssets: Int
    public var completedAssets: Int
    public var skippedAssets: Int
    public var errorCount: Int
    /// Whether the export was paused (vs completed or cancelled)
    public var wasPaused: Bool
    /// Set of processed asset localIdentifiers (for resume)
    public var processedAssetIds: Set<String>
    /// Set of asset localIdentifiers that had errors
    public var errorAssetIds: Set<String>
    /// Index where we stopped (for resume)
    public var pauseIndex: Int?

    public init(
        attemptedAssets: Int,
        completedAssets: Int,
        skippedAssets: Int,
        errorCount: Int,
        wasPaused: Bool = false,
        processedAssetIds: Set<String> = [],
        errorAssetIds: Set<String> = [],
        pauseIndex: Int? = nil
    ) {
        self.attemptedAssets = attemptedAssets
        self.completedAssets = completedAssets
        self.skippedAssets = skippedAssets
        self.errorCount = errorCount
        self.wasPaused = wasPaused
        self.processedAssetIds = processedAssetIds
        self.errorAssetIds = errorAssetIds
        self.pauseIndex = pauseIndex
    }
}

public enum PhotoBackupError: Error {
    case photosPermissionNotGranted(status: PHAuthorizationStatus)
    case noOutputsSelected
}

/// Classifies errors that occur during asset export with iCloud-aware handling
public enum ExportError: Error, Sendable {
    /// iCloud download failed due to network issues or unavailability
    case iCloudDownloadFailed(underlyingError: Error?, filename: String)

    /// Asset is unavailable (corrupted, deleted, or not accessible)
    case assetUnavailable(reason: String, filename: String)

    /// Export timed out after the configured duration
    case timeout(duration: TimeInterval, filename: String)

    /// Export was cancelled
    case cancelled(filename: String)

    /// Generic export failure with underlying error
    case exportFailed(underlyingError: Error, filename: String)

    /// Human-readable description for progress callbacks
    public var userMessage: String {
        switch self {
        case .iCloudDownloadFailed(_, let filename):
            return "iCloud download failed: \(filename) - check network connection"
        case .assetUnavailable(let reason, let filename):
            return "Asset unavailable (\(reason)): \(filename)"
        case .timeout(let duration, let filename):
            return "Timed out after \(Int(duration))s: \(filename)"
        case .cancelled(let filename):
            return "Cancelled: \(filename)"
        case .exportFailed(let error, let filename):
            return "Export failed for \(filename): \(error.localizedDescription)"
        }
    }

    /// Whether this error is potentially recoverable with retry
    public var isRetryable: Bool {
        switch self {
        case .iCloudDownloadFailed, .timeout:
            return true
        case .assetUnavailable, .cancelled, .exportFailed:
            return false
        }
    }
}

/// Configuration for retry behavior during export
public struct RetryConfiguration: Sendable {
    /// Maximum number of retry attempts (0 = no retries)
    public var maxRetries: Int

    /// Base delay before first retry (subsequent delays use exponential backoff)
    public var baseDelaySeconds: TimeInterval

    /// Maximum delay between retries (caps exponential growth)
    public var maxDelaySeconds: TimeInterval

    /// Whether to add random jitter to delays (helps reduce contention)
    public var useJitter: Bool

    /// Default configuration: 3 retries, 1s base delay, 30s max, with jitter
    public static let `default` = RetryConfiguration(
        maxRetries: 3,
        baseDelaySeconds: 1.0,
        maxDelaySeconds: 30.0,
        useJitter: true
    )

    /// No retry - fail immediately on first error
    public static let none = RetryConfiguration(
        maxRetries: 0,
        baseDelaySeconds: 0,
        maxDelaySeconds: 0,
        useJitter: false
    )

    public init(
        maxRetries: Int = 3,
        baseDelaySeconds: TimeInterval = 1.0,
        maxDelaySeconds: TimeInterval = 30.0,
        useJitter: Bool = true
    ) {
        self.maxRetries = maxRetries
        self.baseDelaySeconds = baseDelaySeconds
        self.maxDelaySeconds = maxDelaySeconds
        self.useJitter = useJitter
    }

    /// Calculate delay for given attempt number (0-indexed)
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponentialDelay = baseDelaySeconds * pow(2.0, Double(attempt))
        let cappedDelay = min(exponentialDelay, maxDelaySeconds)

        if useJitter {
            // Add random jitter between 0% and 25% of the delay
            let jitter = cappedDelay * Double.random(in: 0...0.25)
            return cappedDelay + jitter
        }
        return cappedDelay
    }
}

/// Thread-safe tracker for iCloud download progress during export
final class iCloudDownloadTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _isDownloading = false
    private var _lastProgress: Double = 0.0

    var isDownloading: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isDownloading
    }

    var lastProgress: Double {
        lock.lock()
        defer { lock.unlock() }
        return _lastProgress
    }

    func reportProgress(_ progress: Double) {
        lock.lock()
        defer { lock.unlock() }
        _isDownloading = progress < 1.0
        _lastProgress = progress
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        _isDownloading = false
        _lastProgress = 0.0
    }
}

final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment(by n: Int = 1) {
        lock.lock()
        _value += n
        lock.unlock()
    }
}

public final class PhotoBackupExporter {
    public init() {}

    public func requestPhotosAuthorization() -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited {
            return current
        }

        let sema = DispatchSemaphore(value: 0)
        var result: PHAuthorizationStatus = current
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            result = status
            sema.signal()
        }
        sema.wait()
        return result
    }

    public func export(
        options: PhotoBackupOptions,
        progress: @escaping @Sendable (PhotoBackupProgress) -> Void,
        runState: @escaping @Sendable () -> BackupRunState,
        sessionState: BackupSessionState? = nil
    ) throws -> PhotoBackupResult {
        guard options.folderExport != nil || options.immichUpload != nil else {
            throw PhotoBackupError.noOutputsSelected
        }

        let auth = requestPhotosAuthorization()
        guard auth == .authorized || auth == .limited else {
            throw PhotoBackupError.photosPermissionNotGranted(status: auth)
        }

        try ensureDir(options.tempDir)

        // Helper to check if cancelled (not paused)
        let shouldCancel: @Sendable () -> Bool = { runState() == .cancelled }

        let immichUploadErrorCounter = AtomicCounter()
        let progressWrapped: @Sendable (PhotoBackupProgress) -> Void = { event in
            if case .message(let msg) = event, msg.hasPrefix("ERROR Immich upload failed") {
                immichUploadErrorCounter.increment()
            }
            progress(event)
        }

        let immichClient: ImmichClient?
        let immichPipeline: ImmichUploadPipeline?
        if let immichUpload = options.immichUpload {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = options.requestTimeoutSeconds
            config.timeoutIntervalForResource = options.requestTimeoutSeconds
            config.httpMaximumConnectionsPerHost = immichUpload.uploadConcurrency
            let session = URLSession(configuration: config)
            let client = ImmichClient(serverURL: immichUpload.serverURL, apiKey: immichUpload.apiKey, session: session)
            immichClient = client
            immichPipeline = ImmichUploadPipeline(immich: immichUpload, client: client, progress: progressWrapped, shouldCancel: shouldCancel)
        } else {
            immichClient = nil
            immichPipeline = nil
        }

        let runId = UUID().uuidString
        let manifest: ManifestStore?
        if let dest = options.folderExport?.destination, options.backupMode != .full {
            let manifestURL = dest
                .appendingPathComponent(".immibridge", isDirectory: true)
                .appendingPathComponent("manifest.sqlite", isDirectory: false)
            manifest = try? ManifestStore(sqliteURL: manifestURL)
        } else {
            manifest = nil
        }

        let calendar = Calendar.current
        let fetchOptions = PHFetchOptions()
        let ascending = options.sortOrder == .oldestFirst
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: ascending)]

        progress(.scanning)

        func assetPassesFilters(_ asset: PHAsset) -> Bool {
            if let since = options.since, let created = asset.creationDate, created < since { return false }
            switch options.media {
            case .all:
                break
            case .images:
                if asset.mediaType != .image { return false }
            case .videos:
                if asset.mediaType != .video { return false }
            }
            return true
        }

        var filtered: [PHAsset] = []
        var albumMembershipByAssetId: [String: Set<PhotoBackupOptions.AlbumInfo>] = [:]
        var albumsForSync: [PhotoBackupOptions.AlbumInfo] = []

        switch options.albumScope {
        case .allPhotos:
            func appendPersonalAssets() {
                let assets = PHAsset.fetchAssets(with: fetchOptions)
                filtered.reserveCapacity(min(assets.count, options.limit ?? assets.count))
                assets.enumerateObjects { asset, _, stop in
                    if shouldCancel() { stop.pointee = true; return }
                    if !assetPassesFilters(asset) { return }
                    filtered.append(asset)
                    if let limit = options.limit, filtered.count >= limit {
                        stop.pointee = true
                    }
                }
            }

            func sharedAlbumAssetsById() -> [String: PHAsset] {
                var uniqueById: [String: PHAsset] = [:]
                let sharedCollections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
                sharedCollections.enumerateObjects { collection, _, stop in
                    if shouldCancel() { stop.pointee = true; return }
                    let sharedAssets = PHAsset.fetchAssets(in: collection, options: fetchOptions)
                    sharedAssets.enumerateObjects { asset, _, stop2 in
                        if shouldCancel() { stop2.pointee = true; return }
                        if !assetPassesFilters(asset) { return }
                        uniqueById[asset.localIdentifier] = asset
                    }
                }
                return uniqueById
            }

            switch options.libraryScope {
            case .personalOnly:
                appendPersonalAssets()
            case .personalAndShared:
                appendPersonalAssets()
                var uniqueById: [String: PHAsset] = Dictionary(uniqueKeysWithValues: filtered.map { ($0.localIdentifier, $0) })
                for (k, v) in sharedAlbumAssetsById() { uniqueById[k] = v }
                filtered = Array(uniqueById.values)
                filtered.sort { a, b in
                    let da = a.creationDate ?? .distantPast
                    let db = b.creationDate ?? .distantPast
                    return ascending ? (da < db) : (da > db)
                }
                if let limit = options.limit, filtered.count > limit {
                    filtered = Array(filtered.prefix(limit))
                }
            case .sharedOnly:
                filtered = Array(sharedAlbumAssetsById().values)
                filtered.sort { a, b in
                    let da = a.creationDate ?? .distantPast
                    let db = b.creationDate ?? .distantPast
                    return ascending ? (da < db) : (da > db)
                }
                if let limit = options.limit, filtered.count > limit {
                    filtered = Array(filtered.prefix(limit))
                }
            }
        case .selectedAlbums(let localIdentifiers):
            let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: localIdentifiers, options: nil)
            var uniqueById: [String: PHAsset] = [:]
            uniqueById.reserveCapacity(options.limit ?? 1024)

            collections.enumerateObjects { collection, _, stop in
                if shouldCancel() { stop.pointee = true; return }
                let title = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                let albumTitle = (title?.isEmpty == false) ? title! : "Untitled Album"
                let album = PhotoBackupOptions.AlbumInfo(localIdentifier: collection.localIdentifier, title: albumTitle)
                albumsForSync.append(album)

                let albumAssets = PHAsset.fetchAssets(in: collection, options: fetchOptions)
                albumAssets.enumerateObjects { asset, _, stop2 in
                    if shouldCancel() { stop2.pointee = true; return }
                    if !assetPassesFilters(asset) { return }
                    uniqueById[asset.localIdentifier] = asset
                    albumMembershipByAssetId[asset.localIdentifier, default: []].insert(album)
                }
            }

            filtered = Array(uniqueById.values)
            filtered.sort { a, b in
                let da = a.creationDate ?? .distantPast
                let db = b.creationDate ?? .distantPast
                return ascending ? (da < db) : (da > db)
            }
            if let limit = options.limit, filtered.count > limit {
                filtered = Array(filtered.prefix(limit))
            }
        }

        // If we want to mirror albums into Immich, build album membership for the selected scope.
        if options.immichUpload?.syncAlbums == true {
            let includedIds = Set(filtered.map(\.localIdentifier))

            if case .allPhotos = options.albumScope {
                let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
                collections.enumerateObjects { collection, _, stop in
                    if shouldCancel() { stop.pointee = true; return }
                    let title = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let albumTitle = (title?.isEmpty == false) ? title! : "Untitled Album"
                    let album = PhotoBackupOptions.AlbumInfo(localIdentifier: collection.localIdentifier, title: albumTitle)
                    albumsForSync.append(album)

                    let albumAssets = PHAsset.fetchAssets(in: collection, options: nil)
                    albumAssets.enumerateObjects { asset, _, stop2 in
                        if shouldCancel() { stop2.pointee = true; return }
                        if !includedIds.contains(asset.localIdentifier) { return }
                        albumMembershipByAssetId[asset.localIdentifier, default: []].insert(album)
                    }
                }
            }
        }

        // Resume logic: reorder assets if resuming from a previous session
        var processedIds = sessionState?.processedAssetIds ?? Set<String>()
        var errorIds = sessionState?.errorAssetIds ?? Set<String>()

        if let session = sessionState, let pausedAt = session.pausedAt {
            // Identify newer photos (created after pause time)
            let newerPhotos = filtered.filter { asset in
                guard let created = asset.creationDate else { return false }
                return created > pausedAt
            }

            // Partition: newer unprocessed first, then remaining unprocessed
            let newerUnprocessed = newerPhotos.filter { !processedIds.contains($0.localIdentifier) }
            let otherUnprocessed = filtered.filter { asset in
                !processedIds.contains(asset.localIdentifier) &&
                !newerUnprocessed.contains(where: { $0.localIdentifier == asset.localIdentifier })
            }

            // Reorder: newer first, then remaining
            filtered = newerUnprocessed + otherUnprocessed

            if !newerUnprocessed.isEmpty {
                progressWrapped(.message("Resuming: \(newerUnprocessed.count) newer photo(s), \(otherUnprocessed.count) remaining"))
            } else {
                progressWrapped(.message("Resuming: \(otherUnprocessed.count) remaining photo(s)"))
            }
        }

        progress(.willExport(totalAssets: filtered.count))

        final class AlbumCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var assetIdsByAlbumLocalId: [String: Set<String>] = [:]
            private var albumByLocalId: [String: PhotoBackupOptions.AlbumInfo] = [:]

            init(albums: [PhotoBackupOptions.AlbumInfo]) {
                self.albumByLocalId = Dictionary(uniqueKeysWithValues: albums.map { ($0.localIdentifier, $0) })
            }

            func add(assetId: String, to albums: [PhotoBackupOptions.AlbumInfo]) {
                lock.lock()
                for album in albums {
                    albumByLocalId[album.localIdentifier] = album
                    assetIdsByAlbumLocalId[album.localIdentifier, default: []].insert(assetId)
                }
                lock.unlock()
            }

            func snapshot() -> [(album: PhotoBackupOptions.AlbumInfo, assetIds: [String])] {
                lock.lock()
                let byAlbumLocalId = assetIdsByAlbumLocalId
                let albumsById = albumByLocalId
                lock.unlock()

                var out: [(album: PhotoBackupOptions.AlbumInfo, assetIds: [String])] = []
                out.reserveCapacity(byAlbumLocalId.count)
                for (albumId, ids) in byAlbumLocalId {
                    guard let album = albumsById[albumId] else { continue }
                    if ids.isEmpty { continue }
                    out.append((album: album, assetIds: Array(ids)))
                }
                return out
            }
        }

        let albumCollector: AlbumCollector? = (options.immichUpload?.syncAlbums == true) ? AlbumCollector(albums: albumsForSync) : nil

        // If Immich is enabled, perform a full "exists sync" up-front so we can show progress
        // and then start uploading with a complete existing-id set.
        if let immichUpload = options.immichUpload, let immichPipeline {
            do {
                let stats = try runSync { try await ImmichClient(serverURL: immichUpload.serverURL, apiKey: immichUpload.apiKey).getAssetStatistics() }
                progressWrapped(.message("Immich: server has \(stats.total) assets (\(stats.images) images, \(stats.videos) videos)"))
            } catch {
                progressWrapped(.message("ERROR Immich: could not fetch statistics: \(error)"))
            }

            // Build /assets/exist batches based on the Photos assets we plan to process.
            // We intentionally avoid calling PHAssetResource.assetResources here because it can be slow.
            var batches: [(ids: [String], units: Int)] = []
            batches.reserveCapacity(max(1, filtered.count / immichUpload.existBatchSize))
            var currentIds: [String] = []
            currentIds.reserveCapacity(immichUpload.existBatchSize)
            var currentUnits = 0

            func finalizeBatch() {
                guard !currentIds.isEmpty else { return }
                batches.append((ids: currentIds, units: currentUnits))
                currentIds = []
                currentIds.reserveCapacity(immichUpload.existBatchSize)
                currentUnits = 0
            }

            for (idx, asset) in filtered.enumerated() {
                if shouldCancel() { break }
                if idx % 2000 == 0, idx > 0 {
                    progressWrapped(.message("Immich: preparing exists sync… (\(idx)/\(filtered.count))"))
                }

                var ids: [String] = []
                ids.reserveCapacity(4)

                if options.mode == .originals || options.mode == .both {
                    switch asset.mediaType {
                    case .image:
                        ids.append(asset.localIdentifier) // still
                        if asset.mediaSubtypes.contains(.photoLive) {
                            // Some Live Photos upload as pairedVideo, others as a live video resource; check both.
                            ids.append(asset.localIdentifier + ":pairedVideo")
                            ids.append(asset.localIdentifier + ":video")
                        }
                    case .video:
                        ids.append(asset.localIdentifier + ":video")
                    default:
                        break
                    }
                }

                if options.mode == .edited || options.mode == .both {
                    if asset.mediaType == .image {
                        ids.append(asset.localIdentifier + ":edited")
                    }
                }

                if currentIds.count + ids.count > immichUpload.existBatchSize {
                    finalizeBatch()
                }
                if !ids.isEmpty {
                    currentIds.append(contentsOf: ids)
                    currentUnits += 1
                }
            }
            finalizeBatch()

            do {
                try immichPipeline.performExistSyncBatches(batches: batches, totalUnits: filtered.count)
            } catch {
                progressWrapped(.message("ERROR Immich: exists sync failed: \(error)"))
            }
        }

        var attempted = 0
        var completed = 0
        var skipped = 0
        var errors = 0

        var wasPaused = false
        var pauseIndex: Int? = nil

        func photoManifestKey(assetId: String, variant: String) -> String {
            "photo:\(assetId):\(variant)"
        }

        func photoSignature(asset: PHAsset, variant: String, resourceName: String?) -> String {
            let mod = asset.modificationDate?.timeIntervalSince1970 ?? 0
            let created = asset.creationDate?.timeIntervalSince1970 ?? 0
            return "v:\(variant);mod:\(mod);created:\(created);name:\(resourceName ?? "")"
        }

        func relativePathInDestination(_ destination: URL, _ file: URL) -> String {
            let root = destination.standardizedFileURL.path.hasSuffix("/") ? destination.standardizedFileURL.path : destination.standardizedFileURL.path + "/"
            let p = file.standardizedFileURL.path
            if p.hasPrefix(root) { return String(p.dropFirst(root.count)) }
            return file.lastPathComponent
        }

        func shouldSkipByManifest(key: String, signature: String, desiredURL: URL?) -> Bool {
            guard let manifest, let dest = options.folderExport?.destination else { return false }
            guard let desiredURL else { return false }
            guard let entry = manifest.get(key: key), entry.deletedAt == nil else { return false }
            if entry.signature != signature { return false }
            if entry.relPath != relativePathInDestination(dest, desiredURL) { return false }
            return FileManager.default.fileExists(atPath: desiredURL.path)
        }

        func upsertManifestIfPossible(key: String, signature: String, desiredURL: URL?) {
            guard let manifest, let dest = options.folderExport?.destination else { return }
            guard let desiredURL else { return }
            let rel = relativePathInDestination(dest, desiredURL)
            let attrs = try? FileManager.default.attributesOfItem(atPath: desiredURL.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            try? manifest.upsert(ManifestEntry(
                key: key,
                relPath: rel,
                signature: signature,
                size: size,
                mtime: mtime,
                lastSeenRunId: runId,
                deletedAt: nil
            ))
        }

        for (i, asset) in filtered.enumerated() {
            // Check run state at start of each iteration
            let state = runState()
            if state == .cancelled { break }
            if state == .paused {
                wasPaused = true
                pauseIndex = i
                progress(.paused(at: i, total: filtered.count))
                break
            }

            attempted += 1

            let created = usableCaptureDate(asset.creationDate, calendar: calendar)
            let folder = created.map { ymdFolder(for: $0, calendar: calendar) } ?? "Unknown Date"
            let outDir: URL? = options.folderExport.map { folderExport in
                folderExport.destination.appendingPathComponent(folder, isDirectory: true)
            }
            if let outDir { try ensureDir(outDir) }

            let base = baseFilename(for: created, localIdentifier: asset.localIdentifier)
            let resources = PHAssetResource.assetResources(for: asset)

            progress(.exporting(index: i + 1, total: filtered.count, localIdentifier: asset.localIdentifier, baseName: base, mediaTypeRaw: asset.mediaType.rawValue))

            let albumsForAsset = albumMembershipByAssetId[asset.localIdentifier].map { Array($0) } ?? []
            let onImmichAssetId: (@Sendable (String?) -> Void)?
            if let collector = albumCollector, !albumsForAsset.isEmpty {
                onImmichAssetId = { id in
                    guard let id else { return }
                    collector.add(assetId: id, to: albumsForAsset)
                }
            } else {
                onImmichAssetId = nil
            }

            var assetHadAnyWork = false
            var assetHadAnyError = false
            var assetAllSkipped = true

            if let immichPipeline {
                var ids: [String] = []
                ids.reserveCapacity(4)

                func firstResource(_ type: PHAssetResourceType) -> PHAssetResource? {
                    resources.first { $0.type == type }
                }

                if options.mode == .originals || options.mode == .both {
                    let still = firstResource(.fullSizePhoto) ?? firstResource(.photo)
                    let video = firstResource(.fullSizeVideo) ?? firstResource(.video)
                    let paired = firstResource(.pairedVideo)
                    if paired != nil { ids.append(asset.localIdentifier + ":pairedVideo") }
                    if still != nil { ids.append(asset.localIdentifier) }
                    if paired == nil, video != nil { ids.append(asset.localIdentifier + ":video") }
                }

                if options.mode == .edited || options.mode == .both {
                    if asset.mediaType == .image {
                        ids.append(asset.localIdentifier + ":edited")
                    }
                }

                immichPipeline.submitExistChecks(deviceAssetIds: ids)
            }

            if options.mode == .originals || options.mode == .both {
                func firstResource(_ type: PHAssetResourceType) -> PHAssetResource? {
                    resources.first { $0.type == type }
                }

                let still = firstResource(.fullSizePhoto) ?? firstResource(.photo)
                let video = firstResource(.fullSizeVideo) ?? firstResource(.video)
                let paired = firstResource(.pairedVideo)
                let adjustments = options.includeAdjustmentData ? firstResource(.adjustmentData) : nil

                var livePhotoVideoId: String?

                if let paired {
                    assetHadAnyWork = true
                    let ext = extFromFilename(paired.originalFilename) ?? "mov"
                    let desiredURL = outDir?.appendingPathComponent("\(base)_live.\(ext)", isDirectory: false)
                    let key = photoManifestKey(assetId: asset.localIdentifier, variant: "pairedVideo")
                    let sig = photoSignature(asset: asset, variant: "pairedVideo", resourceName: paired.originalFilename)
                    if options.backupMode != .full, shouldSkipByManifest(key: key, signature: sig, desiredURL: desiredURL) {
                        upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                    } else {
                        do {
                            let outcome = try exportResourceToOutputs(
                                resource: paired,
                                asset: asset,
                                deviceAssetIdSuffix: ":pairedVideo",
                                filenameOverride: "\(base)_live.\(ext)",
                                desiredFolderURL: desiredURL,
                                options: options,
                                immichPipeline: immichPipeline,
                                progress: progressWrapped,
                                livePhotoVideoId: nil,
                                awaitImmichAssetId: true,
                                onImmichAssetId: onImmichAssetId
                            )
                            if let folderOutcome = outcome.folderOutcome, case .exported = folderOutcome { assetAllSkipped = false }
                            livePhotoVideoId = outcome.immichAssetId
                            upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                        } catch {
                            assetHadAnyError = true
                            errors += 1
                            progressWrapped(.message("ERROR processing live video: \(error)"))
                        }
                    }
                }

                if let still {
                    assetHadAnyWork = true
                    let ext = extFromFilename(still.originalFilename) ?? "bin"
                    let desiredURL = outDir?.appendingPathComponent("\(base).\(ext)", isDirectory: false)
                    let key = photoManifestKey(assetId: asset.localIdentifier, variant: "original")
                    let sig = photoSignature(asset: asset, variant: "original", resourceName: still.originalFilename)
                    if options.backupMode != .full, shouldSkipByManifest(key: key, signature: sig, desiredURL: desiredURL) {
                        upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                    } else {
                        do {
                            let outcome = try exportResourceToOutputs(
                                resource: still,
                                asset: asset,
                                deviceAssetIdSuffix: "",
                                filenameOverride: "\(base).\(ext)",
                                desiredFolderURL: desiredURL,
                                options: options,
                                immichPipeline: immichPipeline,
                                progress: progressWrapped,
                                livePhotoVideoId: livePhotoVideoId,
                                awaitImmichAssetId: false,
                                onImmichAssetId: onImmichAssetId
                            )
                            if let folderOutcome = outcome.folderOutcome, case .exported = folderOutcome { assetAllSkipped = false }
                            upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                        } catch {
                            assetHadAnyError = true
                            errors += 1
                            progressWrapped(.message("ERROR processing still: \(error)"))
                        }
                    }
                }

                if let adjustments {
                    assetHadAnyWork = true
                    let ext = extFromFilename(adjustments.originalFilename) ?? extFromUTI(adjustments.uniformTypeIdentifier) ?? "aae"
                    let desiredURL = outDir?.appendingPathComponent("\(base)_adjustments.\(ext)", isDirectory: false)
                    let key = photoManifestKey(assetId: asset.localIdentifier, variant: "adjustments")
                    let sig = photoSignature(asset: asset, variant: "adjustments", resourceName: adjustments.originalFilename)
                    if options.backupMode != .full, shouldSkipByManifest(key: key, signature: sig, desiredURL: desiredURL) {
                        upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                    } else {
                        do {
                            let outcome = try exportResourceToOutputs(
                                resource: adjustments,
                                asset: asset,
                                deviceAssetIdSuffix: ":adjustments",
                                filenameOverride: "\(base)_adjustments.\(ext)",
                                desiredFolderURL: desiredURL,
                                options: options,
                                immichPipeline: immichPipeline,
                                progress: progressWrapped,
                                livePhotoVideoId: nil,
                                awaitImmichAssetId: false,
                                onImmichAssetId: onImmichAssetId
                            )
                            if let folderOutcome = outcome.folderOutcome, case .exported = folderOutcome { assetAllSkipped = false }
                            upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                        } catch {
                            assetHadAnyError = true
                            errors += 1
                            progressWrapped(.message("ERROR processing adjustments: \(error)"))
                        }
                    }
                }

                if paired == nil, let video {
                    assetHadAnyWork = true
                    let ext = extFromFilename(video.originalFilename) ?? "mov"
                    let suffix = asset.mediaSubtypes.contains(.photoLive) ? "_live" : ""
                    let desiredURL = outDir?.appendingPathComponent("\(base)\(suffix).\(ext)", isDirectory: false)
                    let key = photoManifestKey(assetId: asset.localIdentifier, variant: "video")
                    let sig = photoSignature(asset: asset, variant: "video", resourceName: video.originalFilename)
                    if options.backupMode != .full, shouldSkipByManifest(key: key, signature: sig, desiredURL: desiredURL) {
                        upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                    } else {
                        do {
                            let outcome = try exportResourceToOutputs(
                                resource: video,
                                asset: asset,
                                deviceAssetIdSuffix: ":video",
                                filenameOverride: "\(base)\(suffix).\(ext)",
                                desiredFolderURL: desiredURL,
                                options: options,
                                immichPipeline: immichPipeline,
                                progress: progressWrapped,
                                livePhotoVideoId: nil,
                                awaitImmichAssetId: false,
                                onImmichAssetId: onImmichAssetId
                            )
                            if let folderOutcome = outcome.folderOutcome, case .exported = folderOutcome { assetAllSkipped = false }
                            upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                        } catch {
                            assetHadAnyError = true
                            errors += 1
                            progressWrapped(.message("ERROR processing video: \(error)"))
                        }
                    }
                }
            }

            if options.mode == .edited || options.mode == .both {
                if asset.mediaType == .image {
                    assetHadAnyWork = true
                    let key = photoManifestKey(assetId: asset.localIdentifier, variant: "edited")
                    let sig = photoSignature(asset: asset, variant: "edited", resourceName: "rendered")
                    if options.backupMode != .full,
                       let manifest,
                       let dest = options.folderExport?.destination,
                       let entry = manifest.get(key: key),
                       entry.deletedAt == nil,
                       entry.signature == sig
                    {
                        let url = dest.appendingPathComponent(entry.relPath, isDirectory: false)
                        if FileManager.default.fileExists(atPath: url.path) {
                            // Touch lastSeenRunId for mirror mode safety.
                            try? manifest.upsert(ManifestEntry(
                                key: key,
                                relPath: entry.relPath,
                                signature: sig,
                                size: entry.size,
                                mtime: entry.mtime,
                                lastSeenRunId: runId,
                                deletedAt: nil
                            ))
                        } else {
                            // Fall back to rendering if file is missing.
                            do {
                                let outcome = try exportEditedImageToOutputs(
                                    asset: asset,
                                    baseName: base,
                                    desiredFolderDir: outDir,
                                    options: options,
                                    immichPipeline: immichPipeline,
                                    progress: progressWrapped,
                                    onImmichAssetId: onImmichAssetId
                                )
                                if let folderOutcome = outcome.folderOutcome, case .exported = folderOutcome { assetAllSkipped = false }
                                if let folderOutcome = outcome.folderOutcome {
                                    switch folderOutcome {
                                    case .exported(let url):
                                        upsertManifestIfPossible(key: key, signature: sig, desiredURL: url)
                                    case .skippedIdentical(let existing):
                                        upsertManifestIfPossible(key: key, signature: sig, desiredURL: existing)
                                    }
                                }
                            } catch {
                                assetHadAnyError = true
                                errors += 1
                                progressWrapped(.message("ERROR exporting edited image: \(error)"))
                            }
                        }
                    } else {
                        do {
                            let outcome = try exportEditedImageToOutputs(
                                asset: asset,
                                baseName: base,
                                desiredFolderDir: outDir,
                                options: options,
                                immichPipeline: immichPipeline,
                                progress: progressWrapped,
                                onImmichAssetId: onImmichAssetId
                            )
                            if let folderOutcome = outcome.folderOutcome, case .exported = folderOutcome { assetAllSkipped = false }
                            if let folderOutcome = outcome.folderOutcome {
                                switch folderOutcome {
                                case .exported(let url):
                                    upsertManifestIfPossible(key: key, signature: sig, desiredURL: url)
                                case .skippedIdentical(let existing):
                                    upsertManifestIfPossible(key: key, signature: sig, desiredURL: existing)
                                }
                            }
                        } catch {
                            assetHadAnyError = true
                            errors += 1
                            progressWrapped(.message("ERROR exporting edited image: \(error)"))
                        }
                    }
                }
            }

            // Track asset processing result
            if !assetHadAnyWork {
                skipped += 1
                processedIds.insert(asset.localIdentifier)
            } else if assetHadAnyError {
                completed += 1
                errorIds.insert(asset.localIdentifier)
                processedIds.insert(asset.localIdentifier)
            } else if assetAllSkipped {
                skipped += 1
                processedIds.insert(asset.localIdentifier)
            } else {
                completed += 1
                processedIds.insert(asset.localIdentifier)
            }
        }

        // Only wait for Immich pipeline if not cancelled
        if !shouldCancel() {
            immichPipeline?.finishAndWait()
        }

        if !shouldCancel(),
           let immichUpload = options.immichUpload,
           immichUpload.syncAlbums,
           let immichClient,
           let albumCollector
        {
            let entries = albumCollector.snapshot()
            if !entries.isEmpty {
                progressWrapped(.message("Immich: syncing albums…"))

                let titleCounts: [String: Int] = entries.reduce(into: [:]) { acc, e in
                    acc[e.album.title, default: 0] += 1
                }

                let existingAlbums: [ImmichClient.AlbumDto]
                do {
                    existingAlbums = try runSync { try await immichClient.listAlbums() }
                } catch {
                    progressWrapped(.message("ERROR Immich: could not list albums: \(error)"))
                    existingAlbums = []
                }

                var immichAlbumIdByName: [String: String] = [:]
                for a in existingAlbums {
                    if let name = a.albumName {
                        immichAlbumIdByName[name] = a.id
                    }
                }

                func immichAlbumName(for album: PhotoBackupOptions.AlbumInfo) -> String {
                    if (titleCounts[album.title] ?? 0) <= 1 { return album.title }
                    return "\(album.title) (Photos \(makeAssetIdShort(album.localIdentifier)))"
                }

                func chunked<T>(_ items: [T], size: Int) -> [[T]] {
                    guard size > 0 else { return [items] }
                    var out: [[T]] = []
                    var idx = 0
                    while idx < items.count {
                        out.append(Array(items[idx..<min(items.count, idx + size)]))
                        idx += size
                    }
                    return out
                }

                for entry in entries {
                    if shouldCancel() { break }
                    let albumName = immichAlbumName(for: entry.album)
                    let albumId: String

                    if let existingId = immichAlbumIdByName[albumName] {
                        albumId = existingId
                    } else {
                        do {
                            let created = try runSync { try await immichClient.createAlbum(name: albumName) }
                            immichAlbumIdByName[albumName] = created.id
                            albumId = created.id
                            progressWrapped(.message("Immich: created album “\(albumName)”"))
                        } catch {
                            progressWrapped(.message("ERROR Immich: could not create album “\(albumName)”: \(error)"))
                            continue
                        }
                    }

                    for batch in chunked(entry.assetIds, size: 500) {
                        if shouldCancel() { break }
                        do {
                            try runSync { try await immichClient.addAssetsToAlbum(albumId: albumId, assetIds: batch) }
                        } catch {
                            progressWrapped(.message("ERROR Immich: could not add assets to album “\(albumName)”: \(error)"))
                            break
                        }
                    }
                }

                progressWrapped(.message("Immich: album sync complete"))
            }
        }

        if options.backupMode == .mirror,
           !wasPaused,
           let manifest,
           let dest = options.folderExport?.destination,
           !options.dryRun
        {
            let keys = manifest.keysNotSeen(runId: runId).filter { $0.hasPrefix("photo:") }
            for key in keys {
                if shouldCancel() { break }
                guard let entry = manifest.get(key: key), entry.deletedAt == nil else { continue }
                let url = dest.appendingPathComponent(entry.relPath, isDirectory: false)
                if FileManager.default.fileExists(atPath: url.path) {
                    do {
                        try FileManager.default.removeItem(at: url)
                        try manifest.markDeleted(key: key)
                    } catch {
                        progressWrapped(.message("ERROR Mirror: failed to delete \(entry.relPath): \(error)"))
                    }
                } else {
                    _ = try? manifest.markDeleted(key: key)
                }
            }
        }

        errors += immichUploadErrorCounter.value

        return PhotoBackupResult(
            attemptedAssets: attempted,
            completedAssets: completed,
            skippedAssets: skipped,
            errorCount: errors,
            wasPaused: wasPaused,
            processedAssetIds: processedIds,
            errorAssetIds: errorIds,
            pauseIndex: pauseIndex
        )
    }
}

// MARK: - Naming & Dates

func makeAssetIdShort(_ localIdentifier: String) -> String {
    let first = localIdentifier.split(separator: "/").first.map(String.init) ?? localIdentifier
    let cleaned = first.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "", options: .regularExpression)
    return String(cleaned.prefix(10)).isEmpty ? "asset" : String(cleaned.prefix(10))
}

func ymdFolder(for date: Date, calendar: Calendar) -> String {
    let comps = calendar.dateComponents([.year, .month, .day], from: date)
    let y = comps.year ?? 0
    let m = comps.month ?? 0
    let d = comps.day ?? 0
    return String(format: "%04d/%02d/%02d", y, m, d)
}

func usableCaptureDate(_ date: Date?, calendar: Calendar) -> Date? {
    guard let date else { return nil }
    let year = calendar.component(.year, from: date)
    return year >= 1900 ? date : nil
}

func baseFilename(for date: Date?, localIdentifier: String) -> String {
    let id = makeAssetIdShort(localIdentifier)
    guard let date else { return "unknown_\(id)" }
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = .current
    df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return "\(df.string(from: date))_\(id)"
}

func extFromFilename(_ name: String) -> String? {
    let ext = (name as NSString).pathExtension
    return ext.isEmpty ? nil : ext.lowercased()
}

func extFromUTI(_ uti: String?) -> String? {
    guard let uti else { return nil }
    if let type = UTType(uti), let ext = type.preferredFilenameExtension {
        return ext.lowercased()
    }
    return nil
}

func ensureDir(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

func uniqueURL(_ desired: URL) -> URL {
    if !FileManager.default.fileExists(atPath: desired.path) {
        return desired
    }
    let base = desired.deletingPathExtension().lastPathComponent
    let ext = desired.pathExtension
    let dir = desired.deletingLastPathComponent()
    var i = 2
    while true {
        let name = ext.isEmpty ? "\(base)_\(i)" : "\(base)_\(i).\(ext)"
        let candidate = dir.appendingPathComponent(name, isDirectory: false)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        i += 1
    }
}

func atomicMove(from tmp: URL, to dst: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: dst.path) {
        _ = try fm.replaceItemAt(dst, withItemAt: tmp, backupItemName: nil, options: [.usingNewMetadataOnly])
    } else {
        try fm.moveItem(at: tmp, to: dst)
    }
}

// MARK: - Hashing & Collisions

func sha256File(_ url: URL) throws -> (size: UInt64, hashHex: String) {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
        let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
        if data.isEmpty { break }
        hasher.update(data: data)
    }
    let digest = hasher.finalize()
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return (size, hex)
}

public enum ExportOutcome: Sendable {
    case exported(url: URL)
    case skippedIdentical(existing: URL)
}

func placeTempFile(
    tmpURL: URL,
    desiredURL: URL,
    collisionPolicy: PhotoBackupOptions.CollisionPolicy
) throws -> ExportOutcome {
    switch collisionPolicy {
    case .skipIdenticalElseRename:
        if !FileManager.default.fileExists(atPath: desiredURL.path) {
            try atomicMove(from: tmpURL, to: desiredURL)
            return .exported(url: desiredURL)
        }

        let tmpInfo = try sha256File(tmpURL)
        let existingInfo: (size: UInt64, hashHex: String)
        do {
            existingInfo = try sha256File(desiredURL)
        } catch {
            // If we can't hash the existing file, fall back to renaming to avoid clobbering.
            let alt = uniqueURL(desiredURL)
            try atomicMove(from: tmpURL, to: alt)
            return .exported(url: alt)
        }

        if tmpInfo.size == existingInfo.size, tmpInfo.hashHex == existingInfo.hashHex {
            try? FileManager.default.removeItem(at: tmpURL)
            return .skippedIdentical(existing: desiredURL)
        }

        let alt = uniqueURL(desiredURL)
        try atomicMove(from: tmpURL, to: alt)
        return .exported(url: alt)
    }
}

// MARK: - PhotoKit export helpers

/// Classifies underlying PhotoKit/Cocoa errors into ExportError cases
private func classifyExportError(_ error: Error, filename: String) -> ExportError {
    let nsError = error as NSError

    // Check for PHPhotosErrorDomain errors
    if nsError.domain == "PHPhotosErrorDomain" {
        switch nsError.code {
        case -1:
            // PHPhotosErrorDomain Code=-1 often indicates iCloud issues
            return .iCloudDownloadFailed(underlyingError: error, filename: filename)
        case 3311:
            // Authorization issue
            return .assetUnavailable(reason: "Authorization denied", filename: filename)
        case 3164:
            // Asset not available
            return .assetUnavailable(reason: "Asset not found", filename: filename)
        default:
            break
        }
    }

    // Check for CloudPhotoLibraryErrorDomain
    if nsError.domain == "CloudPhotoLibraryErrorDomain" {
        return .iCloudDownloadFailed(underlyingError: error, filename: filename)
    }

    // Check for NSCocoaErrorDomain errors
    if nsError.domain == NSCocoaErrorDomain {
        switch nsError.code {
        case 4101:  // "Couldn't communicate with a helper application"
            // Check underlying error for CloudPhotoLibrary issues
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == "CloudPhotoLibraryErrorDomain" {
                return .iCloudDownloadFailed(underlyingError: error, filename: filename)
            }
            return .exportFailed(underlyingError: error, filename: filename)
        case 4097:  // Connection service issue
            return .iCloudDownloadFailed(underlyingError: error, filename: filename)
        case -1:    // Generic error, often iCloud-related
            return .iCloudDownloadFailed(underlyingError: error, filename: filename)
        default:
            break
        }
    }

    // Check for cancellation
    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
        return .cancelled(filename: filename)
    }

    // Check for network-related errors
    if nsError.domain == NSURLErrorDomain {
        switch nsError.code {
        case NSURLErrorTimedOut:
            return .timeout(duration: 0, filename: filename)
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost:
            return .iCloudDownloadFailed(underlyingError: error, filename: filename)
        default:
            break
        }
    }

    // Check for our custom timeout errors
    if nsError.domain == "export" && nsError.code == 408 {
        return .timeout(duration: 0, filename: filename)
    }
    if nsError.domain == "edited" && nsError.code == 408 {
        return .timeout(duration: 0, filename: filename)
    }

    // Default: non-retryable export failure
    return .exportFailed(underlyingError: error, filename: filename)
}

func exportResourceToTemp(
    _ resource: PHAssetResource,
    tempDir: URL,
    networkAccessAllowed: Bool,
    timeoutSeconds: TimeInterval,
    iCloudTimeoutMultiplier: Double,
    retryConfiguration: RetryConfiguration,
    dryRun: Bool,
    progressCallback: ((_ progress: Double, _ isICloud: Bool) -> Void)? = nil
) throws -> URL {
    if dryRun {
        return tempDir.appendingPathComponent("dryrun-\(UUID().uuidString)", isDirectory: false)
    }

    let filename = resource.originalFilename
    var lastError: Error?
    let maxAttempts = retryConfiguration.maxRetries + 1

    for attempt in 0..<maxAttempts {
        let tmpURL = tempDir.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: false)

        do {
            try performSingleResourceExport(
                resource: resource,
                tmpURL: tmpURL,
                networkAccessAllowed: networkAccessAllowed,
                timeoutSeconds: timeoutSeconds,
                iCloudTimeoutMultiplier: iCloudTimeoutMultiplier,
                progressCallback: progressCallback
            )
            return tmpURL
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            lastError = error

            // Classify error and determine if retryable
            let classifiedError = classifyExportError(error, filename: filename)

            guard classifiedError.isRetryable, attempt < maxAttempts - 1 else {
                throw classifiedError
            }

            // Calculate delay and wait before retry
            let delay = retryConfiguration.delay(forAttempt: attempt)
            Thread.sleep(forTimeInterval: delay)
        }
    }

    // Should not reach here, but handle gracefully
    throw lastError ?? ExportError.exportFailed(
        underlyingError: NSError(domain: "export", code: -1),
        filename: filename
    )
}

/// Single attempt helper for resource export with iCloud progress tracking
private func performSingleResourceExport(
    resource: PHAssetResource,
    tmpURL: URL,
    networkAccessAllowed: Bool,
    timeoutSeconds: TimeInterval,
    iCloudTimeoutMultiplier: Double,
    progressCallback: ((_ progress: Double, _ isICloud: Bool) -> Void)?
) throws {
    let sema = DispatchSemaphore(value: 0)
    var writeError: Error?
    let tracker = iCloudDownloadTracker()

    let opts = PHAssetResourceRequestOptions()
    opts.isNetworkAccessAllowed = networkAccessAllowed

    // Set up progress handler to detect iCloud downloads
    opts.progressHandler = { progress in
        tracker.reportProgress(progress)
        progressCallback?(progress, true)
    }

    PHAssetResourceManager.default().writeData(for: resource, toFile: tmpURL, options: opts) { err in
        writeError = err
        sema.signal()
    }

    // Dynamic timeout - extend if iCloud download detected
    let checkInterval: TimeInterval = 1.0
    var elapsed: TimeInterval = 0
    var effectiveTimeout = timeoutSeconds

    while elapsed < effectiveTimeout {
        let waitResult = sema.wait(timeout: .now() + checkInterval)
        if waitResult == .success {
            break
        }
        elapsed += checkInterval

        // If iCloud download in progress, extend timeout
        if tracker.isDownloading {
            effectiveTimeout = max(effectiveTimeout, timeoutSeconds * iCloudTimeoutMultiplier)
        }
    }

    if elapsed >= effectiveTimeout {
        throw NSError(domain: "export", code: 408, userInfo: [
            NSLocalizedDescriptionKey: "Timed out exporting resource (\(resource.originalFilename))."
        ])
    }

    if let writeError {
        throw writeError
    }
}

func exportEditedImageToTemp(
    asset: PHAsset,
    tempDir: URL,
    networkAccessAllowed: Bool,
    timeoutSeconds: TimeInterval,
    iCloudTimeoutMultiplier: Double,
    retryConfiguration: RetryConfiguration,
    dryRun: Bool,
    progressCallback: ((_ progress: Double, _ isICloud: Bool) -> Void)? = nil
) throws -> (tmpURL: URL, ext: String) {
    let filename = "edited image for \(asset.localIdentifier)"
    var lastError: Error?
    let maxAttempts = retryConfiguration.maxRetries + 1

    for attempt in 0..<maxAttempts {
        do {
            return try performSingleEditedImageExport(
                asset: asset,
                tempDir: tempDir,
                networkAccessAllowed: networkAccessAllowed,
                timeoutSeconds: timeoutSeconds,
                iCloudTimeoutMultiplier: iCloudTimeoutMultiplier,
                dryRun: dryRun,
                progressCallback: progressCallback
            )
        } catch {
            lastError = error
            let classifiedError = classifyExportError(error, filename: filename)

            guard classifiedError.isRetryable, attempt < maxAttempts - 1 else {
                throw classifiedError
            }

            let delay = retryConfiguration.delay(forAttempt: attempt)
            Thread.sleep(forTimeInterval: delay)
        }
    }

    throw lastError ?? ExportError.exportFailed(
        underlyingError: NSError(domain: "edited", code: -1),
        filename: filename
    )
}

/// Single attempt helper for edited image export with iCloud progress tracking
private func performSingleEditedImageExport(
    asset: PHAsset,
    tempDir: URL,
    networkAccessAllowed: Bool,
    timeoutSeconds: TimeInterval,
    iCloudTimeoutMultiplier: Double,
    dryRun: Bool,
    progressCallback: ((_ progress: Double, _ isICloud: Bool) -> Void)?
) throws -> (tmpURL: URL, ext: String) {
    let sema = DispatchSemaphore(value: 0)
    var resultData: Data?
    var resultUTI: String?
    var resultError: Error?
    let tracker = iCloudDownloadTracker()

    let opts = PHImageRequestOptions()
    opts.isNetworkAccessAllowed = networkAccessAllowed
    opts.deliveryMode = .highQualityFormat
    opts.version = .current

    // Progress handler for iCloud downloads
    opts.progressHandler = { progress, error, stop, info in
        tracker.reportProgress(progress)
        progressCallback?(progress, true)
    }

    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) { data, uti, _, info in
        resultData = data
        resultUTI = uti
        if let err = info?[PHImageErrorKey] as? NSError {
            resultError = err
        }
        sema.signal()
    }

    // Dynamic timeout - extend if iCloud download detected
    let checkInterval: TimeInterval = 1.0
    var elapsed: TimeInterval = 0
    var effectiveTimeout = timeoutSeconds

    while elapsed < effectiveTimeout {
        let waitResult = sema.wait(timeout: .now() + checkInterval)
        if waitResult == .success {
            break
        }
        elapsed += checkInterval

        if tracker.isDownloading {
            effectiveTimeout = max(effectiveTimeout, timeoutSeconds * iCloudTimeoutMultiplier)
        }
    }

    if elapsed >= effectiveTimeout {
        throw NSError(domain: "edited", code: 408, userInfo: [
            NSLocalizedDescriptionKey: "Timed out rendering edited image."
        ])
    }

    if let resultError { throw resultError }
    guard let data = resultData else {
        throw ExportError.assetUnavailable(reason: "No data returned", filename: asset.localIdentifier)
    }

    let ext = extFromUTI(resultUTI) ?? "jpg"
    if dryRun {
        return (tempDir.appendingPathComponent("dryrun-\(UUID().uuidString)"), ext)
    }

    let tmpURL = tempDir.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: false)
    try data.write(to: tmpURL)
    return (tmpURL, ext)
}

// MARK: - Immich

public struct ImmichServerInfo: Sendable {
    public var ping: String
}

struct ImmichUploadResult: Sendable {
    var id: String
    var status: String
}

final class ImmichClient {
    private let apiBase: URL
    private let apiKey: String
    private let session: URLSession

    init(serverURL: URL, apiKey: String, session: URLSession = .shared) {
        if serverURL.lastPathComponent == "api" {
            self.apiBase = serverURL
        } else {
            self.apiBase = serverURL.appendingPathComponent("api", isDirectory: false)
        }
        self.apiKey = apiKey
        self.session = session
    }

    func ping() async throws {
        _ = try await requestJSON(method: "GET", path: "server/ping", body: Optional<Data>.none) as ServerPingResponse
    }

    func getMe() async throws {
        _ = try await requestJSON(method: "GET", path: "users/me", body: Optional<Data>.none) as UserMeResponse
    }

    func getAssetStatistics() async throws -> AssetStatisticsResponse {
        try await requestJSON(method: "GET", path: "assets/statistics", body: Optional<Data>.none)
    }

    func checkExistingAssets(deviceId: String, deviceAssetIds: [String]) async throws -> Set<String> {
        let dto = CheckExistingAssetsDto(deviceId: deviceId, deviceAssetIds: deviceAssetIds)
        let body = try JSONEncoder().encode(dto)
        let resp: CheckExistingAssetsResponseDto = try await requestJSON(method: "POST", path: "assets/exist", body: body)
        return Set(resp.existingIds)
    }

    func bulkUploadCheck(items: [AssetBulkUploadCheckItem]) async throws -> [AssetBulkUploadCheckResult] {
        let dto = AssetBulkUploadCheckDto(assets: items)
        let body = try JSONEncoder().encode(dto)
        let resp: AssetBulkUploadCheckResponseDto = try await requestJSON(method: "POST", path: "assets/bulk-upload-check", body: body)
        return resp.results
    }

    struct AlbumDto: Decodable {
        let id: String
        let albumName: String?
    }

    func listAlbums() async throws -> [AlbumDto] {
        try await requestJSON(method: "GET", path: "albums", body: Optional<Data>.none)
    }

    func createAlbum(name: String) async throws -> AlbumDto {
        let body = try JSONSerialization.data(withJSONObject: ["albumName": name], options: [])
        return try await requestJSON(method: "POST", path: "albums", body: body)
    }

    func addAssetsToAlbum(albumId: String, assetIds: [String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["ids": assetIds], options: [])
        do {
            _ = try await requestRaw(method: "PUT", path: "albums/\(albumId)/assets", body: body)
        } catch {
            _ = try await requestRaw(method: "POST", path: "albums/\(albumId)/assets", body: body)
        }
    }

    func getAssetIdByDeviceId(deviceId: String, deviceAssetId: String) async throws -> String? {
        let candidatePaths = [
            "assets/device/\(deviceId)/\(deviceAssetId)",
            "assets/assetByDeviceId/\(deviceId)/\(deviceAssetId)"
        ]
        for path in candidatePaths {
            do {
                let data = try await requestRaw(method: "GET", path: path, body: Optional<Data>.none)
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = obj["id"] as? String {
                    return id
                }
                struct AssetIdDto: Decodable { let id: String }
                if let dto = try? JSONDecoder().decode(AssetIdDto.self, from: data) {
                    return dto.id
                }
            } catch {
                continue
            }
        }
        return nil
    }

    func deleteAssets(assetIds: [String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["ids": assetIds], options: [])
        _ = try await requestRaw(method: "DELETE", path: "assets", body: body)
    }

    func uploadAsset(
        fileURL: URL,
        sha1Hex: String?,
        deviceId: String,
        deviceAssetId: String,
        filename: String,
        fileCreatedAt: Date,
        fileModifiedAt: Date,
        durationSeconds: Double?,
        isFavorite: Bool?,
        livePhotoVideoId: String?,
        metadata: [[String: Any]]
    ) async throws -> ImmichUploadResult {
        var fields: [(String, String)] = []
        fields.append(("deviceId", deviceId))
        fields.append(("deviceAssetId", deviceAssetId))
        fields.append(("fileCreatedAt", iso8601(fileCreatedAt)))
        fields.append(("fileModifiedAt", iso8601(fileModifiedAt)))
        fields.append(("filename", filename))
        if let durationSeconds {
            fields.append(("duration", String(durationSeconds)))
        }
        if let isFavorite {
            fields.append(("isFavorite", isFavorite ? "true" : "false"))
        }
        if let livePhotoVideoId {
            fields.append(("livePhotoVideoId", livePhotoVideoId))
        }

        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [])
        let metadataString = String(decoding: metadataData, as: UTF8.self)
        fields.append(("metadata", metadataString))

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: apiBase.appendingPathComponent("assets", isDirectory: false))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        if let sha1Hex {
            req.setValue(sha1Hex, forHTTPHeaderField: "x-immich-checksum")
        }

        let (tmpURL, contentLength) = try makeMultipartTempFile(
            boundary: boundary,
            fields: fields,
            fileFieldName: "assetData",
            fileURL: fileURL
        )
        req.setValue(String(contentLength), forHTTPHeaderField: "Content-Length")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let (data, response) = try await session.upload(for: req, fromFile: tmpURL)
        try ensureHTTP(response, data: data)

        let decoded = try JSONDecoder().decode(AssetUploadResponse.self, from: data)
        return ImmichUploadResult(id: decoded.id, status: decoded.status)
    }

    private func requestRaw(method: String, path: String, body: Data?) async throws -> Data {
        var req = URLRequest(url: apiBase.appendingPathComponent(path, isDirectory: false))
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        try ensureHTTP(response, data: data)
        return data
    }

    private func requestJSON<T: Decodable>(method: String, path: String, body: Data?) async throws -> T {
        let data = try await requestRaw(method: method, path: path, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private final class ImmichUploadPipeline {
    private struct WorkItem {
        let fileURL: URL
        let deleteAfterUpload: URL?
        let deviceId: String
        let deviceAssetId: String
        let filename: String
        let fileCreatedAt: Date
        let fileModifiedAt: Date
        let durationSeconds: Double?
        let isFavorite: Bool?
	        let livePhotoVideoId: String?
	        let metadata: [[String: Any]]
	        let awaitResult: Bool
            let onImmichAssetId: (@Sendable (String?) -> Void)?
	        let completion: (Result<String?, Error>) -> Void
	    }

    private let immich: ImmichUploadOptions
    private let client: ImmichClient
    private let progress: @Sendable (PhotoBackupProgress) -> Void
    private let shouldCancel: @Sendable () -> Bool

    private let stateQueue = DispatchQueue(label: "immich-pipeline-state")
    private let hashQueue = DispatchQueue(label: "immich-pipeline-hash", qos: .userInitiated, attributes: .concurrent)
    private let networkQueue = DispatchQueue(label: "immich-pipeline-network", qos: .userInitiated)
    private let uploadQueue = DispatchQueue(label: "immich-pipeline-upload", qos: .userInitiated, attributes: .concurrent)

    private let inFlightLimiter: DispatchSemaphore
    private let hashLimiter: DispatchSemaphore
    private let uploadLimiter: DispatchSemaphore
    private let group = DispatchGroup()

    private var existingDeviceAssetIds: Set<String> = []
    private var knownDeviceAssetIds: Set<String> = []
    private var existPendingSet: Set<String> = []
    private var existPendingFIFO: [String] = []
    private var existInProgress: Bool = false
	    private var existWaiters: [String: [DispatchSemaphore]] = [:]
	    private var didAnnounceBackgroundExist: Bool = false
	
	    private let existWaitTimeoutSeconds: TimeInterval = 0.25
	    private let existFlushDelaySeconds: TimeInterval = 1.0
	    private var existFlushTimer: DispatchSourceTimer?
	    private var lastExistReportChecked: Int = -1
	    private var lastExistReportTotal: Int = -1
	    private var existSyncCompleted: Bool = false

    private var pendingBulkCheckById: [String: (work: WorkItem, sha1: String)] = [:]
    private var pendingBulkCheckFIFO: [String] = []
    private var bulkCheckInProgress: Bool = false
    private let bulkCheckFlushDelaySeconds: TimeInterval = 1.0
    private var bulkCheckFlushTimer: DispatchSourceTimer?

    init(
        immich: ImmichUploadOptions,
        client: ImmichClient,
        progress: @escaping @Sendable (PhotoBackupProgress) -> Void,
        shouldCancel: @escaping @Sendable () -> Bool
    ) {
        self.immich = immich
        self.client = client
        self.progress = progress
        self.shouldCancel = shouldCancel
        self.inFlightLimiter = DispatchSemaphore(value: immich.maxInFlight)
        self.hashLimiter = DispatchSemaphore(value: immich.hashConcurrency)
        self.uploadLimiter = DispatchSemaphore(value: immich.uploadConcurrency)
    }

	            func submitExistChecks(deviceAssetIds: [String]) {
	        if existSyncCompleted { return }
	        guard !deviceAssetIds.isEmpty else { return }
	        stateQueue.async {
            if !self.didAnnounceBackgroundExist {
                self.didAnnounceBackgroundExist = true
                self.progress(.message("Immich: checking existing assets (background)..."))
            }

	            for id in deviceAssetIds {
	                if self.knownDeviceAssetIds.contains(id) { continue }
	                if self.existPendingSet.contains(id) { continue }
	                self.existPendingSet.insert(id)
	                self.existPendingFIFO.append(id)
	            }
	            self.reportExistProgressIfNeeded(force: false)
	            self.scheduleExistFlushIfNeeded()
	            self.maybeStartExistCheck()
	        }
	    }

	    func performExistSyncBatches(batches: [(ids: [String], units: Int)], totalUnits: Int) throws {
	        stateQueue.sync {
	            existSyncCompleted = false
	            didAnnounceBackgroundExist = true
	        }
	        progress(.message("Immich: syncing existing assets..."))
	        progress(.immichExistingCheck(checked: 0, total: totalUnits))

	        let maxConcurrent = max(1, min(immich.uploadConcurrency, 6))
	        let limiter = DispatchSemaphore(value: maxConcurrent)
	        let syncGroup = DispatchGroup()
	        let checkedCounter = AtomicCounter()

	        for batch in batches {
	            if shouldCancel() { break }
	            limiter.wait()
	            syncGroup.enter()
	            networkQueue.async { [weak self] in
	                defer {
	                    limiter.signal()
	                    syncGroup.leave()
	                }
	                guard let self else { return }
	                do {
	                    let existing = try runSync {
	                        try await self.client.checkExistingAssets(deviceId: self.immich.deviceId, deviceAssetIds: batch.ids)
	                    }
	                    self.stateQueue.sync {
	                        self.knownDeviceAssetIds.formUnion(batch.ids)
	                        self.existingDeviceAssetIds.formUnion(existing)
	                        for id in batch.ids {
	                            self.existPendingSet.remove(id)
	                            if let waiters = self.existWaiters.removeValue(forKey: id) {
	                                for s in waiters { s.signal() }
	                            }
	                        }
	                    }
	                } catch {
	                    self.progress(.message("ERROR Immich: /assets/exist sync batch failed (\(batch.ids.count) ids): \(error)"))
	                    self.stateQueue.sync {
	                        self.knownDeviceAssetIds.formUnion(batch.ids)
	                        for id in batch.ids {
	                            self.existPendingSet.remove(id)
	                            if let waiters = self.existWaiters.removeValue(forKey: id) {
	                                for s in waiters { s.signal() }
	                            }
	                        }
	                    }
	                }

	                checkedCounter.increment(by: batch.units)
	                self.progress(.immichExistingCheck(checked: min(checkedCounter.value, totalUnits), total: totalUnits))
	            }
	        }

	        syncGroup.wait()
	        stateQueue.sync {
	            existSyncCompleted = true
	        }
	        progress(.immichExistingCheck(checked: totalUnits, total: totalUnits))
	        progress(.message("Immich: exists sync complete"))
	    }

    func preloadExisting(deviceAssetIds: [String]) throws {
        guard !deviceAssetIds.isEmpty else { return }
        let deviceId = immich.deviceId
        var out = Set<String>()
        out.reserveCapacity(deviceAssetIds.count)
        for chunk in deviceAssetIds.chunked(into: immich.existBatchSize) {
            if shouldCancel() { break }
            let existing = try runSync { try await self.client.checkExistingAssets(deviceId: deviceId, deviceAssetIds: chunk) }
            out.formUnion(existing)
        }
        existingDeviceAssetIds = out
    }

    func enqueue(
        fileURL: URL,
        deleteAfterUpload: URL?,
        deviceAssetId: String,
        filename: String,
        fileCreatedAt: Date,
        fileModifiedAt: Date,
        durationSeconds: Double?,
        isFavorite: Bool?,
        livePhotoVideoId: String?,
        metadata: [[String: Any]],
        awaitResult: Bool,
        onImmichAssetId: (@Sendable (String?) -> Void)? = nil
    ) throws -> String? {
        if shouldCancel() {
            throw ExportError.cancelled(filename: filename)
        }

        let shouldUseFastExistSkip = !(immich.syncAlbums || immich.updateChangedAssets) && !immich.checksumPrecheck
        if shouldUseFastExistSkip, shouldSkipBecauseExists(deviceAssetId: deviceAssetId) {
            progress(.message("Immich: exists, skipping upload (\(deviceAssetId))"))
            if let deleteAfterUpload {
                try? FileManager.default.removeItem(at: deleteAfterUpload)
            }
            return nil
        }

        inFlightLimiter.wait()
        group.enter()

        let sema = DispatchSemaphore(value: 0)
        var awaited: Result<String?, Error>?

	        let completion: (Result<String?, Error>) -> Void = { [progress] result in
	            if awaitResult {
	                awaited = result
	                sema.signal()
	            }
            if case .failure(let error) = result {
                progress(.message("ERROR Immich upload failed (\(deviceAssetId)): \(error)"))
            }
        }

        let work = WorkItem(
            fileURL: fileURL,
            deleteAfterUpload: deleteAfterUpload,
            deviceId: immich.deviceId,
            deviceAssetId: deviceAssetId,
            filename: filename,
            fileCreatedAt: fileCreatedAt,
            fileModifiedAt: fileModifiedAt,
            durationSeconds: durationSeconds,
            isFavorite: isFavorite,
            livePhotoVideoId: livePhotoVideoId,
            metadata: metadata,
            awaitResult: awaitResult,
            onImmichAssetId: onImmichAssetId,
            completion: completion
        )

        if immich.skipHash {
            startUpload(work: work, sha1Hex: nil)
        } else if !immich.checksumPrecheck {
            hashLimiter.wait()
            hashQueue.async { [weak self] in
                defer { self?.hashLimiter.signal() }
                guard let self else { return }
                do {
                    let sha1 = try sha1HexFile(fileURL)
                    self.startUpload(work: work, sha1Hex: sha1)
                } catch {
                    self.finish(work: work, result: .failure(error))
                }
            }
        } else {
            hashLimiter.wait()
            hashQueue.async { [weak self] in
                defer { self?.hashLimiter.signal() }
                guard let self else { return }
                do {
                    let sha1 = try sha1HexFile(fileURL)
                    self.stateQueue.async {
                        self.pendingBulkCheckById[work.deviceAssetId] = (work: work, sha1: sha1)
                        self.pendingBulkCheckFIFO.append(work.deviceAssetId)
                        // If the caller is awaiting an Immich asset id (e.g. Live Photo paired video),
                        // we must not wait for a large batch threshold; force a bulk check immediately.
                        self.maybeStartBulkCheck(force: awaitResult)
                        self.scheduleBulkCheckFlushIfNeeded()
                    }
                } catch {
                    self.finish(work: work, result: .failure(error))
                }
            }
        }

        if awaitResult {
            sema.wait()
            return try awaited!.get()
        }
        return nil
    }

    func finishAndWait() {
        stateQueue.sync {
            self.maybeStartBulkCheck(force: true)
            self.maybeStartExistCheck(force: true)
            self.reportExistProgressIfNeeded(force: true)
        }
        group.wait()
    }

		    private func shouldSkipBecauseExists(deviceAssetId: String) -> Bool {
	        var syncDone = false
	        var known = false
	        var exists = false

	        // Fast path: if we already know, decide immediately.
	        stateQueue.sync {
	            syncDone = self.existSyncCompleted
	            if syncDone {
	                exists = self.existingDeviceAssetIds.contains(deviceAssetId)
	                return
	            }
	            if self.knownDeviceAssetIds.contains(deviceAssetId) {
	                known = true
	                exists = self.existingDeviceAssetIds.contains(deviceAssetId)
		            } else {
	                // Ensure it's queued for background checking.
	                if !self.existPendingSet.contains(deviceAssetId) {
	                    self.existPendingSet.insert(deviceAssetId)
	                    self.existPendingFIFO.append(deviceAssetId)
	                    self.scheduleExistFlushIfNeeded()
	                    self.maybeStartExistCheck()
	                }
	            }
		        }
	        if known { return exists }
	        if syncDone { return exists }

	        // Short wait to allow a background /assets/exist batch to land before we commit to hashing/upload.
	        let sema = DispatchSemaphore(value: 0)
	        stateQueue.sync {
            self.existWaiters[deviceAssetId, default: []].append(sema)
        }
        _ = sema.wait(timeout: .now() + existWaitTimeoutSeconds)

        stateQueue.sync {
            known = self.knownDeviceAssetIds.contains(deviceAssetId)
            exists = self.existingDeviceAssetIds.contains(deviceAssetId)
        }
        return known && exists
    }

	    private func maybeStartExistCheck(force: Bool = false) {
	        guard !existInProgress else { return }
	        guard !existPendingFIFO.isEmpty else { return }
	        if !force, existPendingFIFO.count < immich.existBatchSize { return }
	
	        existInProgress = true
	        cancelExistFlushTimer()
	        let batchIds = Array(existPendingFIFO.prefix(immich.existBatchSize))
	        existPendingFIFO.removeFirst(min(batchIds.count, existPendingFIFO.count))
	        progress(.message("Immich: /assets/exist batch starting (\(batchIds.count) ids)"))
	
	        networkQueue.async { [weak self] in
	            guard let self else { return }
	            let started = Date()
	            defer {
	                self.stateQueue.async {
	                    self.existInProgress = false
	                    self.scheduleExistFlushIfNeeded()
	                    self.maybeStartExistCheck(force: false)
	                }
	            }

	            do {
	                let existing = try runSync {
	                    try await self.client.checkExistingAssets(deviceId: self.immich.deviceId, deviceAssetIds: batchIds)
	                }
	                let ms = Int(Date().timeIntervalSince(started) * 1000)
	                self.stateQueue.async {
	                    self.progress(.message("Immich: /assets/exist batch complete (\(batchIds.count) ids, \(ms)ms)"))
	                    self.knownDeviceAssetIds.formUnion(batchIds)
	                    self.existingDeviceAssetIds.formUnion(existing)
	                    for id in batchIds {
	                        self.existPendingSet.remove(id)
                        if let waiters = self.existWaiters.removeValue(forKey: id) {
                            for s in waiters { s.signal() }
                        }
                    }
                    self.reportExistProgressIfNeeded(force: false)
                }
	            } catch {
	                // If exist-check fails, mark them as "known" (not existing) so we don't stall work;
	                // duplicates will be caught by checksum precheck or server-side handling.
	                let ms = Int(Date().timeIntervalSince(started) * 1000)
	                self.stateQueue.async {
	                    self.progress(.message("ERROR Immich: /assets/exist batch failed (\(batchIds.count) ids, \(ms)ms): \(error)"))
	                    self.knownDeviceAssetIds.formUnion(batchIds)
	                    for id in batchIds {
	                        self.existPendingSet.remove(id)
	                        if let waiters = self.existWaiters.removeValue(forKey: id) {
                            for s in waiters { s.signal() }
                        }
                    }
                    self.reportExistProgressIfNeeded(force: false)
                }
            }
        }
    }

	    private func reportExistProgressIfNeeded(force: Bool) {
        let checked = knownDeviceAssetIds.count
        let total = checked + existPendingSet.count
        guard total > 0 else { return }

        let isFirstReport = lastExistReportChecked < 0 || lastExistReportTotal < 0
        if !force, !isFirstReport {
            let checkedDelta = abs(checked - lastExistReportChecked)
            let totalDelta = abs(total - lastExistReportTotal)
            if checkedDelta < 200, totalDelta < 500 { return }
        }

	        lastExistReportChecked = checked
	        lastExistReportTotal = total
	        progress(.immichExistingCheck(checked: checked, total: total))
	    }

	    private func scheduleExistFlushIfNeeded() {
	        guard existFlushTimer == nil else { return }
	        guard !existInProgress else { return }
	        guard !existPendingFIFO.isEmpty else { return }
	        if existPendingFIFO.count >= immich.existBatchSize { return }

	        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
	        existFlushTimer = timer
	        timer.schedule(deadline: .now() + existFlushDelaySeconds)
	        timer.setEventHandler { [weak self] in
	            guard let self else { return }
	            self.cancelExistFlushTimer()
	            self.maybeStartExistCheck(force: true)
	        }
	        timer.resume()
	    }

	    private func cancelExistFlushTimer() {
	        existFlushTimer?.cancel()
	        existFlushTimer = nil
	    }

    private func maybeStartBulkCheck(force: Bool = false) {
        guard !bulkCheckInProgress else { return }
        guard !pendingBulkCheckFIFO.isEmpty else { return }
        if !force, pendingBulkCheckFIFO.count < immich.bulkCheckBatchSize { return }

        bulkCheckInProgress = true
        cancelBulkCheckFlushTimer()
        let batchIds = Array(pendingBulkCheckFIFO.prefix(immich.bulkCheckBatchSize))
        pendingBulkCheckFIFO.removeFirst(min(batchIds.count, pendingBulkCheckFIFO.count))
        let batch: [(work: WorkItem, sha1: String)] = batchIds.compactMap { pendingBulkCheckById.removeValue(forKey: $0) }

        networkQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateQueue.async {
                    self.bulkCheckInProgress = false
                    self.scheduleBulkCheckFlushIfNeeded()
                    self.maybeStartBulkCheck(force: false)
                }
            }

            do {
                let items: [AssetBulkUploadCheckItem] = batch.map { AssetBulkUploadCheckItem(checksum: $0.sha1, id: $0.work.deviceAssetId) }
                let results = try runSync { try await self.client.bulkUploadCheck(items: items) }
                let byId = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })

                for (work, sha1) in batch {
                    let r = byId[work.deviceAssetId]
                    if let r, r.action == "reject", r.reason == "duplicate" {
                        self.progress(.message("Immich: duplicate, skipping upload (\(work.deviceAssetId))"))
                        if let deleteAfterUpload = work.deleteAfterUpload {
                            try? FileManager.default.removeItem(at: deleteAfterUpload)
                        }
                        self.finish(work: work, result: .success(r.assetId))
                    } else {
                        let shouldReplaceExisting: Bool = self.stateQueue.sync {
                            self.immich.updateChangedAssets && self.existingDeviceAssetIds.contains(work.deviceAssetId)
                        }

                        if shouldReplaceExisting {
                            do {
                                let existingId = try runSync {
                                    try await self.client.getAssetIdByDeviceId(
                                        deviceId: self.immich.deviceId,
                                        deviceAssetId: work.deviceAssetId
                                    )
                                }
                                if let existingId {
                                    self.progress(.message("Immich: replacing existing asset (\(work.deviceAssetId))"))
                                    try runSync { try await self.client.deleteAssets(assetIds: [existingId]) }
                                } else {
                                    self.progress(.message("ERROR Immich: could not resolve existing asset id (\(work.deviceAssetId)); uploading may fail"))
                                }
                            } catch {
                                self.progress(.message("ERROR Immich: could not delete existing asset (\(work.deviceAssetId)): \(error)"))
                            }
                        }
                        self.startUpload(work: work, sha1Hex: sha1)
                    }
                }
            } catch {
                for (work, _) in batch {
                    self.finish(work: work, result: .failure(error))
                }
            }
        }
    }

    private func scheduleBulkCheckFlushIfNeeded() {
        guard bulkCheckFlushTimer == nil else { return }
        guard !bulkCheckInProgress else { return }
        guard !pendingBulkCheckFIFO.isEmpty else { return }
        if pendingBulkCheckFIFO.count >= immich.bulkCheckBatchSize { return }

        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        bulkCheckFlushTimer = timer
        timer.schedule(deadline: .now() + bulkCheckFlushDelaySeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.cancelBulkCheckFlushTimer()
            self.maybeStartBulkCheck(force: true)
        }
        timer.resume()
    }

    private func cancelBulkCheckFlushTimer() {
        bulkCheckFlushTimer?.cancel()
        bulkCheckFlushTimer = nil
    }

    private func startUpload(work: WorkItem, sha1Hex: String?) {
        uploadLimiter.wait()
        uploadQueue.async { [weak self] in
            guard let self else { return }
            defer { self.uploadLimiter.signal() }

            do {
                let result = try runSync {
                    try await self.client.uploadAsset(
                        fileURL: work.fileURL,
                        sha1Hex: sha1Hex,
                        deviceId: work.deviceId,
                        deviceAssetId: work.deviceAssetId,
                        filename: work.filename,
                        fileCreatedAt: work.fileCreatedAt,
                        fileModifiedAt: work.fileModifiedAt,
                        durationSeconds: work.durationSeconds,
                        isFavorite: work.isFavorite,
                        livePhotoVideoId: work.livePhotoVideoId,
                        metadata: work.metadata
                    )
                }
                self.progress(.message("Immich: upload \(result.status) (\(work.deviceAssetId))"))
                if let deleteAfterUpload = work.deleteAfterUpload {
                    try? FileManager.default.removeItem(at: deleteAfterUpload)
                }
                self.finish(work: work, result: .success(result.id))
            } catch {
                if let deleteAfterUpload = work.deleteAfterUpload {
                    try? FileManager.default.removeItem(at: deleteAfterUpload)
                }
                self.finish(work: work, result: .failure(error))
            }
        }
    }

    private func finish(work: WorkItem, result: Result<String?, Error>) {
        if case .success(let id) = result {
            work.onImmichAssetId?(id)
        }
        work.completion(result)
        group.leave()
        inFlightLimiter.signal()
    }
}

private func iso8601(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

private func ensureHTTP(_ response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200...299).contains(http.statusCode) else {
        let body = String(decoding: data.prefix(2000), as: UTF8.self)
        throw NSError(domain: "immich", code: http.statusCode, userInfo: [
            NSLocalizedDescriptionKey: "Immich HTTP \(http.statusCode): \(body)"
        ])
    }
}

private func makeMultipartTempFile(
    boundary: String,
    fields: [(String, String)],
    fileFieldName: String,
    fileURL: URL
) throws -> (url: URL, contentLength: Int) {
    var preamble = Data()
    preamble.reserveCapacity(2_048)

    for (name, value) in fields {
        preamble.append(Data("--\(boundary)\r\n".utf8))
        preamble.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        preamble.append(Data(value.utf8))
        preamble.append(Data("\r\n".utf8))
    }

    let filename = fileURL.lastPathComponent
    let mime = mimeType(for: fileURL)
    preamble.append(Data("--\(boundary)\r\n".utf8))
    preamble.append(Data("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(filename)\"\r\n".utf8))
    preamble.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))

    let closing = Data("\r\n--\(boundary)--\r\n".utf8)
    let fileSize: Int = {
        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return size
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber {
            return size.intValue
        }
        return -1
    }()
    if fileSize < 0 {
        throw NSError(domain: "immich", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "Could not determine upload file size: \(fileURL.path)"
        ])
    }

    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("immibridge-multipart", isDirectory: true)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let tmpURL = tmpDir.appendingPathComponent("upload-\(UUID().uuidString)", isDirectory: false)
    FileManager.default.createFile(atPath: tmpURL.path, contents: nil)

    let out = try FileHandle(forWritingTo: tmpURL)
    let input = try FileHandle(forReadingFrom: fileURL)
    defer {
        try? out.close()
        try? input.close()
    }

    try out.write(contentsOf: preamble)
    while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
        try out.write(contentsOf: chunk)
    }
    try out.write(contentsOf: closing)

    return (url: tmpURL, contentLength: preamble.count + fileSize + closing.count)
}

private func mimeType(for fileURL: URL) -> String {
    if let type = UTType(filenameExtension: fileURL.pathExtension), let mime = type.preferredMIMEType {
        return mime
    }
    return "application/octet-stream"
}

private struct ServerPingResponse: Decodable {
    let res: String?
    let message: String?
}

private struct UserMeResponse: Decodable {
    let id: String?
}

struct AssetStatisticsResponse: Decodable {
    let images: Int
    let videos: Int
    let total: Int
}

private struct CheckExistingAssetsDto: Encodable {
    let deviceId: String
    let deviceAssetIds: [String]
}

private struct CheckExistingAssetsResponseDto: Decodable {
    let existingIds: [String]
}

private struct AssetBulkUploadCheckDto: Encodable {
    let assets: [AssetBulkUploadCheckItem]
}

struct AssetBulkUploadCheckItem: Encodable {
    let checksum: String
    let id: String
}

private struct AssetBulkUploadCheckResponseDto: Decodable {
    let results: [AssetBulkUploadCheckResult]
}

struct AssetBulkUploadCheckResult: Decodable {
    let action: String
    let id: String
    let reason: String?
    let assetId: String?
}

private struct AssetUploadResponse: Decodable {
    let id: String
    let status: String
}

private func sha1HexFile(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = Insecure.SHA1()
    while true {
        let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
        if data.isEmpty { break }
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// MARK: - Outputs glue

struct OutputsOutcome: Sendable {
    var folderOutcome: ExportOutcome?
    var immichAssetId: String?
}

private func exportResourceToOutputs(
    resource: PHAssetResource,
    asset: PHAsset,
    deviceAssetIdSuffix: String,
    filenameOverride: String,
    desiredFolderURL: URL?,
    options: PhotoBackupOptions,
    immichPipeline: ImmichUploadPipeline?,
    progress: @escaping @Sendable (PhotoBackupProgress) -> Void,
    livePhotoVideoId: String?,
    awaitImmichAssetId: Bool,
    onImmichAssetId: (@Sendable (String?) -> Void)? = nil
) throws -> OutputsOutcome {
    let tmp = try exportResourceToTemp(
        resource,
        tempDir: options.tempDir,
        networkAccessAllowed: options.networkAccessAllowed,
        timeoutSeconds: options.requestTimeoutSeconds,
        iCloudTimeoutMultiplier: options.iCloudTimeoutMultiplier,
        retryConfiguration: options.retryConfiguration,
        dryRun: options.dryRun,
        progressCallback: { downloadProgress, isICloud in
            if isICloud {
                progress(.iCloudDownloading(
                    localIdentifier: asset.localIdentifier,
                    baseName: filenameOverride,
                    progress: downloadProgress,
                    attemptNumber: 1
                ))
            }
        }
    )

    var uploadURL: URL = tmp
    var folderOutcome: ExportOutcome?

    if let desiredFolderURL {
        let outcome = try placeTempFile(tmpURL: tmp, desiredURL: desiredFolderURL, collisionPolicy: options.collisionPolicy)
        folderOutcome = outcome
        switch outcome {
        case .exported(let url):
            uploadURL = url
        case .skippedIdentical(let existing):
            uploadURL = existing
        }
    }

    if let _ = options.immichUpload, let immichPipeline {
        let deviceAssetId = asset.localIdentifier + deviceAssetIdSuffix
        let createdAt = asset.creationDate ?? Date()
        let modifiedAt = asset.modificationDate ?? createdAt
        let duration: Double? = (asset.mediaType == .video) ? asset.duration : nil
        let meta: [[String: Any]] = [[
            "key": "mobile-app",
            "value": [
                "source": "iphoto-backup",
                "phAssetLocalIdentifier": asset.localIdentifier,
                "resourceType": resource.type.rawValue,
                "originalFilename": resource.originalFilename
            ]
        ]]

        let deleteAfterUpload = (desiredFolderURL == nil) ? tmp : nil
        let immichId = try immichPipeline.enqueue(
            fileURL: uploadURL,
            deleteAfterUpload: deleteAfterUpload,
            deviceAssetId: deviceAssetId,
            filename: filenameOverride,
            fileCreatedAt: createdAt,
            fileModifiedAt: modifiedAt,
            durationSeconds: duration,
            isFavorite: nil,
            livePhotoVideoId: livePhotoVideoId,
            metadata: meta,
            awaitResult: awaitImmichAssetId,
            onImmichAssetId: onImmichAssetId
        )
        return OutputsOutcome(folderOutcome: folderOutcome, immichAssetId: immichId)
    }

    if desiredFolderURL == nil, options.immichUpload != nil {
        try? FileManager.default.removeItem(at: tmp)
    }
    return OutputsOutcome(folderOutcome: folderOutcome, immichAssetId: nil)
}

private func exportEditedImageToOutputs(
    asset: PHAsset,
    baseName: String,
    desiredFolderDir: URL?,
    options: PhotoBackupOptions,
    immichPipeline: ImmichUploadPipeline?,
    progress: @escaping @Sendable (PhotoBackupProgress) -> Void,
    onImmichAssetId: (@Sendable (String?) -> Void)? = nil
) throws -> OutputsOutcome {
    let (tmp, ext) = try exportEditedImageToTemp(
        asset: asset,
        tempDir: options.tempDir,
        networkAccessAllowed: options.networkAccessAllowed,
        timeoutSeconds: options.requestTimeoutSeconds,
        iCloudTimeoutMultiplier: options.iCloudTimeoutMultiplier,
        retryConfiguration: options.retryConfiguration,
        dryRun: options.dryRun,
        progressCallback: { downloadProgress, isICloud in
            if isICloud {
                progress(.iCloudDownloading(
                    localIdentifier: asset.localIdentifier,
                    baseName: baseName,
                    progress: downloadProgress,
                    attemptNumber: 1
                ))
            }
        }
    )

    let filename = "\(baseName)_edited.\(ext)"
    var uploadURL: URL = tmp
    var folderOutcome: ExportOutcome?

    if let desiredFolderDir {
        let desired = desiredFolderDir.appendingPathComponent(filename, isDirectory: false)
        let outcome = try placeTempFile(tmpURL: tmp, desiredURL: desired, collisionPolicy: options.collisionPolicy)
        folderOutcome = outcome
        switch outcome {
        case .exported(let url):
            uploadURL = url
        case .skippedIdentical(let existing):
            uploadURL = existing
        }
    }

    if let _ = options.immichUpload, let immichPipeline {
        let deviceAssetId = asset.localIdentifier + ":edited"
        let createdAt = asset.creationDate ?? Date()
        let modifiedAt = asset.modificationDate ?? createdAt
        let meta: [[String: Any]] = [[
            "key": "mobile-app",
            "value": [
                "source": "iphoto-backup",
                "phAssetLocalIdentifier": asset.localIdentifier,
                "resourceType": "edited-render"
            ]
        ]]

        let deleteAfterUpload = (desiredFolderDir == nil) ? tmp : nil
        _ = try immichPipeline.enqueue(
            fileURL: uploadURL,
            deleteAfterUpload: deleteAfterUpload,
            deviceAssetId: deviceAssetId,
            filename: filename,
            fileCreatedAt: createdAt,
            fileModifiedAt: modifiedAt,
            durationSeconds: nil,
            isFavorite: nil,
            livePhotoVideoId: nil,
            metadata: meta,
            awaitResult: false,
            onImmichAssetId: onImmichAssetId
        )
        return OutputsOutcome(folderOutcome: folderOutcome, immichAssetId: nil)
    }

    if desiredFolderDir == nil, options.immichUpload != nil {
        try? FileManager.default.removeItem(at: tmp)
    }
    return OutputsOutcome(folderOutcome: folderOutcome, immichAssetId: nil)
}

private func runSync<T>(_ op: @escaping @Sendable () async throws -> T) throws -> T {
    var result: Result<T, Error>!
    let sema = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
        do {
            let r = try await op()
            result = .success(r)
        } catch {
            result = .failure(error)
        }
        sema.signal()
    }
    sema.wait()
    return try result.get()
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        if isEmpty { return [] }
        var out: [[Element]] = []
        out.reserveCapacity((count + size - 1) / size)
        var i = 0
        while i < count {
            let end = Swift.min(i + size, count)
            out.append(Array(self[i..<end]))
            i = end
        }
        return out
    }
}
