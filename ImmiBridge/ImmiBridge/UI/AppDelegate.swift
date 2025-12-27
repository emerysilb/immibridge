import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindowVisible = false {
        didSet {
            updateActivationPolicy()
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in menu bar when window is closed
        return false
    }

    private func updateActivationPolicy() {
        // Show in Dock when window is visible, hide when closed to menu bar
        NSApp.setActivationPolicy(mainWindowVisible ? .regular : .accessory)
    }

    @objc private func handleWake() {
        // Notify scheduler to check for missed backups
        NotificationCenter.default.post(name: .systemDidWake, object: nil)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

extension Notification.Name {
    static let systemDidWake = Notification.Name("systemDidWake")
}
