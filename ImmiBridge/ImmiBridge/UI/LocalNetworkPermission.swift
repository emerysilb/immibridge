import Foundation

/// Triggers the macOS Local Network privacy prompt.
///
/// Plain `URLSession` requests to LAN IPs often fail with
/// "Local network prohibited" *without* ever showing the system dialog.
/// Browsing a Bonjour service type declared in `NSBonjourServices` is the
/// reliable way to surface **System Settings → Privacy & Security → Local Network**.
enum LocalNetworkPermission {
    private static let lock = NSLock()
    private static var browser: NetServiceBrowser?
    private static var delegateBox: BrowserDelegate?
    private static var keepAliveWorkItem: DispatchWorkItem?

    /// Starts a short Bonjour browse so TCC can show the permission dialog.
    /// Safe to call repeatedly; overlaps are coalesced.
    static func requestPrompt() {
        // NetServiceBrowser must be started on the main thread.
        if Thread.isMainThread {
            startBrowseOnMain()
        } else {
            DispatchQueue.main.async {
                startBrowseOnMain()
            }
        }
    }

    private static func startBrowseOnMain() {
        lock.lock()
        defer { lock.unlock() }

        browser?.stop()
        keepAliveWorkItem?.cancel()
        browser = nil
        delegateBox = nil
        keepAliveWorkItem = nil

        let newBrowser = NetServiceBrowser()
        let newDelegate = BrowserDelegate()
        newBrowser.delegate = newDelegate
        // Service type must appear in Info.plist → NSBonjourServices.
        newBrowser.searchForServices(ofType: "_http._tcp.", inDomain: "local.")

        browser = newBrowser
        delegateBox = newDelegate

        let work = DispatchWorkItem {
            lock.lock()
            defer { lock.unlock() }
            newBrowser.stop()
            if browser === newBrowser {
                browser = nil
                delegateBox = nil
            }
            keepAliveWorkItem = nil
        }
        keepAliveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }
}

/// Retains the browser delegate for the duration of the search.
private final class BrowserDelegate: NSObject, NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        // Permission denied or browse failed — no action needed here.
        // The connection attempt will surface a user-facing error if needed.
        _ = errorDict
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        _ = service
        _ = moreComing
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {}
}
