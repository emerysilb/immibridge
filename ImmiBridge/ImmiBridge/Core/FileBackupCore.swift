import Foundation

public struct FileBackupOptions: Sendable {
    public var sources: [URL]
    public var destination: URL
    public var mode: BackupMode
    public var includeHiddenFiles: Bool
    public var followSymlinks: Bool
    public var dryRun: Bool
    public var requestTimeoutSeconds: TimeInterval

    public init(
        sources: [URL],
        destination: URL,
        mode: BackupMode,
        includeHiddenFiles: Bool = false,
        followSymlinks: Bool = false,
        dryRun: Bool = false,
        requestTimeoutSeconds: TimeInterval = 300
    ) {
        self.sources = sources
        self.destination = destination
        self.mode = mode
        self.includeHiddenFiles = includeHiddenFiles
        self.followSymlinks = followSymlinks
        self.dryRun = dryRun
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }
}

public struct FileBackupResult: Sendable {
    public var scannedFiles: Int
    public var copiedFiles: Int
    public var skippedFiles: Int
    public var deletedFiles: Int
    public var errorCount: Int

    public init(scannedFiles: Int, copiedFiles: Int, skippedFiles: Int, deletedFiles: Int, errorCount: Int) {
        self.scannedFiles = scannedFiles
        self.copiedFiles = copiedFiles
        self.skippedFiles = skippedFiles
        self.deletedFiles = deletedFiles
        self.errorCount = errorCount
    }
}

public final class FileBackupExporter {
    public init() {}

    public func run(
        options: FileBackupOptions,
        manifest: ManifestStore,
        runId: String,
        progress: @escaping @Sendable (PhotoBackupProgress) -> Void,
        runState: @escaping @Sendable () -> BackupRunState
    ) -> FileBackupResult {
        let fm = FileManager.default

        var scanned = 0
        var copied = 0
        var skipped = 0
        var deleted = 0
        var errors = 0

        progress(.fileScanning)

        var files: [(srcRoot: URL, fileURL: URL, relPath: String)] = []
        for root in options.sources {
            if runState() == .cancelled { break }
            let standardizedRoot = root.standardizedFileURL
            let keys: [URLResourceKey] = [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isHiddenKey
            ]
            let opts: FileManager.DirectoryEnumerationOptions = options.includeHiddenFiles ? [] : [.skipsHiddenFiles]
            guard let e = fm.enumerator(at: standardizedRoot, includingPropertiesForKeys: keys, options: opts) else { continue }
            for case let url as URL in e {
                if runState() == .cancelled { break }
                if runState() == .paused {
                    progress(.message("Files: pause requested; stopping after scan"))
                    break
                }

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
                files.append((srcRoot: standardizedRoot, fileURL: url, relPath: rel))
            }
        }

        progress(.fileWillCopy(totalFiles: files.count))

        for (idx, file) in files.enumerated() {
            if runState() == .cancelled { break }
            if runState() == .paused { break }
            scanned += 1
            progress(.fileCopying(index: idx + 1, total: files.count, relativePath: file.relPath))

            let destURL = options.destination.appendingPathComponent(file.relPath, isDirectory: false)
            let destDir = destURL.deletingLastPathComponent()
            do { try ensureDir(destDir) } catch {
                errors += 1
                progress(.message("ERROR Files: could not create dir \(destDir.path): \(error)"))
                continue
            }

            let attrs = (try? fm.attributesOfItem(atPath: file.fileURL.path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let signature = "size:\(size);mtime:\(mtime)"
            let key = "file:\(file.relPath)"

            if options.mode != .full, let existing = manifest.get(key: key), existing.deletedAt == nil {
                if existing.signature == signature, fm.fileExists(atPath: options.destination.appendingPathComponent(existing.relPath).path) {
                    skipped += 1
                    do {
                        try manifest.upsert(ManifestEntry(
                            key: key,
                            relPath: file.relPath,
                            signature: signature,
                            size: size,
                            mtime: mtime,
                            lastSeenRunId: runId,
                            deletedAt: nil
                        ))
                    } catch {
                        errors += 1
                        progress(.message("ERROR Files: manifest update failed: \(error)"))
                    }
                    continue
                }
            }

            if options.dryRun {
                copied += 1
                continue
            }

            do {
                try ensureUbiquitousItemIsDownloaded(file.fileURL, timeoutSeconds: options.requestTimeoutSeconds)
            } catch {
                errors += 1
                progress(.message("ERROR Files: iCloud download failed for \(file.relPath): \(error)"))
                continue
            }

            let tmpURL = options.destination
                .appendingPathComponent(".immibridge-tmp", isDirectory: true)
                .appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: false)
            do {
                try ensureDir(tmpURL.deletingLastPathComponent())
                try fm.copyItem(at: file.fileURL, to: tmpURL)
            } catch {
                errors += 1
                progress(.message("ERROR Files: copy failed for \(file.relPath): \(error)"))
                try? fm.removeItem(at: tmpURL)
                continue
            }

            do {
                _ = try placeTempFile(tmpURL: tmpURL, desiredURL: destURL, collisionPolicy: .skipIdenticalElseRename)
                copied += 1
                do {
                    try manifest.upsert(ManifestEntry(
                        key: key,
                        relPath: file.relPath,
                        signature: signature,
                        size: size,
                        mtime: mtime,
                        lastSeenRunId: runId,
                        deletedAt: nil
                    ))
                } catch {
                    errors += 1
                    progress(.message("ERROR Files: manifest update failed: \(error)"))
                }
            } catch {
                errors += 1
                progress(.message("ERROR Files: place failed for \(file.relPath): \(error)"))
                try? fm.removeItem(at: tmpURL)
            }

            evictUbiquitousItemIfPossible(file.fileURL)
        }

        if options.mode == .mirror, !options.dryRun {
            let notSeen = manifest.keysNotSeen(runId: runId).filter { $0.hasPrefix("file:") }
            for key in notSeen {
                if runState() == .cancelled { break }
                guard let entry = manifest.get(key: key), entry.deletedAt == nil else { continue }
                let path = entry.relPath
                let url = options.destination.appendingPathComponent(path, isDirectory: false)
                if fm.fileExists(atPath: url.path) {
                    do {
                        try fm.removeItem(at: url)
                        deleted += 1
                        try manifest.markDeleted(key: key)
                    } catch {
                        errors += 1
                        progress(.message("ERROR Files: delete failed for \(path): \(error)"))
                    }
                } else {
                    _ = try? manifest.markDeleted(key: key)
                }
            }
        }

        return FileBackupResult(
            scannedFiles: scanned,
            copiedFiles: copied,
            skippedFiles: skipped,
            deletedFiles: deleted,
            errorCount: errors
        )
    }
}

