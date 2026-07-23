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
    /// Strongly retained main window so "Open Main Window" works after close in agent mode.
    private var mainWindow: NSWindow?

    /// Default true: menu-bar agent (no Dock icon). Toggle in UI / status menu.
    static var hideDockIcon: Bool {
        get {
            if UserDefaults.standard.object(forKey: "hideDockIcon") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "hideDockIcon")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "hideDockIcon")
            NotificationCenter.default.post(name: .hideDockIconPreferenceChanged, object: nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar mode: hide Dock so the app can keep running without a Dock presence.
        applyActivationPolicy(forMainWindowVisible: hasVisibleMainWindow())

        NotificationManager.shared.requestAuthorization()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Stay alive for scheduled backups + menu bar controls.
        return false
    }

    /// Dock click / reopen when Dock icon is shown.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMainWindow()
        }
        return true
    }

    @objc private func handleWake() {
        NotificationCenter.default.post(name: .systemDidWake, object: nil)
    }

    @objc private func hideDockPreferenceChanged() {
        applyActivationPolicy(forMainWindowVisible: hasVisibleMainWindow())
        rebuildStatusMenu()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isEligibleMainWindow(window) else { return }
        // Remember SwiftUI WindowGroup window so we can re-show it later.
        if mainWindow == nil {
            mainWindow = window
            window.isReleasedWhenClosed = false
        }
        applyActivationPolicy(forMainWindowVisible: true)
    }

    @objc private func windowDidClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isEligibleMainWindow(window) else { return }
        // Keep the instance if we own it (isReleasedWhenClosed = false); just hide policy.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            applyActivationPolicy(forMainWindowVisible: hasVisibleMainWindow())
        }
    }

    /// True main UI windows only — never the menu-bar status item window.
    private func isEligibleMainWindow(_ window: NSWindow) -> Bool {
        if window is NSPanel { return false }
        // NSStatusBarWindow is NOT an NSPanel; matching it was breaking "Open Main Window".
        let name = window.className
        if name.contains("StatusBar") || name.contains("NSStatusBar") { return false }
        if window.level == .statusBar { return false }
        guard window.styleMask.contains(.titled) else { return false }
        guard window.canBecomeKey else { return false }
        // Ignore tiny helper / hosting shells.
        if window.frame.width < 200 || window.frame.height < 200 { return false }
        return true
    }

    private func hasVisibleMainWindow() -> Bool {
        if let mainWindow, mainWindow.isVisible, !mainWindow.isMiniaturized {
            return true
        }
        return NSApp.windows.contains { window in
            isEligibleMainWindow(window) && window.isVisible && !window.isMiniaturized
        }
    }

    private func findMainWindow() -> NSWindow? {
        if let mainWindow {
            return mainWindow
        }
        let candidates = NSApp.windows.filter(isEligibleMainWindow)
        return candidates.first(where: { $0.isVisible }) ?? candidates.first
    }

    /// `.accessory` = menu bar only (no Dock). `.regular` = normal Dock app.
    private func applyActivationPolicy(forMainWindowVisible mainVisible: Bool) {
        if Self.hideDockIcon {
            // Stay accessory even with a window open — no Dock icon while agent mode is on.
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        } else {
            // Classic app: Dock icon while a main window is up; optional hide when fully closed.
            let policy: NSApplication.ActivationPolicy = mainVisible ? .regular : .accessory
            if NSApp.activationPolicy() != policy {
                NSApp.setActivationPolicy(policy)
            }
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

        let hideDockItem = NSMenuItem(
            title: "Hide Dock Icon",
            action: #selector(toggleHideDockIcon),
            keyEquivalent: ""
        )
        hideDockItem.state = Self.hideDockIcon ? .on : .off
        statusMenu.addItem(hideDockItem)

        statusMenu.addItem(NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates),
            keyEquivalent: "u"
        ))

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
        statusMenu.addItem(NSMenuItem(title: "Quit ImmiBridge", action: #selector(quitApp), keyEquivalent: "q"))

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

    @objc private func toggleHideDockIcon() {
        Self.hideDockIcon.toggle()
        // Preference change posts notification → applyActivationPolicy.
    }

    @objc func openMainWindow() {
        // Defer until the status-item menu finishes dismissing; otherwise ordering
        // a key window from inside the menu action often fails silently.
        DispatchQueue.main.async { [weak self] in
            self?.presentMainWindow()
        }
    }

    private func presentMainWindow() {
        // Show Dock only when user wants a classic app; agent mode stays accessory.
        if !Self.hideDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }

        NSApp.activate(ignoringOtherApps: true)

        if let existing = findMainWindow() {
            mainWindow = existing
            existing.isReleasedWhenClosed = false
            showWindow(existing)
            return
        }

        // No surviving SwiftUI window — create and retain one.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ImmiBridge"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        window.center()
        window.contentViewController = NSHostingController(
            rootView: MainRootView()
                .environmentObject(model)
                .environmentObject(scheduler)
        )
        mainWindow = window
        showWindow(window)
    }

    private func showWindow(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        // orderFrontRegardless works from accessory apps / after status-item menus.
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
    static let hideDockIconPreferenceChanged = Notification.Name("hideDockIconPreferenceChanged")
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuildStatusMenu()
    }
}
