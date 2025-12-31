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

        setupStatusItem()
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
        // When a window closes, check if any visible non-panel windows remain
        // If not, hide the app from the dock (accessory mode = menu bar only)
        Task { @MainActor in
            // Small delay to let the window finish closing
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

            let hasVisibleWindows = NSApp.windows.contains { window in
                !window.isMiniaturized && window.isVisible && !(window is NSPanel)
            }

            if !hasVisibleWindows {
                NSApp.setActivationPolicy(.accessory)
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

    @objc private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let existing = NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible })
            ?? NSApp.windows.first(where: { !($0 is NSPanel) })
        {
            existing.makeKeyAndOrderFront(nil)
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
        window.makeKeyAndOrderFront(nil)
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
