
// ===== TEST SHIM =====
// ImmichUploadPipeline is file-private, so the second-run duplicate test cannot reach it
// from another file. run.sh concatenates the real Core/PhotoBackupCore.swift with this
// file to get a compilation unit that shares its scope.
//
// Concatenated at build time on purpose: a checked-in copy of PhotoBackupCore.swift would
// rot the first time someone edited the real one, and the test would then be verifying
// code that no longer ships.

final class DupBox: @unchecked Sendable {
    let lock = NSLock()
    var persisted: [String: String] = [:]
    var dupSkips = 0
}

struct DupPassResult {
    var persisted: [String: String]
    var dupSkips: Int
}

func __dupTestPass(
    label: String,
    options: ImmichUploadOptions,
    client: ImmichClient,
    files: [(url: URL, deviceAssetId: String)]
) -> DupPassResult {
    let box = DupBox()
    let noDir: URL? = nil

    let pipeline = ImmichUploadPipeline(
        immich: options,
        client: client,
        progress: { p in
            if case .message(let m) = p {
                if m.contains("duplicate, skipping upload") {
                    box.lock.lock(); box.dupSkips += 1; box.lock.unlock()
                }
                print("         [\(label)] \(m)")
            }
        },
        shouldCancel: { false },
        failedUploadsDir: noDir,
        onAssetPersisted: { dev, immich in
            box.lock.lock(); box.persisted[dev] = immich; box.lock.unlock()
        }
    )

    let noURL: URL? = nil
    let noDuration: Double? = nil
    let noLivePhoto: String? = nil
    let meta: [[String: Any]] = []
    for f in files {
        _ = try? pipeline.enqueue(
            fileURL: f.url, deleteAfterUpload: noURL, deviceAssetId: f.deviceAssetId,
            filename: f.url.lastPathComponent,
            fileCreatedAt: Date(), fileModifiedAt: Date(),
            durationSeconds: noDuration, isFavorite: false, livePhotoVideoId: noLivePhoto,
            metadata: meta, awaitResult: true)
    }
    pipeline.finishAndWait()
    box.lock.lock(); defer { box.lock.unlock() }
    return DupPassResult(persisted: box.persisted, dupSkips: box.dupSkips)
}
