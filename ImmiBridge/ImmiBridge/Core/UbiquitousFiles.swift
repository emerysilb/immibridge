import Foundation

struct UbiquitousStatus {
    let isUbiquitous: Bool
    let downloadingStatus: URLUbiquitousItemDownloadingStatus?
}

func ubiquitousStatus(for url: URL) -> UbiquitousStatus {
    let values = try? url.resourceValues(forKeys: [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey
    ])
    return UbiquitousStatus(
        isUbiquitous: values?.isUbiquitousItem ?? false,
        downloadingStatus: values?.ubiquitousItemDownloadingStatus
    )
}

func ensureUbiquitousItemIsDownloaded(
    _ url: URL,
    timeoutSeconds: TimeInterval,
    pollInterval: TimeInterval = 0.25
) throws {
    let fm = FileManager.default
    let start = Date()

    let status0 = ubiquitousStatus(for: url)
    guard status0.isUbiquitous else { return }

    do {
        try fm.startDownloadingUbiquitousItem(at: url)
    } catch {
        // Best-effort; if already downloading, we can still wait.
    }

    while true {
        let status = ubiquitousStatus(for: url)
        if !status.isUbiquitous { return }
        if status.downloadingStatus == .current { return }
        if Date().timeIntervalSince(start) >= timeoutSeconds {
            throw NSError(domain: "UbiquitousFiles", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Timed out downloading iCloud item: \(url.lastPathComponent)"
            ])
        }
        Thread.sleep(forTimeInterval: pollInterval)
    }
}

func evictUbiquitousItemIfPossible(_ url: URL) {
    let fm = FileManager.default
    let status = ubiquitousStatus(for: url)
    guard status.isUbiquitous else { return }
    _ = try? fm.evictUbiquitousItem(at: url)
}

