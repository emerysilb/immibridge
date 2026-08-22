import Foundation

/// Triggers the macOS Local Network privacy prompt.
///
/// Originally contributed by @59n in PR #29.
///
/// A plain `URLSession` request to a LAN address can fail with "Local network
/// prohibited" *without* macOS ever showing the permission dialog. When that happens the
/// app never appears in System Settings → Privacy & Security → Local Network at all, so
/// telling the user to enable the toggle is useless — there is nothing there to enable.
///
/// Browsing a Bonjour service type declared in `NSBonjourServices` is the reliable way to
/// make TCC present the dialog. We do not care about the results of the browse; running it
/// at all is the point.
enum LocalNetworkPermission {
    private static let lock = NSLock()
    private static var browser: NetServiceBrowser?
    private static var delegateBox: BrowserDelegate?
    private static var stopWorkItem: DispatchWorkItem?

    /// Browse period. Long enough for TCC to present the sheet, short enough that we are
    /// not holding a browser open behind the user's back.
    private static let browseDuration: TimeInterval = 3.0

    /// Starts a short Bonjour browse so TCC can show the permission dialog.
    /// Safe to call repeatedly; an in-flight browse is replaced rather than stacked.
    static func requestPrompt() {
        // NetServiceBrowser must be started on the main thread.
        if Thread.isMainThread {
            startBrowseOnMain()
        } else {
            DispatchQueue.main.async { startBrowseOnMain() }
        }
    }

    private static func startBrowseOnMain() {
        lock.lock()
        defer { lock.unlock() }

        browser?.stop()
        stopWorkItem?.cancel()
        browser = nil
        delegateBox = nil
        stopWorkItem = nil

        let newBrowser = NetServiceBrowser()
        let newDelegate = BrowserDelegate()
        newBrowser.delegate = newDelegate
        // Service type must appear in Info.plist -> NSBonjourServices, or the browse is
        // rejected before TCC is ever consulted.
        newBrowser.searchForServices(ofType: "_http._tcp.", inDomain: "local.")

        browser = newBrowser
        delegateBox = newDelegate

        let work = DispatchWorkItem {
            lock.lock()
            defer { lock.unlock() }
            newBrowser.stop()
            // Only clear if we are still the current browse; a newer one may have replaced us.
            if browser === newBrowser {
                browser = nil
                delegateBox = nil
            }
            stopWorkItem = nil
        }
        stopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + browseDuration, execute: work)
    }
}

/// `NetServiceBrowser` holds its delegate weakly, so something has to keep this alive for
/// the duration of the search.
private final class BrowserDelegate: NSObject, NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        // Permission denied, or no interface to browse on. Nothing to do: the actual
        // connection attempt is what surfaces a user-facing error.
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        // Results are irrelevant — running the browse is what prompts for permission.
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {}
}
