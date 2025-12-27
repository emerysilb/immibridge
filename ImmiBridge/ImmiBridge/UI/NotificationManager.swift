import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    // MARK: - Notification Preferences

    @Published var notifyOnStart: Bool = false {
        didSet { saveSettings() }
    }

    @Published var notifyOnCompletion: Bool = true {
        didSet { saveSettings() }
    }

    @Published var notifyOnError: Bool = true {
        didSet { saveSettings() }
    }

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    // MARK: - Private Properties

    private let defaults = UserDefaults.standard
    private let notificationCenter = UNUserNotificationCenter.current()

    // MARK: - Initialization

    private init() {
        loadSettings()
        checkAuthorizationStatus()
    }

    // MARK: - Authorization

    func requestAuthorization() {
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            Task { @MainActor [weak self] in
                self?.checkAuthorizationStatus()
                if let error = error {
                    print("Notification authorization error: \(error.localizedDescription)")
                }
            }
        }
    }

    func checkAuthorizationStatus() {
        notificationCenter.getNotificationSettings { [weak self] settings in
            Task { @MainActor [weak self] in
                self?.authorizationStatus = settings.authorizationStatus
            }
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Send Notifications

    func sendBackupStarted() {
        guard notifyOnStart else { return }

        let content = UNMutableNotificationContent()
        content.title = "Backup Started"
        content.body = "Photo backup is now running."
        content.sound = .default
        content.categoryIdentifier = "BACKUP_STATUS"

        sendNotification(id: "backup-started", content: content)
    }

    func sendBackupCompleted(uploaded: Int, skipped: Int, errors: Int) {
        guard notifyOnCompletion else { return }

        let content = UNMutableNotificationContent()
        content.title = "Backup Complete"

        var parts: [String] = []
        if uploaded > 0 {
            parts.append("\(uploaded) uploaded")
        }
        if skipped > 0 {
            parts.append("\(skipped) skipped")
        }
        if errors > 0 {
            parts.append("\(errors) errors")
        }

        content.body = parts.isEmpty ? "Backup finished." : parts.joined(separator: ", ")
        content.sound = .default
        content.categoryIdentifier = "BACKUP_STATUS"

        sendNotification(id: "backup-completed", content: content)
    }

    func sendBackupError(message: String) {
        guard notifyOnError else { return }

        let content = UNMutableNotificationContent()
        content.title = "Backup Error"
        content.body = message
        content.sound = .defaultCritical
        content.categoryIdentifier = "BACKUP_ERROR"

        sendNotification(id: "backup-error-\(UUID().uuidString)", content: content)
    }

    func sendBackupSkipped(reason: String) {
        // Only send if user wants to know about errors/issues
        guard notifyOnError else { return }

        let content = UNMutableNotificationContent()
        content.title = "Scheduled Backup Skipped"
        content.body = reason
        content.sound = .default
        content.categoryIdentifier = "BACKUP_STATUS"

        sendNotification(id: "backup-skipped", content: content)
    }

    func sendTestNotification() {
        // Re-check authorization status before sending
        notificationCenter.getNotificationSettings { [weak self] settings in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.authorizationStatus = settings.authorizationStatus

                if settings.authorizationStatus == .authorized {
                    let content = UNMutableNotificationContent()
                    content.title = "Test Notification"
                    content.body = "Notifications are working correctly!"
                    content.sound = .default

                    let request = UNNotificationRequest(
                        identifier: "test-notification",
                        content: content,
                        trigger: nil
                    )

                    self.notificationCenter.add(request) { error in
                        if let error = error {
                            print("Failed to send test notification: \(error.localizedDescription)")
                        }
                    }
                } else if settings.authorizationStatus == .notDetermined {
                    // Request authorization first, then send
                    self.notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                        Task { @MainActor [weak self] in
                            self?.checkAuthorizationStatus()
                            if granted {
                                self?.sendTestNotification()
                            }
                        }
                    }
                } else {
                    print("Notifications not authorized: \(settings.authorizationStatus.rawValue)")
                }
            }
        }
    }

    // MARK: - Private Methods

    private func sendNotification(id: String, content: UNMutableNotificationContent) {
        guard authorizationStatus == .authorized else {
            print("Notifications not authorized, skipping: \(content.title)")
            return
        }

        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: nil // Deliver immediately
        )

        notificationCenter.add(request) { error in
            if let error = error {
                print("Failed to send notification: \(error.localizedDescription)")
            }
        }
    }

    private func loadSettings() {
        notifyOnStart = defaults.object(forKey: "notifyOnStart") as? Bool ?? false
        notifyOnCompletion = defaults.object(forKey: "notifyOnCompletion") as? Bool ?? true
        notifyOnError = defaults.object(forKey: "notifyOnError") as? Bool ?? true
    }

    private func saveSettings() {
        defaults.set(notifyOnStart, forKey: "notifyOnStart")
        defaults.set(notifyOnCompletion, forKey: "notifyOnCompletion")
        defaults.set(notifyOnError, forKey: "notifyOnError")
    }
}
