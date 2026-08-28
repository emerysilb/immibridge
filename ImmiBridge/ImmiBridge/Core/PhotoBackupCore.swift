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
    public var replacedCount: Int

    public init(uploadedCount: Int = 0, skippedCount: Int = 0, errorCount: Int = 0, replacedCount: Int = 0) {
        self.uploadedCount = uploadedCount
        self.skippedCount = skippedCount
        self.errorCount = errorCount
        self.replacedCount = replacedCount
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

// MARK: - In-Flight Cancellation Registry

/// Tracks in-flight PhotoKit and URLSession requests so the user can interrupt
/// a hung asset by clicking Stop. The orchestrator calls `cancelAll()` exactly
/// once when the run state transitions to non-running; per-call register/deregister
/// ensures we never cancel a request that has already finished.
public final class InFlightCancellationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var photoKitImageRequestIds: Set<Int32> = []
    private var photoKitResourceRequestIds: Set<Int32> = []
    // Weak refs would be nice, but URLSessionTask isn't NSObject-friendly for that.
    // We hold strong refs and rely on deregister-on-completion to release.
    private var urlSessionTasks: [ObjectIdentifier: URLSessionTask] = [:]
    private var cancelled: Bool = false

    public init() {}

    /// Returns true if cancellation has already been signaled. New requests
    /// can use this to avoid registering work that should not start.
    public func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func registerImageRequest(_ id: Int32) {
        lock.lock()
        photoKitImageRequestIds.insert(id)
        lock.unlock()
    }

    func deregisterImageRequest(_ id: Int32) {
        lock.lock()
        photoKitImageRequestIds.remove(id)
        lock.unlock()
    }

    func registerResourceRequest(_ id: Int32) {
        lock.lock()
        photoKitResourceRequestIds.insert(id)
        lock.unlock()
    }

    func deregisterResourceRequest(_ id: Int32) {
        lock.lock()
        photoKitResourceRequestIds.remove(id)
        lock.unlock()
    }

    func registerURLSessionTask(_ task: URLSessionTask) {
        lock.lock()
        let alreadyCancelled = cancelled
        if !alreadyCancelled {
            urlSessionTasks[ObjectIdentifier(task)] = task
        }
        lock.unlock()
        // If a Stop happened between the caller deciding to start and us holding
        // the lock, cancel immediately so we don't leak a hung request.
        if alreadyCancelled {
            task.cancel()
        }
    }

    func deregisterURLSessionTask(_ task: URLSessionTask) {
        lock.lock()
        urlSessionTasks.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()
    }

    /// Cancels everything currently registered. Safe to call multiple times.
    /// New work registered after this point will be cancelled immediately
    /// in `registerURLSessionTask` (PhotoKit registrations don't have an
    /// equivalent fast path; the per-asset shouldStop check covers them).
    public func cancelAll() {
        lock.lock()
        cancelled = true
        let imageIds = photoKitImageRequestIds
        let resourceIds = photoKitResourceRequestIds
        let tasks = Array(urlSessionTasks.values)
        photoKitImageRequestIds.removeAll()
        photoKitResourceRequestIds.removeAll()
        urlSessionTasks.removeAll()
        lock.unlock()

        for id in imageIds {
            PHImageManager.default().cancelImageRequest(id)
        }
        for id in resourceIds {
            PHAssetResourceManager.default().cancelDataRequest(id)
        }
        for task in tasks {
            task.cancel()
        }
    }

    /// Re-arms the registry for a fresh run after cancellation.
    func reset() {
        lock.lock()
        cancelled = false
        photoKitImageRequestIds.removeAll()
        photoKitResourceRequestIds.removeAll()
        urlSessionTasks.removeAll()
        lock.unlock()
    }
}

public struct FolderExportOptions: Sendable {
    public var destination: URL

    public init(destination: URL) {
        self.destination = destination
    }
}

// MARK: - Metadata Sync

/// Complete metadata extracted from PHAsset for sync tracking
public struct PHAssetMetadata: Codable, Sendable, Equatable {
    // Core identifiers
    public var localIdentifier: String

    // Dates
    public var creationDate: Date?
    public var modificationDate: Date?

    // Location (from CLLocation)
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?

    // User state
    public var isFavorite: Bool
    public var isHidden: Bool

    // Dimensions
    public var pixelWidth: Int
    public var pixelHeight: Int

    // Burst info
    public var burstIdentifier: String?
    public var representsBurst: Bool

    // Media info
    public var mediaType: Int  // PHAssetMediaType raw value
    public var duration: TimeInterval

    // User-visible text from Photos
    public var title: String?
    /// Keywords (tags) from Photos. Read via AppleScript, so may be nil if read failed/not attempted.
    public var keywords: [String]?

    public init(
        localIdentifier: String,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        altitude: Double? = nil,
        isFavorite: Bool = false,
        isHidden: Bool = false,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        burstIdentifier: String? = nil,
        representsBurst: Bool = false,
        mediaType: Int = 0,
        duration: TimeInterval = 0,
        title: String? = nil,
        keywords: [String]? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.burstIdentifier = burstIdentifier
        self.representsBurst = representsBurst
        self.mediaType = mediaType
        self.duration = duration
        self.title = title
        self.keywords = keywords
    }

    /// Generate a signature string for change detection
    /// Only includes fields that are syncable to Immich
    public func signature() -> String {
        var components: [String] = []
        // Location with 6 decimal precision (~0.1m accuracy)
        if let lat = latitude, let lon = longitude {
            components.append("loc:\(String(format: "%.6f", lat)),\(String(format: "%.6f", lon))")
        }
        if let alt = altitude {
            components.append("alt:\(String(format: "%.1f", alt))")
        }
        components.append("fav:\(isFavorite)")
        components.append("hid:\(isHidden)")
        if let creation = creationDate {
            components.append("cre:\(Int(creation.timeIntervalSince1970))")
        }
        if let mod = modificationDate {
            components.append("mod:\(Int(mod.timeIntervalSince1970))")
        }
        if let title, !title.isEmpty {
            components.append("ttl:\(title)")
        }
        if let keywords, !keywords.isEmpty {
            components.append("kw:\(keywords.sorted().joined(separator: "|"))")
        }
        return components.joined(separator: ";")
    }
}

/// Mapping between PHAsset localIdentifier and Immich asset ID
public struct AssetMapping: Sendable {
    public var localIdentifier: String      // PHAsset.localIdentifier
    public var immichAssetId: String        // Immich UUID
    public var deviceAssetId: String        // deviceAssetId used during upload
    public var lastSyncedSignature: String  // Metadata signature when last synced
    public var lastSyncedAt: Date

    public init(
        localIdentifier: String,
        immichAssetId: String,
        deviceAssetId: String,
        lastSyncedSignature: String,
        lastSyncedAt: Date
    ) {
        self.localIdentifier = localIdentifier
        self.immichAssetId = immichAssetId
        self.deviceAssetId = deviceAssetId
        self.lastSyncedSignature = lastSyncedSignature
        self.lastSyncedAt = lastSyncedAt
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
    /// Sync metadata (location, favorites, etc.) for already-uploaded assets
    public var syncMetadata: Bool
    /// Run metadata sync only (skip upload phase)
    public var metadataSyncOnly: Bool
    /// If true, overwrite existing metadata in Immich; if false (default), only add missing metadata
    public var metadataOverwrite: Bool

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
        updateChangedAssets: Bool = false,
        syncMetadata: Bool = true,
        metadataSyncOnly: Bool = false,
        metadataOverwrite: Bool = false
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
        self.syncMetadata = syncMetadata
        self.metadataSyncOnly = metadataSyncOnly
        self.metadataOverwrite = metadataOverwrite
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
    /// If set, failed Immich uploads will be recorded here (small JSON records; no media files).
    public var failedUploadsDir: URL?
    /// If set, exports only these Photos `localIdentifier`s (ignores album scope).
    public var onlyAssetLocalIdentifiers: Set<String>?
    public var backupMode: BackupMode
    public var mode: Mode
    public var media: Media
    public var sortOrder: SortOrder
    public var limit: Int?
    public var dryRun: Bool
    public var since: Date?
    public var until: Date?
    public var albumScope: AlbumScope
    public var libraryScope: LibraryScope
    public var includeAdjustmentData: Bool
    public var networkAccessAllowed: Bool
    public var requestTimeoutSeconds: TimeInterval
    public var collisionPolicy: CollisionPolicy
    public var retryConfiguration: RetryConfiguration
    public var iCloudTimeoutMultiplier: Double
    public var includeHiddenPhotos: Bool
    public var filenameFormat: FilenameFormat
    /// Controls how exported files are arranged within the folder destination.
    public var folderOrganization: FolderOrganization
    /// When true, a folder export skips any file whose target name already exists in the
    /// destination, without consulting the manifest and without downloading the asset from
    /// iCloud first. This is what makes an interrupted run resumable when the manifest is
    /// missing or its signatures no longer match (Photos rewrites `modificationDate` for
    /// reasons unrelated to pixel content). Matching is by name only — an asset edited in
    /// Photos since it was exported will therefore not be re-exported.
    public var skipIfNameExistsInDestination: Bool

    public init(
        folderExport: FolderExportOptions? = nil,
        immichUpload: ImmichUploadOptions? = nil,
        tempDir: URL,
        failedUploadsDir: URL? = nil,
        onlyAssetLocalIdentifiers: Set<String>? = nil,
        backupMode: BackupMode = .smartIncremental,
        mode: Mode = .originals,
        media: Media = .all,
        sortOrder: SortOrder = .oldestFirst,
        limit: Int? = nil,
        dryRun: Bool = false,
        since: Date? = nil,
        until: Date? = nil,
        albumScope: AlbumScope = .allPhotos,
        libraryScope: LibraryScope = .personalOnly,
        includeAdjustmentData: Bool = true,
        networkAccessAllowed: Bool = true,
        requestTimeoutSeconds: TimeInterval = 300,
        collisionPolicy: CollisionPolicy = .skipIdenticalElseRename,
        retryConfiguration: RetryConfiguration = .default,
        iCloudTimeoutMultiplier: Double = 2.0,
        includeHiddenPhotos: Bool = false,
        filenameFormat: FilenameFormat = .dateAndOriginal,
        folderOrganization: FolderOrganization = .byDate,
        skipIfNameExistsInDestination: Bool = false
    ) {
        self.folderExport = folderExport
        self.immichUpload = immichUpload
        self.tempDir = tempDir
        self.failedUploadsDir = failedUploadsDir
        self.onlyAssetLocalIdentifiers = onlyAssetLocalIdentifiers
        self.backupMode = backupMode
        self.mode = mode
        self.media = media
        self.sortOrder = sortOrder
        self.limit = limit
        self.dryRun = dryRun
        self.since = since
        self.until = until
        self.albumScope = albumScope
        self.libraryScope = libraryScope
        self.includeAdjustmentData = includeAdjustmentData
        self.networkAccessAllowed = networkAccessAllowed
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.collisionPolicy = collisionPolicy
        self.retryConfiguration = retryConfiguration
        self.iCloudTimeoutMultiplier = iCloudTimeoutMultiplier
        self.includeHiddenPhotos = includeHiddenPhotos
        self.filenameFormat = filenameFormat
        self.folderOrganization = folderOrganization
        self.skipIfNameExistsInDestination = skipIfNameExistsInDestination
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
    /// Reports progress of metadata sync phase
    case metadataSyncing(index: Int, total: Int, synced: Int, skipped: Int, notInImmich: Int)
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
    public var dryRunPlan: DryRunPlan?
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
        dryRunPlan: DryRunPlan? = nil,
        wasPaused: Bool = false,
        processedAssetIds: Set<String> = [],
        errorAssetIds: Set<String> = [],
        pauseIndex: Int? = nil
    ) {
        self.attemptedAssets = attemptedAssets
        self.completedAssets = completedAssets
        self.skippedAssets = skippedAssets
        self.errorCount = errorCount
        self.dryRunPlan = dryRunPlan
        self.wasPaused = wasPaused
        self.processedAssetIds = processedAssetIds
        self.errorAssetIds = errorAssetIds
        self.pauseIndex = pauseIndex
    }
}

public struct DryRunPlan: Sendable {
    public var assetsScanned: Int
    public var imagesScanned: Int
    public var videosScanned: Int
    public var livePhotosScanned: Int

    public var immichPlannedUploads: Int
    public var immichPlannedStillImages: Int
    public var immichPlannedVideos: Int
    public var immichPlannedEditedImages: Int

    public var immichWouldSkipExisting: Int
    public var immichWouldReplaceExisting: Int

    public var notes: [String]

    public init(
        assetsScanned: Int,
        imagesScanned: Int,
        videosScanned: Int,
        livePhotosScanned: Int,
        immichPlannedUploads: Int,
        immichPlannedStillImages: Int,
        immichPlannedVideos: Int,
        immichPlannedEditedImages: Int,
        immichWouldSkipExisting: Int,
        immichWouldReplaceExisting: Int,
        notes: [String]
    ) {
        self.assetsScanned = assetsScanned
        self.imagesScanned = imagesScanned
        self.videosScanned = videosScanned
        self.livePhotosScanned = livePhotosScanned
        self.immichPlannedUploads = immichPlannedUploads
        self.immichPlannedStillImages = immichPlannedStillImages
        self.immichPlannedVideos = immichPlannedVideos
        self.immichPlannedEditedImages = immichPlannedEditedImages
        self.immichWouldSkipExisting = immichWouldSkipExisting
        self.immichWouldReplaceExisting = immichWouldReplaceExisting
        self.notes = notes
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

// MARK: - Metadata Extraction

/// Extract complete metadata from a PHAsset for sync tracking.
/// Note: keywords are NOT populated here (they require AppleScript). Use `PhotosKeywordReader` for that.
public func extractMetadata(from asset: PHAsset) -> PHAssetMetadata {
    var metadata = PHAssetMetadata(
        localIdentifier: asset.localIdentifier,
        creationDate: asset.creationDate,
        modificationDate: asset.modificationDate,
        isFavorite: asset.isFavorite,
        isHidden: asset.isHidden,
        pixelWidth: asset.pixelWidth,
        pixelHeight: asset.pixelHeight,
        burstIdentifier: asset.burstIdentifier,
        representsBurst: asset.representsBurst,
        mediaType: asset.mediaType.rawValue,
        duration: asset.duration
    )

    // Extract location from CLLocation
    if let location = asset.location {
        metadata.latitude = location.coordinate.latitude
        metadata.longitude = location.coordinate.longitude
        metadata.altitude = location.altitude
    }

    // Title (rarely set by users, but cheap to read)
    if let t = asset.value(forKey: "title") as? String, !t.isEmpty {
        metadata.title = t
    }

    return metadata
}

// MARK: - Photos Keyword Reader (AppleScript)

/// Reads user-applied keywords (tags) from the Photos app via AppleScript.
/// Requires `com.apple.security.temporary-exception.apple-events` entitlement
/// allowing `com.apple.Photos`, plus `NSAppleEventsUsageDescription` in Info.plist.
final class PhotosKeywordReader: @unchecked Sendable {
    private var available: Bool = true
    private let lock = NSLock()

    /// Returns the list of keywords for an asset, or nil if reading failed.
    /// Returns an empty array when the asset has no keywords.
    func keywords(for localIdentifier: String) -> [String]? {
        lock.lock()
        let canTry = available
        lock.unlock()
        guard canTry else { return nil }

        // Photos AppleScript media item ids match PHAsset.localIdentifier in modern macOS,
        // but on some setups they're just the UUID portion. Try both.
        let uuidPart = localIdentifier.split(separator: "/").first.map(String.init) ?? localIdentifier
        for candidate in [localIdentifier, uuidPart] {
            let safeId = candidate.replacingOccurrences(of: "\"", with: "\\\"")
            let source = """
            tell application \"Photos\"
                try
                    set theItem to media item id \"\(safeId)\"
                    set kws to keywords of theItem
                    if kws is missing value then return \"__OK__\"
                    set AppleScript's text item delimiters to linefeed
                    set out to kws as text
                    set AppleScript's text item delimiters to \"\"
                    return \"__OK__\" & linefeed & out
                on error
                    return \"\"
                end try
            end tell
            """
            guard let script = NSAppleScript(source: source) else { return nil }
            var errInfo: NSDictionary?
            let result = script.executeAndReturnError(&errInfo)
            if errInfo != nil {
                // If automation was denied (errAEEventNotPermitted == -1743), give up for the rest of the run.
                if let code = errInfo?["NSAppleScriptErrorNumber"] as? Int, code == -1743 {
                    lock.lock()
                    available = false
                    lock.unlock()
                }
                return nil
            }
            let raw = result.stringValue ?? ""
            if raw.isEmpty { continue }   // not found with this id form, try next
            // Strip the __OK__ marker and split remaining lines into keywords.
            var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.first == "__OK__" { lines.removeFirst() }
            return lines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        // Neither id form found the asset. Treat as no keywords (don't keep trying).
        return []
    }

    var isAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return available
    }
}

/// Check if metadata has changed since last sync
public func metadataChangedSinceLastSync(
    asset: PHAsset,
    mapping: AssetMapping?
) -> (changed: Bool, currentMetadata: PHAssetMetadata) {
    let currentMetadata = extractMetadata(from: asset)
    let currentSignature = currentMetadata.signature()

    guard let mapping = mapping else {
        // No mapping = never synced, but we can't sync without Immich ID
        return (changed: false, currentMetadata: currentMetadata)
    }

    let changed = currentSignature != mapping.lastSyncedSignature
    return (changed: changed, currentMetadata: currentMetadata)
}

public final class PhotoBackupExporter {
    /// Registry of in-flight PhotoKit/URLSession requests for the current run.
    /// `cancelInFlight()` interrupts whatever the worker threads are blocked on
    /// so the user's Stop click takes effect immediately rather than waiting
    /// for a hung asset to time out.
    public let inFlightRegistry = InFlightCancellationRegistry()

    public init() {}

    /// Forces all currently in-flight PhotoKit/URLSession requests to abort.
    /// Call this from the UI when the user clicks Stop, in addition to flipping
    /// the run state. Per-asset catch blocks convert the resulting errors to
    /// user-stop entries so the existing logging remains accurate.
    public func cancelInFlight() {
        inFlightRegistry.cancelAll()
    }

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
        sessionState: BackupSessionState? = nil,
        timeoutProvider: (() -> TimeInterval)? = nil
    ) throws -> PhotoBackupResult {
        guard options.folderExport != nil || options.immichUpload != nil else {
            throw PhotoBackupError.noOutputsSelected
        }

        let auth = requestPhotosAuthorization()
        guard auth == .authorized || auth == .limited else {
            throw PhotoBackupError.photosPermissionNotGranted(status: auth)
        }

        try ensureDir(options.tempDir)

        // Reset cancellation registry for a fresh run. Anything left over from a
        // prior cancelled run would otherwise refuse to start new URLSession tasks.
        inFlightRegistry.reset()
        let registry = inFlightRegistry

        // Helper to check if cancelled (not paused)
        let shouldCancel: @Sendable () -> Bool = { runState() == .cancelled }

        // Helper to interrupt polling loops quickly when user clicks Stop
        let shouldStop: () -> Bool = { runState() != .running }

        let immichUploadErrorCounter = AtomicCounter()
        let progressWrapped: @Sendable (PhotoBackupProgress) -> Void = { event in
            if case .message(let msg) = event, msg.hasPrefix("ERROR Immich upload failed") {
                immichUploadErrorCounter.increment()
            }
            progress(event)
        }

        // Asset mapping store for metadata sync. Built before the upload pipeline because the
        // pipeline records `localIdentifier -> immichAssetId` into it as uploads complete.
        let assetMappingStore: AssetMappingStore?
        if let immichUpload = options.immichUpload, immichUpload.syncMetadata || immichUpload.metadataSyncOnly {
            let mappingURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("ImmiBridge", isDirectory: true)
                .appendingPathComponent("asset-mappings.sqlite", isDirectory: false)
            assetMappingStore = try? AssetMappingStore(sqliteURL: mappingURL)
        } else {
            assetMappingStore = nil
        }

        // Records the mapping the metadata-sync phase needs. This is the only mechanism that
        // populates the store on Immich v3, where the device-id search does not exist — without
        // it, metadata sync there can never resolve a single asset (see the v2-only recovery
        // note in the metadata phase).
        let onAssetPersisted: (@Sendable (String, String) -> Void)?
        if let store = assetMappingStore {
            onAssetPersisted = { deviceAssetId, immichAssetId in
                // Only the unsuffixed deviceAssetId is a PHAsset localIdentifier; ":video",
                // ":pairedVideo", ":adjustments" and ":edited" are sidecars of the same asset,
                // and localIdentifiers themselves never contain a colon.
                guard !deviceAssetId.contains(":") else { return }
                if let existing = store.get(localIdentifier: deviceAssetId),
                   existing.immichAssetId == immichAssetId {
                    return
                }
                // Empty signature = "metadata not pushed yet", which is what the sync phase
                // below tests against; a re-uploaded asset correctly re-syncs its metadata.
                try? store.upsert(AssetMapping(
                    localIdentifier: deviceAssetId,
                    immichAssetId: immichAssetId,
                    deviceAssetId: deviceAssetId,
                    lastSyncedSignature: "",
                    lastSyncedAt: .distantPast
                ))
            }
        } else {
            onAssetPersisted = nil
        }

        let immichClient: ImmichClient?
        let immichPipeline: ImmichUploadPipeline?
        if let immichUpload = options.immichUpload {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = options.requestTimeoutSeconds
            config.timeoutIntervalForResource = options.requestTimeoutSeconds
            config.httpMaximumConnectionsPerHost = immichUpload.uploadConcurrency
            let session = URLSession(configuration: config)
            let client = ImmichClient(
                serverURL: immichUpload.serverURL,
                apiKey: immichUpload.apiKey,
                session: session,
                cancellationRegistry: registry,
                logger: { progressWrapped(.message($0)) }
            )
            immichClient = client
            immichPipeline = ImmichUploadPipeline(
                immich: immichUpload,
                client: client,
                progress: progressWrapped,
                shouldCancel: shouldCancel,
                failedUploadsDir: options.failedUploadsDir,
                onAssetPersisted: onAssetPersisted
            )
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
            let created = asset.creationDate
            if !options.includeHiddenPhotos && asset.isHidden { return false }
            if let since = options.since, let created = created, created < since { return false }
            if let until = options.until, let created = created, created > until { return false }
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

        if let onlyIds = options.onlyAssetLocalIdentifiers, !onlyIds.isEmpty {
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: Array(onlyIds), options: nil)
            filtered.reserveCapacity(fetch.count)
            fetch.enumerateObjects { asset, _, stop in
                if shouldCancel() { stop.pointee = true; return }
                if !assetPassesFilters(asset) { return }
                filtered.append(asset)
            }
            filtered.sort { a, b in
                let da = a.creationDate ?? .distantPast
                let db = b.creationDate ?? .distantPast
                return ascending ? (da < db) : (da > db)
            }
            if let limit = options.limit, filtered.count > limit {
                filtered = Array(filtered.prefix(limit))
            }
        } else {
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

        if options.dryRun {
            var notes: [String] = []
            let totalAssets = filtered.count
            let imagesScanned = filtered.filter { $0.mediaType == .image }.count
            let videosScanned = filtered.filter { $0.mediaType == .video }.count
            let livePhotosScanned = filtered.filter { $0.mediaSubtypes.contains(.photoLive) }.count

            var plannedStill = 0
            var plannedVideos = 0
            var plannedEdited = 0
            var wouldSkipExisting = 0
            var wouldReplaceExisting = 0
            // False once we know the dry run cannot tell existing assets from new ones, so the
            // summary below reports "unknown" instead of asserting a number it did not measure.
            var duplicatePredictionAvailable = true

            if let immichUpload = options.immichUpload, let immichPipeline {
                // Reuse the existing "exists sync" batching logic to populate the pipeline's existing-id cache.
                // This avoids downloading/exporting any asset bytes.
                do {
                    let stats = try runSync { try await ImmichClient(serverURL: immichUpload.serverURL, apiKey: immichUpload.apiKey).getAssetStatistics() }
                    progressWrapped(.message("Immich: server has \(stats.total) assets (\(stats.images) images, \(stats.videos) videos)"))
                } catch {
                    progressWrapped(.message("ERROR Immich: could not fetch statistics: \(error)"))
                }

                // The whole pre-pass is /assets/exist, which only v2 serves. Running it on v3
                // would answer "nothing exists" without issuing a single request, and the dry run
                // would then confidently predict a full re-upload of an already-synced library.
                let existing: Set<String>
                if immichPipeline.serverIsLegacyV2() {
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

                    for asset in filtered {
                        if shouldCancel() { break }

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
                            if (asset.mediaType == .image || asset.mediaType == .video), asset.hasAdjustments {
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
                        notes.append("Immich exist-check failed; counts may be inaccurate.")
                    }

                    existing = immichPipeline.snapshotExistingDeviceAssetIds()
                    notes.append("Dry run uses Immich /assets/exist (device asset ids). Items uploaded from other devices/tools may still be detected as checksum-duplicates during a real run and be skipped.")
                    progressWrapped(.message("Dry run: Immich reports \(existing.count) existing device-asset id(s) for this deviceId"))
                } else {
                    // ponytail: no prediction on v3 rather than a checksum simulation. Predicting
                    // would mean hashing every original, i.e. exporting (and iCloud-downloading)
                    // the whole library — the one thing a dry run promises not to do.
                    // Ceiling: on v3 the dry run reports what it would *consider*, not what it
                    // would transfer.
                    existing = []
                    duplicatePredictionAvailable = false
                    notes.append("Immich v3 removed /assets/exist, so this dry run cannot tell which items the server already has. The real run detects duplicates by checksum and skips them, so it will usually upload far fewer than planned below.")
                    progressWrapped(.message("Dry run: duplicate prediction unavailable on Immich v3 (the real run dedups by checksum)"))
                }

                // Count planned outputs and whether each would be skipped/replaced, per the same deviceAssetId scheme
                // the uploader uses (without exporting).
                for asset in filtered {
                    if shouldCancel() { break }

                    var outputs: [(label: String, id: String)] = []

                    if options.mode == .originals || options.mode == .both {
                        switch asset.mediaType {
                        case .image:
                            plannedStill += 1
                            outputs.append((label: "still", id: asset.localIdentifier))
                            if asset.mediaSubtypes.contains(.photoLive) {
                                plannedVideos += 1
                                outputs.append((label: "pairedVideo", id: asset.localIdentifier + ":pairedVideo"))
                                outputs.append((label: "video", id: asset.localIdentifier + ":video"))
                            }
                        case .video:
                            plannedVideos += 1
                            outputs.append((label: "video", id: asset.localIdentifier + ":video"))
                        default:
                            break
                        }
                    }

                    if options.mode == .edited || options.mode == .both {
                        if (asset.mediaType == .image || asset.mediaType == .video), asset.hasAdjustments {
                            plannedEdited += 1
                            outputs.append((label: "edited", id: asset.localIdentifier + ":edited"))
                        }
                    }

                    // Evaluate outputs and append per-output notes
                    let resources = PHAssetResource.assetResources(for: asset)
                    let filename = resources.first?.originalFilename ?? asset.localIdentifier
                    for out in outputs {
                        let exists = existing.contains(out.id)
                        if exists {
                            if immichUpload.updateChangedAssets {
                                wouldReplaceExisting += 1
                                notes.append("\(filename) (\(out.label)) — would replace")
                            } else {
                                wouldSkipExisting += 1
                                notes.append("\(filename) (\(out.label)) — would skip (already exists)")
                            }
                        } else if duplicatePredictionAvailable {
                            notes.append("\(filename) (\(out.label)) — would upload")
                        } else {
                            notes.append("\(filename) (\(out.label)) — would upload unless the server already has it")
                        }
                    }
                }

                if immichUpload.syncAlbums {
                    notes.append("Album sync not simulated in dry run.")
                }
                // The real run forces the checksum precheck on whenever we are not on v2, so the
                // caveat has to follow that same condition rather than the configured flag alone.
                if immichUpload.checksumPrecheck || !duplicatePredictionAvailable {
                    notes.append("Checksum-based duplicate detection is not simulated in dry run.")
                }
            } else {
                notes.append("Immich upload not enabled; dry run only reports scan counts.")
            }

            let plannedUploads = plannedStill + plannedVideos + plannedEdited
            let plan = DryRunPlan(
                assetsScanned: totalAssets,
                imagesScanned: imagesScanned,
                videosScanned: videosScanned,
                livePhotosScanned: livePhotosScanned,
                immichPlannedUploads: plannedUploads,
                immichPlannedStillImages: plannedStill,
                immichPlannedVideos: plannedVideos,
                immichPlannedEditedImages: plannedEdited,
                immichWouldSkipExisting: wouldSkipExisting,
                immichWouldReplaceExisting: wouldReplaceExisting,
                notes: notes
            )

            let wouldUploadNew = max(0, plannedUploads - wouldSkipExisting - wouldReplaceExisting)
            progressWrapped(.message("Dry run plan: scanned \(totalAssets) assets (\(imagesScanned) images, \(videosScanned) videos, \(livePhotosScanned) Live Photos)"))
            if duplicatePredictionAvailable {
                progressWrapped(.message("Dry run plan: Immich planned \(plannedUploads) upload(s) — would upload \(wouldUploadNew), skip existing \(wouldSkipExisting), replace existing \(wouldReplaceExisting)"))
            } else {
                progressWrapped(.message("Dry run plan: Immich would consider \(plannedUploads) upload(s) — how many are already on the server is unknown here (Immich v3 has no device-id exist check); the real run skips checksum-duplicates"))
            }
            if !notes.isEmpty {
                for n in notes {
                    progressWrapped(.message("Dry run note: \(n)"))
                }
            }

            return PhotoBackupResult(
                attemptedAssets: totalAssets,
                completedAssets: 0,
                skippedAssets: 0,
                errorCount: 0,
                dryRunPlan: plan,
                wasPaused: false,
                processedAssetIds: [],
                errorAssetIds: [],
                pauseIndex: nil
            )
        }

        // If Immich is enabled, perform a full "exists sync" up-front so we can show progress
        // and then start uploading with a complete existing-id set.
        if let immichUpload = options.immichUpload, let immichPipeline {
            // Decide (and log) the server major before any work is routed, so the log explains
            // why the exist-sync below either ran or was skipped. The answer is memoised.
            _ = immichPipeline.serverIsLegacyV2()

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
                    if (asset.mediaType == .image || asset.mediaType == .video), asset.hasAdjustments {
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

        func photoManifestKey(assetId: String, variant: String, folderTag: String? = nil) -> String {
            if let folderTag, !folderTag.isEmpty {
                return "photo:\(assetId):\(variant):folder=\(folderTag)"
            }
            return "photo:\(assetId):\(variant)"
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

        // Destination paths this run has already taken responsibility for. Two distinct assets
        // can compute the same output name (notably with `.originalOnly`), so a file this run
        // just wrote is not evidence of a previous backup — without this, the second asset
        // would be silently dropped instead of being renamed by the collision policy.
        var pathsClaimedThisRun: Set<String> = []

        func claimPath(_ url: URL?) {
            guard options.skipIfNameExistsInDestination, let url else { return }
            pathsClaimedThisRun.insert(url.standardizedFileURL.path)
        }

        /// A zero-byte file is the fingerprint of a write that never finished. The temp dir lives
        /// on the internal disk, so placing a file onto an external volume is a cross-device
        /// copy — killing the app or unplugging the drive mid-copy can leave a stub behind.
        /// Treat such a file as absent so it is exported again instead of trusted forever.
        func isNonEmptyFile(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { return false }
            return size > 0
        }

        func nameAlreadyInDestination(_ desiredURL: URL?) -> Bool {
            guard options.skipIfNameExistsInDestination, let desiredURL else { return false }
            if pathsClaimedThisRun.contains(desiredURL.standardizedFileURL.path) { return false }
            return isNonEmptyFile(desiredURL)
        }

        /// Returns a file already in `dir` whose name is `stem` plus any extension. Used for
        /// rendered edits, whose extension is only known after the render completes.
        func existingFileMatchingStem(in dir: URL?, stem: String) -> URL? {
            guard options.skipIfNameExistsInDestination, let dir else { return nil }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
            let prefix = (stem + ".").lowercased()
            for name in names where name.lowercased().hasPrefix(prefix) {
                let url = dir.appendingPathComponent(name, isDirectory: false)
                if pathsClaimedThisRun.contains(url.standardizedFileURL.path) { continue }
                if !isNonEmptyFile(url) { continue }
                return url
            }
            return nil
        }

        var nameSkips = 0

        /// Single decision point for "this variant is already in the destination". Records the
        /// claim on `desiredURL` either way, so a later asset computing the same name still gets
        /// exported (and renamed) rather than skipped.
        func shouldSkipExistingFile(key: String, signature: String, desiredURL: URL?) -> Bool {
            defer { claimPath(desiredURL) }
            if options.backupMode != .full,
               shouldSkipByManifest(key: key, signature: signature, desiredURL: desiredURL) {
                return true
            }
            if nameAlreadyInDestination(desiredURL) {
                nameSkips += 1
                return true
            }
            return false
        }

        // Skip export/upload phase if metadata sync only mode
        let skipExportPhase = options.immichUpload?.metadataSyncOnly == true

        if skipExportPhase {
            progress(.message("Metadata sync only mode - skipping upload phase"))
            progress(.message("Will sync metadata for \(filtered.count) photos already in Immich"))
        }

        if !skipExportPhase {
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

            // Determine the per-asset destination folder(s) within the folder export root.
            // For `.byDate` (default): a single `<root>/YYYY/MM/DD/` folder.
            // For `.byAlbum`: one folder per user album the asset belongs to,
            //                 or `<root>/_Unsorted/` if it belongs to no user album.
            // The first entry is treated as the "primary" destination for export
            // (and any Immich upload). Additional entries receive a file copy.
            struct PerAssetFolder { let url: URL; let tag: String }
            var assetFolders: [PerAssetFolder] = []
            if let folderExport = options.folderExport {
                switch options.folderOrganization {
                case .byDate:
                    let folder = created.map { ymdFolder(for: $0, calendar: calendar) } ?? "Unknown Date"
                    let url = folderExport.destination.appendingPathComponent(folder, isDirectory: true)
                    assetFolders.append(PerAssetFolder(url: url, tag: folder))
                case .byAlbum:
                    let names = userAlbumFolderNames(for: asset)
                    if names.isEmpty {
                        let url = folderExport.destination.appendingPathComponent("_Unsorted", isDirectory: true)
                        assetFolders.append(PerAssetFolder(url: url, tag: "_Unsorted"))
                    } else {
                        for name in names {
                            let url = folderExport.destination.appendingPathComponent(name, isDirectory: true)
                            assetFolders.append(PerAssetFolder(url: url, tag: name))
                        }
                    }
                }
            }
            for f in assetFolders { try ensureDir(f.url) }

            // Primary out dir is used for export (plus optional Immich upload). Additional dirs get a copy.
            let outDir: URL? = assetFolders.first?.url
            let primaryFolderTag: String? = assetFolders.first?.tag
            let additionalFolders: [PerAssetFolder] = assetFolders.count > 1 ? Array(assetFolders.dropFirst()) : []

            // Helper: copy an existing exported file to each additional folder, updating the manifest.
            // Used only when `folderOrganization == .byAlbum` and the asset is in multiple albums.
            func mirrorExportToAdditionalFolders(
                sourceURL: URL,
                filename: String,
                variant: String,
                signature: String
            ) {
                guard !additionalFolders.isEmpty else { return }
                guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }
                for f in additionalFolders {
                    let target = f.url.appendingPathComponent(filename, isDirectory: false)
                    let key = photoManifestKey(assetId: asset.localIdentifier, variant: variant, folderTag: f.tag)
                    if nameAlreadyInDestination(target) {
                        nameSkips += 1
                        claimPath(target)
                        upsertManifestIfPossible(key: key, signature: signature, desiredURL: target)
                        continue
                    }
                    do {
                        let outcome = try placeTempFile(
                            tmpURL: sourceURL,
                            desiredURL: target,
                            collisionPolicy: options.collisionPolicy,
                            copyInsteadOfMove: true
                        )
                        let placedURL: URL = {
                            switch outcome {
                            case .exported(let u): return u
                            case .skippedIdentical(let u): return u
                            }
                        }()
                        claimPath(placedURL)
                        upsertManifestIfPossible(key: key, signature: signature, desiredURL: placedURL)
                    } catch {
                        progressWrapped(.message("ERROR copying to album folder \(f.tag): \(error)"))
                    }
                }
            }

            let resources = PHAssetResource.assetResources(for: asset)
            let originalFilename = primaryOriginalFilename(from: resources)
            let base = baseFilename(for: created, localIdentifier: asset.localIdentifier, originalFilename: originalFilename, format: options.filenameFormat)

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
                    if (asset.mediaType == .image || asset.mediaType == .video), asset.hasAdjustments {
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
                    let filename = "\(base)_live.\(ext)"
                    let desiredURL = outDir?.appendingPathComponent(filename, isDirectory: false)
                    let key = photoManifestKey(assetId: asset.localIdentifier, variant: "pairedVideo", folderTag: primaryFolderTag)
                    let sig = photoSignature(asset: asset, variant: "pairedVideo", resourceName: paired.originalFilename)
                    if shouldSkipExistingFile(key: key, signature: sig, desiredURL: desiredURL) {
                        upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                        if let primarySource = desiredURL {
                            mirrorExportToAdditionalFolders(sourceURL: primarySource, filename: filename, variant: "pairedVideo", signature: sig)
                        }
                    } else {
                        do {
                            let outcome = try exportResourceToOutputs(
                                resource: paired,
                                asset: asset,
                                deviceAssetIdSuffix: ":pairedVideo",
                                filenameOverride: filename,
                                desiredFolderURL: desiredURL,
                                options: options,
                                immichPipeline: immichPipeline,
                                progress: progressWrapped,
                                livePhotoVideoId: nil,
                                awaitImmichAssetId: true,
                                onImmichAssetId: onImmichAssetId,
                                shouldStop: shouldStop,
                                timeoutProvider: timeoutProvider,
                                cancellationRegistry: registry
                            )
                            if let folderOutcome = outcome.folderOutcome, case .exported = folderOutcome { assetAllSkipped = false }
                            livePhotoVideoId = outcome.immichAssetId
                            upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                            if let folderOutcome = outcome.folderOutcome {
                                let placedURL: URL = {
                                    switch folderOutcome {
                                    case .exported(let u): return u
                                    case .skippedIdentical(let u): return u
                                    }
                                }()
                                mirrorExportToAdditionalFolders(sourceURL: placedURL, filename: filename, variant: "pairedVideo", signature: sig)
                            }
                        } catch let error as NSError where error.code == 499 {
                            progressWrapped(.message("Stopped by user during live video export"))
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
                    let filename = "\(base).\(ext)"
                    let desiredURL = outDir?.appendingPathComponent(filename, isDirectory: false)
                    let key = photoManifestKey(assetId: asset.localIdentifier, variant: "original", folderTag: primaryFolderTag)
                    let sig = photoSignature(asset: asset, variant: "original", resourceName: still.originalFilename)
                    if shouldSkipExistingFile(key: key, signature: sig, desiredURL: desiredURL) {
                        upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                        if let primarySource = desiredURL {
                            mirrorExportToAdditionalFolders(sourceURL: primarySource, filename: filename, variant: "original", signature: sig)
                        }
                    } else {
                        do {
                            let outcome = try exportResourceToOutputs(
                                resource: still,
                                asset: asset,
                                deviceAssetIdSuffix: "",
                                filenameOverride: filename,
                                desiredFolderURL: desiredURL,
                                options: options,
                                immichPipeline: immichPipeline,
                                progress: progressWrapped,
                                livePhotoVideoId: livePhotoVideoId,
                                awaitImmichAssetId: false,
                                onImmichAssetId: onImmichAssetId,
                                shouldStop: shouldStop,
                                timeoutProvider: timeoutProvider,
                                cancellationRegistry: registry
                            )
                            if let folderOutcome = outcome.folderOutcome, case .exported = folderOutcome { assetAllSkipped = false }
                            upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                            if let folderOutcome = outcome.folderOutcome {
                                let placedURL: URL = {
                                    switch folderOutcome {
                                    case .exported(let u): return u
                                    case .skippedIdentical(let u): return u
                                    }
                                }()
                                mirrorExportToAdditionalFolders(sourceURL: placedURL, filename: filename, variant: "original", signature: sig)
                            }
                        } catch let error as NSError where error.code == 499 {
                            progressWrapped(.message("Stopped by user during still export"))
                        } catch {
                            assetHadAnyError = true
                            errors += 1
                            progressWrapped(.message("ERROR processing still: \(error)"))
                        }
                    }
                }

                // Only export adjustment data to folder (not Immich - it doesn't support .plist/.aae files)
                if let adjustments, outDir != nil {
                    assetHadAnyWork = true
                    let ext = extFromFilename(adjustments.originalFilename) ?? extFromUTI(adjustments.uniformTypeIdentifier) ?? "aae"
                    let filename = "\(base)_adjustments.\(ext)"
                    let desiredURL = outDir?.appendingPathComponent(filename, isDirectory: false)
                    let key = photoManifestKey(assetId: asset.localIdentifier, variant: "adjustments", folderTag: primaryFolderTag)
                    let sig = photoSignature(asset: asset, variant: "adjustments", resourceName: adjustments.originalFilename)
                    if shouldSkipExistingFile(key: key, signature: sig, desiredURL: desiredURL) {
                        upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                        if let primarySource = desiredURL {
                            mirrorExportToAdditionalFolders(sourceURL: primarySource, filename: filename, variant: "adjustments", signature: sig)
                        }
                    } else {
                        do {
                            let outcome = try exportResourceToOutputs(
                                resource: adjustments,
                                asset: asset,
                                deviceAssetIdSuffix: ":adjustments",
                                filenameOverride: filename,
                                desiredFolderURL: desiredURL,
                                options: options,
                                immichPipeline: nil,  // Never upload adjustment data to Immich
                                progress: progressWrapped,
                                livePhotoVideoId: nil,
                                awaitImmichAssetId: false,
                                onImmichAssetId: onImmichAssetId,
                                shouldStop: shouldStop,
                                timeoutProvider: timeoutProvider,
                                cancellationRegistry: registry
                            )
                            if let folderOutcome = outcome.folderOutcome, case .exported = folderOutcome { assetAllSkipped = false }
                            upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                            if let folderOutcome = outcome.folderOutcome {
                                let placedURL: URL = {
                                    switch folderOutcome {
                                    case .exported(let u): return u
                                    case .skippedIdentical(let u): return u
                                    }
                                }()
                                mirrorExportToAdditionalFolders(sourceURL: placedURL, filename: filename, variant: "adjustments", signature: sig)
                            }
                        } catch let error as NSError where error.code == 499 {
                            progressWrapped(.message("Stopped by user during adjustments export"))
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
                    let filename = "\(base)\(suffix).\(ext)"
                    let desiredURL = outDir?.appendingPathComponent(filename, isDirectory: false)
                    let key = photoManifestKey(assetId: asset.localIdentifier, variant: "video", folderTag: primaryFolderTag)
                    let sig = photoSignature(asset: asset, variant: "video", resourceName: video.originalFilename)
                    if shouldSkipExistingFile(key: key, signature: sig, desiredURL: desiredURL) {
                        upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                        if let primarySource = desiredURL {
                            mirrorExportToAdditionalFolders(sourceURL: primarySource, filename: filename, variant: "video", signature: sig)
                        }
                    } else {
                        do {
                            let outcome = try exportResourceToOutputs(
                                resource: video,
                                asset: asset,
                                deviceAssetIdSuffix: ":video",
                                filenameOverride: filename,
                                desiredFolderURL: desiredURL,
                                options: options,
                                immichPipeline: immichPipeline,
                                progress: progressWrapped,
                                livePhotoVideoId: nil,
                                awaitImmichAssetId: false,
                                onImmichAssetId: onImmichAssetId,
                                shouldStop: shouldStop,
                                timeoutProvider: timeoutProvider,
                                cancellationRegistry: registry
                            )
                            if let folderOutcome = outcome.folderOutcome, case .exported = folderOutcome { assetAllSkipped = false }
                            upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                            if let folderOutcome = outcome.folderOutcome {
                                let placedURL: URL = {
                                    switch folderOutcome {
                                    case .exported(let u): return u
                                    case .skippedIdentical(let u): return u
                                    }
                                }()
                                mirrorExportToAdditionalFolders(sourceURL: placedURL, filename: filename, variant: "video", signature: sig)
                            }
                        } catch let error as NSError where error.code == 499 {
                            progressWrapped(.message("Stopped by user during video export"))
                        } catch {
                            assetHadAnyError = true
                            errors += 1
                            progressWrapped(.message("ERROR processing video: \(error)"))
                        }
                    }
                }
            }

            if options.mode == .edited || options.mode == .both {
                if asset.mediaType == .image, asset.hasAdjustments {
                    assetHadAnyWork = true
                    let key = photoManifestKey(assetId: asset.localIdentifier, variant: "edited", folderTag: primaryFolderTag)
                    let sig = photoSignature(asset: asset, variant: "edited", resourceName: "rendered")

                    // Helper: mirror the edited image (filename comes back from outcome.url) to additional folders.
                    func mirrorEditedTo(placedURL: URL) {
                        guard !additionalFolders.isEmpty else { return }
                        let filename = placedURL.lastPathComponent
                        mirrorExportToAdditionalFolders(sourceURL: placedURL, filename: filename, variant: "edited", signature: sig)
                    }

                    if let existing = existingFileMatchingStem(in: outDir, stem: "\(base)_edited") {
                        nameSkips += 1
                        claimPath(existing)
                        upsertManifestIfPossible(key: key, signature: sig, desiredURL: existing)
                        mirrorEditedTo(placedURL: existing)
                    } else if options.backupMode != .full,
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
                            claimPath(url)
                            mirrorEditedTo(placedURL: url)
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
                                    onImmichAssetId: onImmichAssetId,
                                    shouldStop: shouldStop,
                                    timeoutProvider: timeoutProvider,
                                    cancellationRegistry: registry
                                )
                                if let folderOutcome = outcome.folderOutcome, case .exported = folderOutcome { assetAllSkipped = false }
                                if let folderOutcome = outcome.folderOutcome {
                                    switch folderOutcome {
                                    case .exported(let url):
                                        claimPath(url)
                                        upsertManifestIfPossible(key: key, signature: sig, desiredURL: url)
                                        mirrorEditedTo(placedURL: url)
                                    case .skippedIdentical(let existing):
                                        claimPath(existing)
                                        upsertManifestIfPossible(key: key, signature: sig, desiredURL: existing)
                                        mirrorEditedTo(placedURL: existing)
                                    }
                                }
                            } catch let error as NSError where error.code == 499 {
                                progressWrapped(.message("Stopped by user during edited image export"))
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
                                onImmichAssetId: onImmichAssetId,
                                shouldStop: shouldStop,
                                timeoutProvider: timeoutProvider,
                                cancellationRegistry: registry
                            )
                            if let folderOutcome = outcome.folderOutcome, case .exported = folderOutcome { assetAllSkipped = false }
                            if let folderOutcome = outcome.folderOutcome {
                                switch folderOutcome {
                                case .exported(let url):
                                    claimPath(url)
                                    upsertManifestIfPossible(key: key, signature: sig, desiredURL: url)
                                    mirrorEditedTo(placedURL: url)
                                case .skippedIdentical(let existing):
                                    claimPath(existing)
                                    upsertManifestIfPossible(key: key, signature: sig, desiredURL: existing)
                                    mirrorEditedTo(placedURL: existing)
                                }
                            }
                        } catch let error as NSError where error.code == 499 {
                            progressWrapped(.message("Stopped by user during edited image export"))
                        } catch {
                            assetHadAnyError = true
                            errors += 1
                            progressWrapped(.message("ERROR exporting edited image: \(error)"))
                        }
                    }
                } else if asset.mediaType == .video, asset.hasAdjustments {
                    let editedVideo = resources.first { $0.type == .fullSizeVideo } ?? resources.first { $0.type == .video }
                    if let editedVideo {
                        assetHadAnyWork = true
                        let ext = extFromFilename(editedVideo.originalFilename) ?? "mov"
                        let desiredURL = outDir?.appendingPathComponent("\(base)_edited.\(ext)", isDirectory: false)
                        let key = photoManifestKey(assetId: asset.localIdentifier, variant: "edited")
                        let sig = photoSignature(asset: asset, variant: "edited", resourceName: editedVideo.originalFilename)
                        if shouldSkipExistingFile(key: key, signature: sig, desiredURL: desiredURL) {
                            upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                        } else {
                            do {
                                let outcome = try exportResourceToOutputs(
                                    resource: editedVideo,
                                    asset: asset,
                                    deviceAssetIdSuffix: ":edited",
                                    filenameOverride: "\(base)_edited.\(ext)",
                                    desiredFolderURL: desiredURL,
                                    options: options,
                                    immichPipeline: immichPipeline,
                                    progress: progressWrapped,
                                    livePhotoVideoId: nil,
                                    awaitImmichAssetId: false,
                                    onImmichAssetId: onImmichAssetId,
                                    shouldStop: shouldStop,
                                    timeoutProvider: timeoutProvider
                                )
                                if let folderOutcome = outcome.folderOutcome, case .exported = folderOutcome { assetAllSkipped = false }
                                upsertManifestIfPossible(key: key, signature: sig, desiredURL: desiredURL)
                            } catch let error as NSError where error.code == 499 {
                                progressWrapped(.message("Stopped by user during edited video export"))
                            } catch {
                                assetHadAnyError = true
                                errors += 1
                                progressWrapped(.message("ERROR exporting edited video: \(error)"))
                            }
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

        if nameSkips > 0 {
            progressWrapped(.message("Skipped \(nameSkips) file(s) already in the destination (matched by filename)"))
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
        } // end if !skipExportPhase

        // MARK: - Metadata Sync Phase
        // For metadata sync, stop on both paused AND cancelled (metadata sync doesn't need resume support)
        let shouldStopMetadataSync: @Sendable () -> Bool = {
            let state = runState()
            return state == .cancelled || state == .paused
        }

        if !shouldStopMetadataSync(),
           let immichUpload = options.immichUpload,
           immichUpload.syncMetadata || immichUpload.metadataSyncOnly,
           let immichClient,
           let assetMappingStore
        {
            progressWrapped(.message("Metadata: starting sync phase..."))

            var metadataSynced = 0
            var metadataSkipped = 0
            var metadataErrors = 0
            var metadataRecovered = 0
            var metadataNotInImmich = 0
            var metadataMappingUnknown = 0
            let metadataTotal = filtered.count

            // Hoisted out of the per-asset loop: `runSync` spins up a detached Task plus a
            // semaphore per call, and the answer is fixed for the run.
            let metadataServerIsLegacyV2 = (try? runSync { await immichClient.isLegacyV2() }) ?? false
            var announcedMappingUnavailable = false

            // Tag sync setup: read keywords from Photos via AppleScript and push to Immich.
            let keywordReader = PhotosKeywordReader()
            // name (lowercased for case-insensitive match) -> Immich tag id
            var tagIdByName: [String: String] = [:]
            // Lazily populated on first asset that has keywords.
            var loadedExistingTags = false
            var keywordsDeniedAnnounced = false

            for (metadataIndex, asset) in filtered.enumerated() {
                if shouldStopMetadataSync() { break }

                // Report progress
                progress(.metadataSyncing(
                    index: metadataIndex + 1,
                    total: metadataTotal,
                    synced: metadataSynced,
                    skipped: metadataSkipped,
                    notInImmich: metadataNotInImmich
                ))

                var currentMetadata = extractMetadata(from: asset)
                // Read keywords from Photos (AppleScript). Nil = read failed/denied; treated as "unknown".
                if keywordReader.isAvailable {
                    currentMetadata.keywords = keywordReader.keywords(for: asset.localIdentifier)
                    if !keywordReader.isAvailable && !keywordsDeniedAnnounced {
                        keywordsDeniedAnnounced = true
                        progressWrapped(.message("Metadata: tag sync skipped (Photos automation not authorized; grant in System Settings > Privacy > Automation)"))
                    }
                }
                let currentSignature = currentMetadata.signature()

                // Check if we have a mapping for this asset
                var mapping = assetMappingStore.get(localIdentifier: asset.localIdentifier)

                // If no mapping exists, try to recover from Immich by device asset ID.
                // ponytail: v2-only recovery. Immich v3 has no device-id search (and probing it
                // there would return an arbitrary asset — see ImmichClient.getAssetIdByDeviceId).
                // On v3 the mapping instead comes from the upload pipeline, which records every
                // asset id the server confirms (`onAssetPersisted`). Ceiling: an asset that was
                // put on the server by something other than this app has no mapping on v3 and
                // cannot be looked up — reported separately below rather than as "not in Immich".
                if mapping == nil, metadataServerIsLegacyV2 {
                    let deviceAssetId = asset.localIdentifier
                    do {
                        if let immichAssetId = try runSync({ try await immichClient.getAssetIdByDeviceId(deviceId: immichUpload.deviceId, deviceAssetId: deviceAssetId) }) {
                            // Create mapping for this asset
                            let newMapping = AssetMapping(
                                localIdentifier: asset.localIdentifier,
                                immichAssetId: immichAssetId,
                                deviceAssetId: deviceAssetId,
                                lastSyncedSignature: "",  // Empty = needs sync
                                lastSyncedAt: .distantPast
                            )
                            try? assetMappingStore.upsert(newMapping)
                            mapping = newMapping
                            metadataRecovered += 1
                        }
                    } catch {
                        // Asset not in Immich yet, skip metadata sync
                    }
                }

                guard let mapping = mapping else {
                    guard metadataServerIsLegacyV2 else {
                        // Not the same thing as "not in Immich": on v3 we simply have no way to
                        // ask. Saying "not in Immich" here would tell the user their library is
                        // missing from the server when it is very likely all there.
                        metadataMappingUnknown += 1
                        if !announcedMappingUnavailable {
                            announcedMappingUnavailable = true
                            progressWrapped(.message("Metadata: some assets have no local Immich mapping. Immich v3 removed the device-id lookup, so their metadata can only be synced once this app has uploaded them itself."))
                        }
                        continue
                    }
                    // No mapping = asset not in Immich, skip
                    metadataNotInImmich += 1
                    continue
                }

                // Check cancellation after API calls
                if shouldStopMetadataSync() { break }

                // Check if metadata has changed (based on local signature)
                if currentSignature == mapping.lastSyncedSignature {
                    metadataSkipped += 1
                    continue
                }

                // Fetch existing Immich asset metadata (unless overwrite mode)
                let existingAsset: ImmichClient.AssetResponseDto?
                if immichUpload.metadataOverwrite {
                    existingAsset = nil  // Skip fetch, will overwrite everything
                } else {
                    do {
                        existingAsset = try runSync { try await immichClient.getAssetIfExists(assetId: mapping.immichAssetId) }
                        if shouldStopMetadataSync() { break }
                    } catch {
                        // If we can't fetch, skip this asset
                        metadataErrors += 1
                        progressWrapped(.message("ERROR Metadata: could not fetch \(asset.localIdentifier): \(error)"))
                        continue
                    }
                }

                // Build update DTO - only include fields missing in Immich (or all if overwrite mode)
                var update = ImmichClient.UpdateAssetDto()
                let overwrite = immichUpload.metadataOverwrite

                // Location - only add if Immich doesn't have it (or overwrite enabled)
                if let lat = currentMetadata.latitude, let lon = currentMetadata.longitude {
                    let immichHasLocation = existingAsset?.effectiveLatitude != nil && existingAsset?.effectiveLongitude != nil
                    if overwrite || !immichHasLocation {
                        update.latitude = lat
                        update.longitude = lon
                    }
                }

                // Favorites - only update if different and (overwrite or Immich is false/nil)
                let immichIsFavorite = existingAsset?.isFavorite ?? false
                if currentMetadata.isFavorite != immichIsFavorite {
                    if overwrite || !immichIsFavorite {
                        // In additive mode: only set to true, never unset
                        // In overwrite mode: sync the actual value
                        update.isFavorite = overwrite ? currentMetadata.isFavorite : (currentMetadata.isFavorite ? true : nil)
                    }
                }

                // Hidden/Archived - only update if different and (overwrite or Immich is false/nil)
                let immichIsArchived = existingAsset?.effectiveIsArchived ?? false
                if currentMetadata.isHidden != immichIsArchived {
                    if overwrite {
                        update.setArchived(currentMetadata.isHidden)
                    } else if !immichIsArchived {
                        // Additive mode: only ever archive, never un-archive. (The outer test
                        // already guarantees isHidden == true in this branch.)
                        update.setArchived(true)
                    }
                }

                // Creation date - only add if Immich doesn't have it (or overwrite enabled)
                if let creation = currentMetadata.creationDate {
                    let immichHasDate = existingAsset?.effectiveDateTimeOriginal != nil
                    if overwrite || !immichHasDate {
                        update.dateTimeOriginal = iso8601(creation)
                    }
                }

                // Title (Photos "title") -> Immich description.
                // PHAsset has no description field; Immich already extracts EXIF/IPTC ImageDescription
                // from uploaded files, so we only fill description from Photos title (when set) to
                // preserve user-entered text that EXIF wouldn't capture.
                if let title = currentMetadata.title, !title.isEmpty {
                    if overwrite {
                        update.description = title
                    }
                    // Additive mode: don't clobber an existing description that may have come from EXIF.
                    // (We can't easily diff against current Immich description without an extra fetch field;
                    // skipping in additive mode is the conservative choice.)
                }

                // Tag sync (independent of update DTO; runs even if no other field changed)
                let assetKeywords = (currentMetadata.keywords ?? []).filter { !$0.isEmpty }
                let needsTagSync = !assetKeywords.isEmpty

                // Skip API call if no field changes AND no tags to sync
                let hasUpdateFields = update.hasChanges
                if !hasUpdateFields && !needsTagSync {
                    metadataSkipped += 1
                    continue
                }

                if shouldStopMetadataSync() { break }

                var assetUpdateOK = true
                if hasUpdateFields {
                    let updateSnapshot = update
                    do {
                        _ = try runSync { try await immichClient.updateAssetIfExists(assetId: mapping.immichAssetId, update: updateSnapshot) }
                    } catch {
                        assetUpdateOK = false
                        metadataErrors += 1
                        progressWrapped(.message("ERROR Metadata: sync failed for \(asset.localIdentifier): \(error)"))
                    }
                }

                // Tag sync — best-effort, separate from asset metadata update.
                var tagSyncOK = true
                if needsTagSync {
                    if !loadedExistingTags {
                        loadedExistingTags = true
                        do {
                            let existing = try runSync { try await immichClient.listTags() }
                            for t in existing {
                                let n = (t.name ?? t.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                if !n.isEmpty { tagIdByName[n.lowercased()] = t.id }
                            }
                        } catch {
                            progressWrapped(.message("WARN Metadata: could not list Immich tags: \(error)"))
                        }
                    }

                    // Find names we don't yet have ids for and upsert them.
                    let missing = assetKeywords.filter { tagIdByName[$0.lowercased()] == nil }
                    if !missing.isEmpty {
                        do {
                            let created = try runSync { try await immichClient.upsertTags(names: missing) }
                            for t in created {
                                let n = (t.name ?? t.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                if !n.isEmpty { tagIdByName[n.lowercased()] = t.id }
                            }
                        } catch {
                            tagSyncOK = false
                            progressWrapped(.message("WARN Metadata: tag upsert failed for \(asset.localIdentifier): \(error)"))
                        }
                    }

                    // Attach each tag to this asset.
                    for name in assetKeywords {
                        guard let tagId = tagIdByName[name.lowercased()] else { continue }
                        do {
                            try runSync { try await immichClient.addAssetsToTag(tagId: tagId, assetIds: [mapping.immichAssetId]) }
                        } catch {
                            tagSyncOK = false
                            progressWrapped(.message("WARN Metadata: attach tag '\(name)' failed for \(asset.localIdentifier): \(error)"))
                        }
                    }
                }

                if assetUpdateOK && tagSyncOK {
                    // Update mapping with new signature only if everything succeeded.
                    let updatedMapping = AssetMapping(
                        localIdentifier: mapping.localIdentifier,
                        immichAssetId: mapping.immichAssetId,
                        deviceAssetId: mapping.deviceAssetId,
                        lastSyncedSignature: currentSignature,
                        lastSyncedAt: Date()
                    )
                    try? assetMappingStore.upsert(updatedMapping)
                    if hasUpdateFields || needsTagSync {
                        metadataSynced += 1
                    }
                }

                if shouldStopMetadataSync() { break }
            }

            var summaryParts: [String] = []
            if metadataSynced > 0 { summaryParts.append("synced \(metadataSynced)") }
            if metadataSkipped > 0 { summaryParts.append("skipped \(metadataSkipped)") }
            if metadataRecovered > 0 { summaryParts.append("recovered \(metadataRecovered) mappings") }
            if metadataNotInImmich > 0 { summaryParts.append("not in Immich \(metadataNotInImmich)") }
            if metadataMappingUnknown > 0 { summaryParts.append("no local mapping \(metadataMappingUnknown)") }
            if metadataErrors > 0 { summaryParts.append("errors \(metadataErrors)") }
            let summary = summaryParts.isEmpty ? "no changes" : summaryParts.joined(separator: ", ")
            progressWrapped(.message("Metadata: sync complete (\(summary))"))
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

/// Sanitize an album title so it is safe to use as a single path component on macOS filesystems.
/// Replaces `/`, `:`, NUL, leading dots; trims whitespace.
/// Returns `_Unsorted` if the cleaned name is empty.
func sanitizeAlbumNameForFolder(_ raw: String) -> String {
    var s = raw
    // Replace path-hostile characters with underscore.
    let bad: [Character] = ["/", ":", "\0", "\\"]
    s = String(s.map { bad.contains($0) ? "_" : $0 })
    // Trim whitespace.
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    // Strip leading dots so directories are not hidden / "." / "..".
    while s.hasPrefix(".") {
        s = String(s.dropFirst())
    }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return "_Unsorted" }
    return s
}

/// Returns the sanitized titles of user-created albums that contain the given asset.
/// System "smart" albums and other non-album collections are excluded.
/// Returns an empty array if the asset is in no user album.
func userAlbumFolderNames(for asset: PHAsset) -> [String] {
    let collections = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
    var names: [String] = []
    var seen: Set<String> = []
    collections.enumerateObjects { collection, _, _ in
        // Only user-created albums (skip smart albums, shared cloud, etc. handled elsewhere).
        guard collection.assetCollectionType == .album else { return }
        let raw = (collection.localizedTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = sanitizeAlbumNameForFolder(raw)
        if seen.insert(sanitized).inserted {
            names.append(sanitized)
        }
    }
    return names
}

func usableCaptureDate(_ date: Date?, calendar: Calendar) -> Date? {
    guard let date else { return nil }
    let year = calendar.component(.year, from: date)
    return year >= 1900 ? date : nil
}

/// Returns the originalFilename of the asset's primary photo/video resource,
/// preferring the still or video before falling back to whatever resource exists
/// (e.g. adjustment sidecars) so the resulting name reflects what the user sees
/// in the Photos app rather than a sidecar's name.
func primaryOriginalFilename(from resources: [PHAssetResource]) -> String? {
    let preferredOrder: [PHAssetResourceType] = [
        .photo, .fullSizePhoto,
        .video, .fullSizeVideo,
        .pairedVideo, .fullSizePairedVideo,
        .audio
    ]
    for type in preferredOrder {
        if let r = resources.first(where: { $0.type == type }), !r.originalFilename.isEmpty {
            return r.originalFilename
        }
    }
    return resources.first?.originalFilename
}

/// Sanitize a filename stem so it is safe to embed in an output path:
/// strip path separators, NUL, control characters, trim whitespace,
/// and cap length to keep total path components well under filesystem limits.
/// Does not lowercase — original casing is preserved.
func sanitizeOriginalNameStem(_ stem: String, maxLength: Int = 60) -> String {
    var cleaned = stem.replacingOccurrences(of: "/", with: "_")
    cleaned = cleaned.replacingOccurrences(of: "\\", with: "_")
    cleaned = cleaned.replacingOccurrences(of: ":", with: "_")
    cleaned = cleaned.replacingOccurrences(of: "\0", with: "")
    // Strip ASCII control characters (0x00-0x1F and 0x7F).
    cleaned = String(cleaned.unicodeScalars.filter { scalar in
        let v = scalar.value
        return !(v < 0x20 || v == 0x7F)
    })
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.count > maxLength {
        cleaned = String(cleaned.prefix(maxLength))
    }
    return cleaned
}

func baseFilename(for date: Date?, localIdentifier: String, originalFilename: String? = nil, format: FilenameFormat = .dateAndOriginal) -> String {
    let id = makeAssetIdShort(localIdentifier)
    guard let date else { return "unknown_\(id)" }
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = .current
    df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let dateStr = df.string(from: date)

    let originalStem: String? = {
        guard let raw = originalFilename else { return nil }
        let stem = (raw as NSString).deletingPathExtension
        let cleaned = sanitizeOriginalNameStem(stem)
        return cleaned.isEmpty ? nil : cleaned
    }()

    switch format {
    case .dateAndId:
        return "\(dateStr)_\(id)"
    case .dateAndOriginal:
        if let stem = originalStem {
            return "\(dateStr)_\(stem)"
        }
        return "\(dateStr)_\(id)"
    case .originalOnly:
        if let stem = originalStem {
            return stem
        }
        return "\(dateStr)_\(id)"
    }
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
    collisionPolicy: PhotoBackupOptions.CollisionPolicy,
    copyInsteadOfMove: Bool = false
) throws -> ExportOutcome {
    // Local helper that either moves or copies the source file, so both code paths
    // (first-time write and rename-to-avoid-collision) share the same behavior.
    func placeFile(from src: URL, to dst: URL) throws {
        if copyInsteadOfMove {
            try FileManager.default.copyItem(at: src, to: dst)
        } else {
            try atomicMove(from: src, to: dst)
        }
    }

    switch collisionPolicy {
    case .skipIdenticalElseRename:
        if !FileManager.default.fileExists(atPath: desiredURL.path) {
            try placeFile(from: tmpURL, to: desiredURL)
            return .exported(url: desiredURL)
        }

        let tmpInfo = try sha256File(tmpURL)
        let existingInfo: (size: UInt64, hashHex: String)
        do {
            existingInfo = try sha256File(desiredURL)
        } catch {
            // If we can't hash the existing file, fall back to renaming to avoid clobbering.
            let alt = uniqueURL(desiredURL)
            try placeFile(from: tmpURL, to: alt)
            return .exported(url: alt)
        }

        if tmpInfo.size == existingInfo.size, tmpInfo.hashHex == existingInfo.hashHex {
            if !copyInsteadOfMove {
                try? FileManager.default.removeItem(at: tmpURL)
            }
            return .skippedIdentical(existing: desiredURL)
        }

        let alt = uniqueURL(desiredURL)
        try placeFile(from: tmpURL, to: alt)
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
    progressCallback: ((_ progress: Double, _ isICloud: Bool) -> Void)? = nil,
    shouldStop: (() -> Bool)? = nil,
    timeoutProvider: (() -> TimeInterval)? = nil,
    cancellationRegistry: InFlightCancellationRegistry? = nil
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
                progressCallback: progressCallback,
                shouldStop: shouldStop,
                timeoutProvider: timeoutProvider,
                cancellationRegistry: cancellationRegistry
            )
            return tmpURL
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            lastError = error

            // If the user clicked Stop, the registry will have cancelled the
            // PhotoKit request, surfacing as a generic Cocoa/PHPhotos error.
            // Convert it into the 499 user-stop sentinel up-front so the
            // per-asset catch blocks recognize it as a stop, not a failure.
            if shouldStop?() == true || cancellationRegistry?.isCancelled() == true {
                throw NSError(domain: "export", code: 499, userInfo: [
                    NSLocalizedDescriptionKey: "Export stopped by user (\(filename))."
                ])
            }

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
    progressCallback: ((_ progress: Double, _ isICloud: Bool) -> Void)?,
    shouldStop: (() -> Bool)? = nil,
    timeoutProvider: (() -> TimeInterval)? = nil,
    cancellationRegistry: InFlightCancellationRegistry? = nil
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

    // We use `requestData` (rather than `writeData`) so we get a cancellable
    // PHAssetResourceDataRequestID. We stream the chunks straight to disk so
    // the on-disk semantics match what `writeData` would have given us.
    FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
    let fileHandle: FileHandle
    do {
        fileHandle = try FileHandle(forWritingTo: tmpURL)
    } catch {
        throw error
    }

    let writeQueue = DispatchQueue(label: "immibridge.resource-write")
    var didFailWriting = false

    let requestID = PHAssetResourceManager.default().requestData(
        for: resource,
        options: opts,
        dataReceivedHandler: { chunk in
            writeQueue.sync {
                guard !didFailWriting else { return }
                do {
                    try fileHandle.write(contentsOf: chunk)
                } catch {
                    didFailWriting = true
                    writeError = error
                }
            }
        },
        completionHandler: { err in
            writeQueue.sync {
                try? fileHandle.close()
            }
            if let err {
                writeError = err
            }
            sema.signal()
        }
    )
    cancellationRegistry?.registerResourceRequest(requestID)
    defer { cancellationRegistry?.deregisterResourceRequest(requestID) }

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

        if shouldStop?() == true {
            // Cancel the underlying PhotoKit request so it actually gives up.
            // The completion handler will still fire with an error; we throw
            // the 499 sentinel ourselves so per-asset catches recognize it.
            PHAssetResourceManager.default().cancelDataRequest(requestID)
            throw NSError(domain: "export", code: 499, userInfo: [
                NSLocalizedDescriptionKey: "Export stopped by user (\(resource.originalFilename))."
            ])
        }

        // If iCloud download in progress, extend timeout
        let baseTimeout = timeoutProvider?() ?? timeoutSeconds
        if tracker.isDownloading {
            effectiveTimeout = max(effectiveTimeout, baseTimeout * iCloudTimeoutMultiplier)
        } else {
            effectiveTimeout = baseTimeout
        }
    }

    if elapsed >= effectiveTimeout {
        // Make sure PhotoKit isn't still chewing on the request before we move on.
        PHAssetResourceManager.default().cancelDataRequest(requestID)
        throw NSError(domain: "export", code: 408, userInfo: [
            NSLocalizedDescriptionKey: "Timed out exporting resource (\(resource.originalFilename))."
        ])
    }

    if let writeError {
        // PhotoKit's cancellation surfaces as PHPhotosError or NSCocoaError.
        // If the user requested stop, hand back the 499 sentinel so the
        // per-asset catch treats it as a stop instead of an error.
        if shouldStop?() == true || cancellationRegistry?.isCancelled() == true {
            throw NSError(domain: "export", code: 499, userInfo: [
                NSLocalizedDescriptionKey: "Export stopped by user (\(resource.originalFilename)).",
                NSUnderlyingErrorKey: writeError
            ])
        }
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
    progressCallback: ((_ progress: Double, _ isICloud: Bool) -> Void)? = nil,
    shouldStop: (() -> Bool)? = nil,
    timeoutProvider: (() -> TimeInterval)? = nil,
    cancellationRegistry: InFlightCancellationRegistry? = nil
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
                progressCallback: progressCallback,
                shouldStop: shouldStop,
                timeoutProvider: timeoutProvider,
                cancellationRegistry: cancellationRegistry
            )
        } catch {
            lastError = error

            // Stop-signaled cancellations should bypass retry classification
            // and surface as the 499 user-stop sentinel.
            if shouldStop?() == true || cancellationRegistry?.isCancelled() == true {
                throw NSError(domain: "export", code: 499, userInfo: [
                    NSLocalizedDescriptionKey: "Export stopped by user (\(filename))."
                ])
            }

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
    progressCallback: ((_ progress: Double, _ isICloud: Bool) -> Void)?,
    shouldStop: (() -> Bool)? = nil,
    timeoutProvider: (() -> TimeInterval)? = nil,
    cancellationRegistry: InFlightCancellationRegistry? = nil
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

    let requestID = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) { data, uti, _, info in
        resultData = data
        resultUTI = uti
        if let err = info?[PHImageErrorKey] as? NSError {
            resultError = err
        }
        sema.signal()
    }
    cancellationRegistry?.registerImageRequest(requestID)
    defer { cancellationRegistry?.deregisterImageRequest(requestID) }

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

        if shouldStop?() == true {
            // Cancel the underlying PhotoKit request so it actually gives up.
            PHImageManager.default().cancelImageRequest(requestID)
            throw NSError(domain: "export", code: 499, userInfo: [
                NSLocalizedDescriptionKey: "Export stopped by user (edited image for \(asset.localIdentifier))."
            ])
        }

        let baseTimeout = timeoutProvider?() ?? timeoutSeconds
        if tracker.isDownloading {
            effectiveTimeout = max(effectiveTimeout, baseTimeout * iCloudTimeoutMultiplier)
        } else {
            effectiveTimeout = baseTimeout
        }
    }

    if elapsed >= effectiveTimeout {
        PHImageManager.default().cancelImageRequest(requestID)
        throw NSError(domain: "edited", code: 408, userInfo: [
            NSLocalizedDescriptionKey: "Timed out rendering edited image."
        ])
    }

    if let resultError {
        // PhotoKit cancellation surfaces as PHImageErrorKey from the request.
        // Normalize to the 499 sentinel when the user pressed Stop.
        if shouldStop?() == true || cancellationRegistry?.isCancelled() == true {
            throw NSError(domain: "export", code: 499, userInfo: [
                NSLocalizedDescriptionKey: "Export stopped by user (edited image for \(asset.localIdentifier)).",
                NSUnderlyingErrorKey: resultError
            ])
        }
        throw resultError
    }
    guard let data = resultData else {
        if shouldStop?() == true || cancellationRegistry?.isCancelled() == true {
            throw NSError(domain: "export", code: 499, userInfo: [
                NSLocalizedDescriptionKey: "Export stopped by user (edited image for \(asset.localIdentifier))."
            ])
        }
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
    /// Optional registry that lets the user's Stop click interrupt in-flight
    /// uploads/JSON requests. Tasks are registered before await and removed
    /// in defer so we never leak refs after completion.
    private let cancellationRegistry: InFlightCancellationRegistry?

    /// Optional sink for one-off diagnostics that the user needs to see in the run log
    /// (currently only the server-version decision). `ImmichClient` has no progress channel
    /// of its own, and the version decision silently changes how the whole run is routed.
    private let logger: (@Sendable (String) -> Void)?

    /// Outcome of one `/server/version` probe. `cacheable` distinguishes a *definitive*
    /// answer (the server responded, we just could not read a major out of it) from a
    /// transport failure, which must not be memoised for the life of the run.
    private struct ServerMajorProbe {
        let major: Int?
        let cacheable: Bool
    }

    /// Caches the `/server/version` probe. `ImmichClient` is shared across the upload
    /// pipeline's concurrent hash/upload/network queues, so this has to be an actor (or a
    /// lock) rather than a plain `var`. Holding the `Task` — not the value — means concurrent
    /// first callers all await the same in-flight probe instead of racing to issue their own.
    ///
    /// A transport failure is deliberately *not* settled: a single 502 from a reverse proxy
    /// at second 0 would otherwise pin a genuine v2 server into v3-compatible mode for the
    /// whole run (no `/assets/exist` skip, no replace-on-change, no mapping recovery).
    /// Retries are bounded so a server that is simply down does not re-probe per asset.
    private actor ServerMajorCache {
        private var settled: Int??
        private var probe: Task<ServerMajorProbe, Never>?
        private var transportFailures = 0
        private let maxTransportFailures = 2

        func major(fetch: @escaping @Sendable () async -> ServerMajorProbe) async -> (major: Int?, isFinal: Bool) {
            if let settled { return (settled, true) }
            if let probe { return (await probe.value.major, false) }

            let task = Task<ServerMajorProbe, Never> { await fetch() }
            probe = task
            let result = await task.value
            if !result.cacheable { transportFailures += 1 }
            let isFinal = result.cacheable || transportFailures >= maxTransportFailures
            if isFinal { settled = .some(result.major) }
            probe = nil
            return (result.major, isFinal)
        }
    }

    private let serverMajorCache = ServerMajorCache()

    init(
        serverURL: URL,
        apiKey: String,
        session: URLSession = .shared,
        cancellationRegistry: InFlightCancellationRegistry? = nil,
        logger: (@Sendable (String) -> Void)? = nil
    ) {
        if serverURL.lastPathComponent == "api" {
            self.apiBase = serverURL
        } else {
            self.apiBase = serverURL.appendingPathComponent("api", isDirectory: false)
        }
        self.apiKey = apiKey
        self.session = session
        self.cancellationRegistry = cancellationRegistry
        self.logger = logger
    }

    func ping() async throws {
        _ = try await requestJSON(method: "GET", path: "server/ping", body: Optional<Data>.none) as ServerPingResponse
    }

    /// `GET /api/server/version` → `{"major":N,"minor":N,"patch":N}`. Present on both v2 and v3.
    ///
    /// The decision is always logged, because it silently re-routes the whole run: on a
    /// misdetected v2 server the `/assets/exist` skip, replace-on-change and metadata mapping
    /// recovery all go quiet, and without a log line there is nothing to explain it.
    private func probeServerMajor() async -> ServerMajorProbe {
        do {
            let resp: ServerVersionResponse = try await requestJSON(
                method: "GET",
                path: "server/version",
                body: Optional<Data>.none
            )
            logger?("Immich: server major \(resp.major) (\(resp.major <= 2 ? "legacy v2 endpoints enabled" : "v3-compatible mode"))")
            return ServerMajorProbe(major: resp.major, cacheable: true)
        } catch {
            // The server answered, we just could not read a version out of it (non-2xx, or a
            // body we cannot decode). That is a definitive "no usable version" — cache it.
            let answered = (error is DecodingError) || ((error as NSError).domain == "immich")
            logger?("Immich: /server/version unavailable (\(error)); using v3-compatible mode\(answered ? "" : " for now")")
            return ServerMajorProbe(major: nil, cacheable: answered)
        }
    }

    /// True only when the server *positively* reports Immich major version 2 or older.
    ///
    /// Deliberately fail-safe: an unreachable or unparseable `/server/version` answers `false`
    /// ("treat as v3"). The v2-only endpoints are the dangerous ones — see the hazard note on
    /// `getAssetIdByDeviceId` — so "unknown" must never unlock them. Guessing v3 when unsure
    /// costs a fast path (and replace-on-change); guessing v2 would corrupt data.
    func isLegacyV2() async -> Bool {
        await legacyV2Decision().isLegacyV2
    }

    /// `isLegacyV2()` plus whether that answer is final. A non-final `false` means the probe hit
    /// a transport failure and is still worth retrying, so callers that memoise the answer
    /// themselves must not pin it — otherwise one 502 at second 0 downgrades a genuine v2 server
    /// for the whole run.
    func legacyV2Decision() async -> (isLegacyV2: Bool, isFinal: Bool) {
        let (major, isFinal) = await serverMajorCache.major { [self] in await probeServerMajor() }
        guard let major else { return (false, isFinal) }
        return (major <= 2, isFinal)
    }

    func getMe() async throws {
        _ = try await requestJSON(method: "GET", path: "users/me", body: Optional<Data>.none) as UserMeResponse
    }

    func getAssetStatistics() async throws -> AssetStatisticsResponse {
        try await requestJSON(method: "GET", path: "assets/statistics", body: Optional<Data>.none)
    }

    /// v2-only. Immich v3 removed `POST /api/assets/exist` outright (it 404s there), so we
    /// skip the round-trip entirely and report "nothing known to exist" — which is exactly how
    /// every caller already treats an empty result. On v3, duplicate detection falls through to
    /// the checksum paths (`bulk-upload-check` / the `x-immich-checksum` upload header).
    func checkExistingAssets(deviceId: String, deviceAssetIds: [String]) async throws -> Set<String> {
        guard await isLegacyV2() else { return [] }
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

    /// v2-only, and the gate below is a *safety* gate, not an optimisation. DO NOT "simplify"
    /// it into a try/catch.
    ///
    /// Immich v3 dropped the `deviceAssetId` / `deviceId` filters from the search DTO, and that
    /// DTO is a Zod object declared **without** `.strict()` — so v3 does not reject the unknown
    /// keys, it silently strips them. The POST therefore returns 200 with the results of an
    /// *unfiltered* search, and `items[0]` is some arbitrary asset from the library. Callers
    /// use the returned id to delete an asset or to write Photos metadata onto it, so trusting
    /// it on v3 means silently clobbering an unrelated asset. There is no error to catch; only a
    /// positively-detected v2 server makes this request meaningful.
    func getAssetIdByDeviceId(deviceId: String, deviceAssetId: String) async throws -> String? {
        guard await isLegacyV2() else { return nil }

        let searchBody: [String: Any] = [
            "deviceAssetId": deviceAssetId,
            "deviceId": deviceId
        ]
        let body = try JSONSerialization.data(withJSONObject: searchBody, options: [])

        do {
            let data = try await requestRaw(method: "POST", path: "search/metadata", body: body)
            if let id = firstSearchResultId(in: data) {
                return id
            }
        } catch {
            print("getAssetIdByDeviceId search failed: \(error)")
        }

        return nil
    }

    /// `POST /search/metadata` answers `{ "assets": { "items": [ { "id": ... } ] } }` on both majors.
    private func firstSearchResultId(in data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = obj["assets"] as? [String: Any],
              let items = assets["items"] as? [[String: Any]],
              let first = items.first,
              let id = first["id"] as? String else {
            return nil
        }
        return id
    }

    func deleteAssets(assetIds: [String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["ids": assetIds], options: [])
        _ = try await requestRaw(method: "DELETE", path: "assets", body: body)
    }

    // MARK: - Metadata Update

    /// Request body for PUT /assets/{id}
    struct UpdateAssetDto: Encodable, Sendable {
        var dateTimeOriginal: String?
        var description: String?
        var isFavorite: Bool?
        /// Immich `AssetVisibility`: "archive" | "timeline" | "hidden" | "locked".
        /// Unconditional on both majors — `isArchived` was never a field on v2.5.6's
        /// `UpdateAssetBase` either (it was accepted and ignored), so sending `visibility`
        /// also fixes archive sync on v2. Set it via `setArchived(_:)`.
        var visibility: String?
        var latitude: Double?
        var longitude: Double?
        var rating: Int?  // -1 to 5

        init(
            dateTimeOriginal: String? = nil,
            description: String? = nil,
            isFavorite: Bool? = nil,
            visibility: String? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil,
            rating: Int? = nil
        ) {
            self.dateTimeOriginal = dateTimeOriginal
            self.description = description
            self.isFavorite = isFavorite
            self.visibility = visibility
            self.latitude = latitude
            self.longitude = longitude
            self.rating = rating
        }

        /// Maps `PHAsset.isHidden` onto the Immich visibility enum.
        mutating func setArchived(_ archived: Bool) {
            visibility = archived ? "archive" : "timeline"
        }

        /// Check if any fields are set (to avoid empty updates)
        var hasChanges: Bool {
            dateTimeOriginal != nil || description != nil || isFavorite != nil ||
            visibility != nil || latitude != nil || longitude != nil || rating != nil
        }
    }

    /// Response from GET/PUT /assets/{id}
    struct AssetResponseDto: Decodable {
        let id: String
        let isFavorite: Bool?
        /// Older/v2 servers still return this boolean; v3 dropped it in favour of `visibility`.
        let isArchived: Bool?
        /// v3 (and late v2) `AssetVisibility`: "archive" | "timeline" | "hidden" | "locked".
        let visibility: String?
        let latitude: Double?
        let longitude: Double?
        let dateTimeOriginal: String?

        /// Nested exifInfo for location data (Immich sometimes returns location in exifInfo)
        struct ExifInfo: Decodable {
            let latitude: Double?
            let longitude: Double?
            let dateTimeOriginal: String?
        }
        let exifInfo: ExifInfo?

        /// Get latitude from either top-level or exifInfo
        var effectiveLatitude: Double? { latitude ?? exifInfo?.latitude }
        var effectiveLongitude: Double? { longitude ?? exifInfo?.longitude }
        var effectiveDateTimeOriginal: String? { dateTimeOriginal ?? exifInfo?.dateTimeOriginal }
        /// Prefer whichever archive representation the server actually sent.
        var effectiveIsArchived: Bool { isArchived ?? (visibility == "archive") }
    }

    /// Fetch asset details from Immich
    func getAsset(assetId: String) async throws -> AssetResponseDto {
        return try await requestJSON(method: "GET", path: "assets/\(assetId)", body: nil)
    }

    /// Fetch asset details, returning nil if not found (404)
    func getAssetIfExists(assetId: String) async throws -> AssetResponseDto? {
        do {
            return try await getAsset(assetId: assetId)
        } catch let error as NSError where error.code == 404 {
            return nil
        }
    }

    /// Update metadata for a single asset
    func updateAsset(assetId: String, update: UpdateAssetDto) async throws -> AssetResponseDto {
        let body = try JSONEncoder().encode(update)
        return try await requestJSON(method: "PUT", path: "assets/\(assetId)", body: body)
    }

    /// Error indicating asset not found (404)
    struct AssetNotFoundError: Error {
        let assetId: String
    }

    /// Update metadata for a single asset, returning nil if asset not found (404)
    func updateAssetIfExists(assetId: String, update: UpdateAssetDto) async throws -> AssetResponseDto? {
        do {
            return try await updateAsset(assetId: assetId, update: update)
        } catch let error as NSError where error.code == 404 {
            return nil
        }
    }

    // MARK: - Tags

    struct TagDto: Decodable {
        let id: String
        let name: String?
        let value: String?
    }

    /// List all tags on the server.
    func listTags() async throws -> [TagDto] {
        try await requestJSON(method: "GET", path: "tags", body: Optional<Data>.none)
    }

    /// Create (or fetch existing) tags by name. Returns the created/found TagDto for each name.
    /// Uses the Immich v2.5+ upsert endpoint: PUT /api/tags  body: { "tags": ["name1", ...] }
    func upsertTags(names: [String]) async throws -> [TagDto] {
        guard !names.isEmpty else { return [] }
        let body = try JSONSerialization.data(withJSONObject: ["tags": names], options: [])
        // Some Immich versions expose the upsert at PUT /tags, others at PUT /tags/upsert.
        do {
            return try await requestJSON(method: "PUT", path: "tags", body: body)
        } catch {
            // Fallback for older API surface
            return try await requestJSON(method: "PUT", path: "tags/upsert", body: body)
        }
    }

    /// Bulk-attach a single tag to many assets. Body: { "ids": [assetId, ...] }
    /// Endpoint: PUT /api/tags/{tagId}/assets
    func addAssetsToTag(tagId: String, assetIds: [String]) async throws {
        guard !assetIds.isEmpty else { return }
        let body = try JSONSerialization.data(withJSONObject: ["ids": assetIds], options: [])
        _ = try await requestRaw(method: "PUT", path: "tags/\(tagId)/assets", body: body)
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
        // Always sent, no version branch: v2.5.6's AssetMediaBase declares both @IsNotEmpty()
        // and non-optional (omitting them is a 400 on every upload), while v3 removed them from
        // the schema — and its Zod object has no `.strict()`, so it silently strips them.
        // One payload serves both majors.
        fields.append(("deviceId", deviceId))
        fields.append(("deviceAssetId", deviceAssetId))
        fields.append(("fileCreatedAt", iso8601(fileCreatedAt)))
        fields.append(("fileModifiedAt", iso8601(fileModifiedAt)))
        fields.append(("filename", filename))
        if let durationSeconds {
            // v2 takes any string here; v3 parses it with `z.coerce.number().int().min(0)` and
            // rejects the old `String(durationSeconds)` ("5.0") on the `.int()` check.
            // Integer milliseconds as a string satisfies both majors, so no version branch.
            let durationMilliseconds = max(0, Int((durationSeconds * 1000).rounded()))
            fields.append(("duration", String(durationMilliseconds)))
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

        let (data, response) = try await performUpload(request: req, fromFile: tmpURL)
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
        let (data, response) = try await performData(request: req)
        try ensureHTTP(response, data: data)
        return data
    }

    /// URLSession data wrapper that registers the underlying `URLSessionDataTask`
    /// with the cancellation registry so the user's Stop click can abort it.
    /// Falls back to `session.data(for:)` when no registry is wired.
    private func performData(request: URLRequest) async throws -> (Data, URLResponse) {
        guard let registry = cancellationRegistry else {
            return try await session.data(for: request)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            // We have to declare `task` first so the completion handler can
            // capture it by reference for deregister-on-completion.
            var taskRef: URLSessionDataTask?
            let task = session.dataTask(with: request) { data, response, error in
                if let t = taskRef { registry.deregisterURLSessionTask(t) }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            taskRef = task
            registry.registerURLSessionTask(task)
            task.resume()
        }
    }

    /// URLSession upload wrapper, mirror of `performData` for multipart file uploads.
    private func performUpload(request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        guard let registry = cancellationRegistry else {
            return try await session.upload(for: request, fromFile: fileURL)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            var taskRef: URLSessionUploadTask?
            let task = session.uploadTask(with: request, fromFile: fileURL) { data, response, error in
                if let t = taskRef { registry.deregisterURLSessionTask(t) }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            taskRef = task
            registry.registerURLSessionTask(task)
            task.resume()
        }
    }

    private func requestJSON<T: Decodable>(method: String, path: String, body: Data?) async throws -> T {
        let data = try await requestRaw(method: method, path: path, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private final class ImmichUploadPipeline {
    private struct FailedUploadRecord: Codable {
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
    private let failedUploadsDir: URL?
    /// `(deviceAssetId, immichAssetId)` for every work item the server ends up holding —
    /// freshly uploaded or answered as a checksum duplicate. Unlike `onImmichAssetId` (album
    /// collection only, and nil unless the asset is in an album) this fires unconditionally.
    private let onAssetPersisted: (@Sendable (String, String) -> Void)?

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

    private var serverIsLegacyV2Cache: Bool?

    private var pendingBulkCheckById: [String: (work: WorkItem, sha1: String)] = [:]
    private var pendingBulkCheckFIFO: [String] = []
    private var bulkCheckInProgress: Bool = false
    private let bulkCheckFlushDelaySeconds: TimeInterval = 1.0
    private var bulkCheckFlushTimer: DispatchSourceTimer?

    init(
        immich: ImmichUploadOptions,
        client: ImmichClient,
        progress: @escaping @Sendable (PhotoBackupProgress) -> Void,
        shouldCancel: @escaping @Sendable () -> Bool,
        failedUploadsDir: URL?,
        onAssetPersisted: (@Sendable (String, String) -> Void)? = nil
    ) {
        self.immich = immich
        self.client = client
        self.progress = progress
        self.shouldCancel = shouldCancel
        self.failedUploadsDir = failedUploadsDir
        self.onAssetPersisted = onAssetPersisted
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

	    func snapshotExistingDeviceAssetIds() -> Set<String> {
	        stateQueue.sync { existingDeviceAssetIds }
	    }

	    /// Memoised server-major answer. `ImmichClient` already caches the probe itself; this
	    /// second layer only exists so the per-asset `enqueue` path doesn't spin up a detached
	    /// Task + semaphore (`runSync`) for every single variant of every asset.
	    ///
	    /// Only a *final* answer is memoised — a probe that failed in transport is still
	    /// retryable, and pinning it here would silently downgrade a real v2 server for the run.
	    func serverIsLegacyV2() -> Bool {
	        if let cached = stateQueue.sync(execute: { serverIsLegacyV2Cache }) { return cached }
	        let decision = (try? runSync { await self.client.legacyV2Decision() }) ?? (isLegacyV2: false, isFinal: false)
	        if decision.isFinal {
	            stateQueue.sync { serverIsLegacyV2Cache = decision.isLegacyV2 }
	        }
	        return decision.isLegacyV2
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

        // Immich v3 removed /assets/exist, so `existingDeviceAssetIds` is permanently empty there
        // and the fast exist-skip below can never fire. That would leave a default-configured run
        // (albums off, update-changed off) with no client-side duplicate gate at all — i.e. a full
        // re-upload of the library, and a full iCloud re-download, on every run. The checksum
        // bulk-upload-check works on both majors, so force it on when we are not on v2. We already
        // hash every file on this path, so this costs one batched round-trip, not extra CPU.
        // v2 keeps its exact previous routing.
        let useChecksumPrecheck = immich.checksumPrecheck || !serverIsLegacyV2()
        let shouldUseFastExistSkip = !(immich.syncAlbums || immich.updateChangedAssets) && !useChecksumPrecheck
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
        } else if !useChecksumPrecheck {
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
                        // ponytail: v2-only in practice. v3 has no /assets/exist, so
                        // `existingDeviceAssetIds` is always empty there and update-changed never
                        // replaces — a changed asset uploads as a new one and the stale copy stays.
                        // Ceiling: replacing on v3 would need a persisted deviceAssetId→assetId map.
                        let shouldReplaceExisting: Bool = self.stateQueue.sync {
                            self.immich.updateChangedAssets && self.existingDeviceAssetIds.contains(work.deviceAssetId)
                        }

                        if shouldReplaceExisting {
                            do {
                                // Device-id search only. A checksum search for `sha1` cannot help
                                // here: reaching this branch means bulk-upload-check just answered
                                // "no asset of yours carries that checksum", and the search filter
                                // sees a strict subset of what that check covers. It would also be
                                // the wrong question — we want the *previous* asset's id, not the
                                // id of the new bytes we are about to upload.
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
                self.archiveFailedUpload(work: work, error: error)
                self.finish(work: work, result: .failure(error))
            }
        }
    }

    private func archiveFailedUpload(work: WorkItem, error: Error) {
        guard let failedUploadsDir else { return }
        do {
            try FileManager.default.createDirectory(at: failedUploadsDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            progress(.message("ERROR Immich: could not create failed uploads dir: \(error)"))
            return
        }

        let uniquePrefix = UUID().uuidString
        // Do not archive the failed file itself (could silently consume disk).
        // Always clean up temp files created for upload.
        if let deleteAfterUpload = work.deleteAfterUpload {
            try? FileManager.default.removeItem(at: deleteAfterUpload)
        }

        let metadataJSON: Data = (try? JSONSerialization.data(withJSONObject: work.metadata, options: [])) ?? Data()
        let phAssetLocalIdentifier: String? = {
            guard let obj = try? JSONSerialization.jsonObject(with: metadataJSON) as? [[String: Any]] else { return nil }
            for e in obj {
                guard let value = e["value"] as? [String: Any] else { continue }
                if let id = value["phAssetLocalIdentifier"] as? String { return id }
            }
            return nil
        }()
        let record = FailedUploadRecord(
            savedAt: Date(),
            deviceId: work.deviceId,
            deviceAssetId: work.deviceAssetId,
            phAssetLocalIdentifier: phAssetLocalIdentifier,
            filename: work.filename,
            fileCreatedAt: work.fileCreatedAt,
            fileModifiedAt: work.fileModifiedAt,
            durationSeconds: work.durationSeconds,
            isFavorite: work.isFavorite,
            livePhotoVideoId: work.livePhotoVideoId,
            metadataJSON: metadataJSON,
            errorDescription: String(describing: error)
        )

        let recordURL = failedUploadsDir.appendingPathComponent("failed-upload-\(uniquePrefix).json", isDirectory: false)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)
            try data.write(to: recordURL, options: [.atomic])
            progress(.message("Immich: recorded failed upload (\(work.deviceAssetId))"))
        } catch {
            progress(.message("ERROR Immich: could not write failed upload record: \(error)"))
        }
    }

    private func finish(work: WorkItem, result: Result<String?, Error>) {
        if case .success(let id) = result {
            work.onImmichAssetId?(id)
            if let id {
                onAssetPersisted?(work.deviceAssetId, id)
            }
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

/// `GET /api/server/version` — semver as numeric fields on both v2 and v3.
private struct ServerVersionResponse: Decodable {
    let major: Int
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

/// Internal (not file-private) so the folder-source syncer can reuse the exact same digest
/// the Photos pipeline sends as `x-immich-checksum`.
func sha1HexFile(_ url: URL) throws -> String {
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
    onImmichAssetId: (@Sendable (String?) -> Void)? = nil,
    shouldStop: (() -> Bool)? = nil,
    timeoutProvider: (() -> TimeInterval)? = nil,
    cancellationRegistry: InFlightCancellationRegistry? = nil
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
        },
        shouldStop: shouldStop,
        timeoutProvider: timeoutProvider,
        cancellationRegistry: cancellationRegistry
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
            isFavorite: asset.isFavorite,
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
    onImmichAssetId: (@Sendable (String?) -> Void)? = nil,
    shouldStop: (() -> Bool)? = nil,
    timeoutProvider: (() -> TimeInterval)? = nil,
    cancellationRegistry: InFlightCancellationRegistry? = nil
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
        },
        shouldStop: shouldStop,
        timeoutProvider: timeoutProvider,
        cancellationRegistry: cancellationRegistry
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
            isFavorite: asset.isFavorite,
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
