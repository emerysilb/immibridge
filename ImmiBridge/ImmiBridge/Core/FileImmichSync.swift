import Foundation

public struct FileImmichSyncOptions: Sendable {
    public var sources: [URL]
    public var immich: ImmichUploadOptions
    public var updateChanged: Bool
    public var requestTimeoutSeconds: TimeInterval
    public var includeHiddenFiles: Bool
    public var followSymlinks: Bool
    public var dryRun: Bool

    public init(
        sources: [URL],
        immich: ImmichUploadOptions,
        updateChanged: Bool,
        requestTimeoutSeconds: TimeInterval,
        includeHiddenFiles: Bool = false,
        followSymlinks: Bool = false,
        dryRun: Bool = false
    ) {
        self.sources = sources
        self.immich = immich
        self.updateChanged = updateChanged
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.includeHiddenFiles = includeHiddenFiles
        self.followSymlinks = followSymlinks
        self.dryRun = dryRun
    }
}

public struct FileImmichSyncResult: Sendable {
    public var scannedFiles: Int
    public var uploadedFiles: Int
    public var skippedExisting: Int
    public var replacedFiles: Int
    public var errorCount: Int

    public init(scannedFiles: Int, uploadedFiles: Int, skippedExisting: Int, replacedFiles: Int, errorCount: Int) {
        self.scannedFiles = scannedFiles
        self.uploadedFiles = uploadedFiles
        self.skippedExisting = skippedExisting
        self.replacedFiles = replacedFiles
        self.errorCount = errorCount
    }
}

public final class FileImmichSyncer {
    public init() {}

    public func run(
        options: FileImmichSyncOptions,
        progress: @escaping @Sendable (PhotoBackupProgress) -> Void,
        runState: @escaping @Sendable () -> BackupRunState
    ) -> FileImmichSyncResult {
        let fm = FileManager.default
        let immich = options.immich

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = options.requestTimeoutSeconds
        config.timeoutIntervalForResource = options.requestTimeoutSeconds
        config.httpMaximumConnectionsPerHost = immich.uploadConcurrency
        let session = URLSession(configuration: config)
        let client = ImmichClient(serverURL: immich.serverURL, apiKey: immich.apiKey, session: session)

        var files: [(root: URL, url: URL, relPath: String, createdAt: Date, modifiedAt: Date)] = []
        var scanned = 0

        progress(.fileScanning)

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isHiddenKey
        ]
        let enumOpts: FileManager.DirectoryEnumerationOptions = options.includeHiddenFiles ? [] : [.skipsHiddenFiles]

        for root in options.sources {
            if runState() == .cancelled { break }
            let standardizedRoot = root.standardizedFileURL
            guard let e = fm.enumerator(at: standardizedRoot, includingPropertiesForKeys: keys, options: enumOpts) else { continue }
            for case let url as URL in e {
                if runState() == .cancelled { break }
                if runState() == .paused { break }

                if !options.followSymlinks {
                    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                        continue
                    }
                }

                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
                guard values?.isRegularFile == true else { continue }
                if !options.includeHiddenFiles, values?.isHidden == true { continue }

                let rel = url.path.replacingOccurrences(of: standardizedRoot.path, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if rel.isEmpty { continue }

                let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
                let createdAt = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) ?? Date()
                let modifiedAt = (attrs[.modificationDate] as? Date) ?? createdAt
                files.append((root: standardizedRoot, url: url, relPath: rel, createdAt: createdAt, modifiedAt: modifiedAt))
            }
        }

        progress(.fileWillCopy(totalFiles: files.count))

        func deviceAssetId(for file: (root: URL, url: URL, relPath: String, createdAt: Date, modifiedAt: Date)) -> String {
            // Stable across runs on the same machine for “already synced?” checks.
            // If you want multiple roots to coexist, prefix with the root lastPathComponent.
            return "file:\(file.relPath)"
        }

        // Batch exist check
        var existingIds = Set<String>()
        let deviceIds = files.map { deviceAssetId(for: $0) }
        if !deviceIds.isEmpty {
            let batchSize = max(1, immich.existBatchSize)
            var checked = 0
            while checked < deviceIds.count {
                if runState() == .cancelled { break }
                let end = min(deviceIds.count, checked + batchSize)
                let batch = Array(deviceIds[checked..<end])
                do {
                    let exist = try runSync { try await client.checkExistingAssets(deviceId: immich.deviceId, deviceAssetIds: batch) }
                    existingIds.formUnion(exist)
                } catch {
                    progress(.message("ERROR Immich: /assets/exist failed for file sync: \(error)"))
                }
                checked = end
                progress(.immichExistingCheck(checked: checked, total: deviceIds.count))
            }
        }

        var uploaded = 0
        var skipped = 0
        var replaced = 0
        var errors = 0

        for (idx, file) in files.enumerated() {
            if runState() == .cancelled { break }
            if runState() == .paused { break }
            scanned += 1
            progress(.fileCopying(index: idx + 1, total: files.count, relativePath: file.relPath))

            let id = deviceAssetId(for: file)
            if existingIds.contains(id) {
                if options.updateChanged {
                    do {
                        if let immichId = try runSync({ try await client.getAssetIdByDeviceId(deviceId: immich.deviceId, deviceAssetId: id) }) {
                            if !options.dryRun {
                                try runSync({ try await client.deleteAssets(assetIds: [immichId]) })
                            }
                            replaced += 1
                        } else {
                            skipped += 1
                            continue
                        }
                    } catch {
                        errors += 1
                        progress(.message("ERROR Immich: failed to replace existing file \(file.relPath): \(error)"))
                        continue
                    }
                } else {
                    skipped += 1
                    continue
                }
            }

            if options.dryRun {
                uploaded += 1
                continue
            }

            do {
                // iCloud Drive: download on demand; then best-effort re-evict.
                try ensureUbiquitousItemIsDownloaded(file.url, timeoutSeconds: options.requestTimeoutSeconds)
                let filename = file.url.lastPathComponent
                let meta: [[String: Any]] = [[
                    "filename": filename,
                    "type": "file",
                    "filePath": file.relPath,
                    "createdAt": iso8601String(file.createdAt),
                    "modifiedAt": iso8601String(file.modifiedAt),
                ]]
                _ = try runSync {
                    try await client.uploadAsset(
                        fileURL: file.url,
                        sha1Hex: nil,
                        deviceId: immich.deviceId,
                        deviceAssetId: id,
                        filename: filename,
                        fileCreatedAt: file.createdAt,
                        fileModifiedAt: file.modifiedAt,
                        durationSeconds: nil,
                        isFavorite: nil,
                        livePhotoVideoId: nil,
                        metadata: meta
                    )
                }
                uploaded += 1
                evictUbiquitousItemIfPossible(file.url)
            } catch {
                errors += 1
                progress(.message("ERROR Immich: upload failed for file \(file.relPath): \(error)"))
            }
        }

        return FileImmichSyncResult(
            scannedFiles: scanned,
            uploadedFiles: uploaded,
            skippedExisting: skipped,
            replacedFiles: replaced,
            errorCount: errors
        )
    }
}

private func iso8601String(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

private func runSync<T>(_ op: @escaping @Sendable () async throws -> T) throws -> T {
    let sema = DispatchSemaphore(value: 0)
    var out: Result<T, Error>?
    Task.detached {
        do {
            let value = try await op()
            out = .success(value)
        } catch {
            out = .failure(error)
        }
        sema.signal()
    }
    sema.wait()
    return try out!.get()
}
