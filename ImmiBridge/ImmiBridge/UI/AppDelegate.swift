import AppKit
import Sparkle
import SwiftUI
import UserNotifications

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PhotoBackupViewModel()
    let scheduler = BackupScheduler()
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()

    /// Strongly retained so "Open Main Window" still works after the window is closed.
    /// SwiftUI releases WindowGroup windows on close by default, which is why reopening
    /// used to fall through to building a brand new window.
    private var mainWindow: NSWindow?

    /// Menu-bar agent mode: keep running with no Dock icon.
    ///
    /// Defaults to **false**. Defaulting to true would make the Dock icon vanish for
    /// everyone on upgrade, which is a surprising thing for an update to do to you.
    static var hideDockIcon: Bool {
        get { UserDefaults.standard.bool(forKey: "hideDockIcon") }
        set {
            UserDefaults.standard.set(newValue, forKey: "hideDockIcon")
            NotificationCenter.default.post(name: .hideDockIconPreferenceChanged, object: nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions
        NotificationManager.shared.requestAuthorization()

        // Register for power/wake notifications
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // Register for window close notifications to hide from dock when all windows close
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        // Track which window is the real main window so we can re-show that instance
        // rather than constructing a replacement.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hideDockPreferenceChanged),
            name: .hideDockIconPreferenceChanged,
            object: nil
        )

        setupStatusItem()
        applyActivationPolicy(forMainWindowVisible: hasVisibleMainWindow())
    }

    /// Dock icon click when the Dock icon is showing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow() }
        return true
    }

    // MARK: - Window identification

    /// A window we would consider "the app's main window".
    ///
    /// The `NSStatusBarWindow` backing the menu bar item is visible and is **not** an
    /// `NSPanel`, so a plain `!($0 is NSPanel)` test matches it. That was the bug: with the
    /// real window closed, "Open Main Window" would find the status bar window, order it
    /// front, and return — so nothing appeared to happen.
    private func isEligibleMainWindow(_ window: NSWindow) -> Bool {
        if window is NSPanel { return false }
        if String(describing: type(of: window)).contains("StatusBar") { return false }
        // SwiftUI's menu bar extra and other helper windows carry no title bar.
        if !window.styleMask.contains(.titled) { return false }
        return true
    }

    private func hasVisibleMainWindow() -> Bool {
        NSApp.windows.contains { isEligibleMainWindow($0) && $0.isVisible && !$0.isMiniaturized }
    }

    private func applyActivationPolicy(forMainWindowVisible visible: Bool) {
        // Only drop to accessory when the user actually asked for agent mode.
        let policy: NSApplication.ActivationPolicy = (visible || !Self.hideDockIcon) ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    @objc private func hideDockPreferenceChanged() {
        applyActivationPolicy(forMainWindowVisible: hasVisibleMainWindow())
        rebuildStatusMenu()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isEligibleMainWindow(window) else { return }
        if mainWindow !== window {
            mainWindow = window
            // Keep the instance alive across close so we can re-show it.
            window.isReleasedWhenClosed = false
        }
        applyActivationPolicy(forMainWindowVisible: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running so scheduled backups can continue; the menu bar item can reopen the window.
        return false
    }

    @objc private func handleWake() {
        // Notify scheduler to check for missed backups
        NotificationCenter.default.post(name: .systemDidWake, object: nil)
    }

    @objc private func windowDidClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isEligibleMainWindow(window) else { return }
        Task { @MainActor in
            // Let the window finish closing before asking what is still on screen.
            try? await Task.sleep(nanoseconds: 100_000_000)
            applyActivationPolicy(forMainWindowVisible: hasVisibleMainWindow())
        }
    }

    private func setupStatusItem() {
        statusMenu.delegate = self

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = statusImage()
        item.menu = statusMenu
        statusItem = item

        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        statusMenu.removeAllItems()

        let titleItem = NSMenuItem(title: statusTitle(), action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        statusMenu.addItem(titleItem)
        statusMenu.addItem(NSMenuItem.separator())

        statusMenu.addItem(NSMenuItem(
            title: "Open Main Window",
            action: #selector(openMainWindow),
            keyEquivalent: "o"
        ))
        statusMenu.addItem(NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates),
            keyEquivalent: "u"
        ))

        let dockItem = NSMenuItem(
            title: "Hide Dock Icon",
            action: #selector(toggleHideDockIcon),
            keyEquivalent: ""
        )
        dockItem.state = Self.hideDockIcon ? .on : .off
        statusMenu.addItem(dockItem)

        if model.isRunning {
            if model.isPaused {
                statusMenu.addItem(NSMenuItem(
                    title: "Resume Backup",
                    action: #selector(resumeBackup),
                    keyEquivalent: "r"
                ))
            } else {
                statusMenu.addItem(NSMenuItem(
                    title: "Pause Backup",
                    action: #selector(pauseBackup),
                    keyEquivalent: "p"
                ))
            }
            statusMenu.addItem(NSMenuItem(
                title: "Stop Backup",
                action: #selector(stopBackup),
                keyEquivalent: "."
            ))
        } else {
            statusMenu.addItem(NSMenuItem(
                title: "Run Backup Now",
                action: #selector(runBackupNow),
                keyEquivalent: "r"
            ))
        }

        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.button?.image = statusImage()
    }

    private func statusTitle() -> String {
        if model.isRunning {
            return model.isPaused ? "ImmiBridge — Paused" : "ImmiBridge — Backing Up…"
        }
        if model.errorCount > 0 {
            return "ImmiBridge — Completed with Errors"
        }
        return scheduler.isEnabled ? "ImmiBridge — Scheduled" : "ImmiBridge — Ready"
    }

    private func statusImage() -> NSImage? {
        let symbolName: String = {
            if model.isRunning {
                return model.isPaused ? "pause.circle.fill" : "arrow.clockwise.circle.fill"
            }
            if model.errorCount > 0 {
                return "exclamationmark.circle.fill"
            }
            return scheduler.isEnabled ? "clock.circle" : "arrow.clockwise.circle"
        }()

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ImmiBridge")
        image?.isTemplate = true
        return image
    }

    @objc func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Prefer the window we retained; fall back to any eligible one. Both filters skip
        // the status bar window, which is neither a panel nor titled.
        if let existing = mainWindow
            ?? NSApp.windows.first(where: { isEligibleMainWindow($0) && $0.isVisible })
            ?? NSApp.windows.first(where: { isEligibleMainWindow($0) })
        {
            existing.makeKeyAndOrderFront(nil)
            mainWindow = existing
            existing.isReleasedWhenClosed = false
            return
        }

        // If the user closed the last SwiftUI window, create a new one.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ImmiBridge"
        window.center()
        window.contentViewController = NSHostingController(
            rootView: MainRootView()
                .environmentObject(model)
                .environmentObject(scheduler)
        )
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
    }

    @objc private func toggleHideDockIcon() {
        Self.hideDockIcon.toggle()
    }

    @objc private func runBackupNow() {
        model.start()
        rebuildStatusMenu()
    }

    @objc private func pauseBackup() {
        model.pause()
        rebuildStatusMenu()
    }

    @objc private func resumeBackup() {
        model.resume()
        rebuildStatusMenu()
    }

    @objc private func stopBackup() {
        model.cancel()
        rebuildStatusMenu()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }
}

extension Notification.Name {
    static let systemDidWake = Notification.Name("systemDidWake")
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuildStatusMenu()
    }
}
