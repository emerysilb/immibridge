import SwiftUI
import UserNotifications

struct NotificationSettingsView: View {
    @ObservedObject private var notifications = NotificationManager.shared

    var body: some View {
        BackupCardView(
            title: "Notifications",
            badge: notificationBadge,
            isDisabled: false
        ) {
            VStack(alignment: .leading, spacing: 14) {
                // Authorization status
                if notifications.authorizationStatus != .authorized {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Notifications are not enabled")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Spacer()
                        Button("Enable") {
                            if notifications.authorizationStatus == .notDetermined {
                                notifications.requestAuthorization()
                            } else {
                                notifications.openNotificationSettings()
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle(height: 32))
                        .frame(width: 80)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Divider()
                        .overlay(DesignSystem.Colors.separator)
                }

                // Notification toggles
                VStack(alignment: .leading, spacing: 12) {
                    NotificationToggle(
                        title: "Backup Started",
                        description: "Notify when a scheduled backup begins",
                        isOn: $notifications.notifyOnStart
                    )

                    NotificationToggle(
                        title: "Backup Completed",
                        description: "Notify when backup finishes with summary",
                        isOn: $notifications.notifyOnCompletion
                    )

                    NotificationToggle(
                        title: "Errors & Issues",
                        description: "Notify on errors or skipped backups",
                        isOn: $notifications.notifyOnError
                    )
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var notificationBadge: StatusBadge {
        switch notifications.authorizationStatus {
        case .authorized:
            return StatusBadge(kind: .success, text: "Enabled")
        case .denied:
            return StatusBadge(kind: .warning, text: "Disabled")
        case .notDetermined:
            return StatusBadge(kind: .muted, text: "Not Set")
        default:
            return StatusBadge(kind: .muted, text: "Unknown")
        }
    }
}

struct NotificationToggle: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(description)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Spacer(minLength: 0)
        }
    }
}

#Preview {
    NotificationSettingsView()
        .padding()
        .background(DesignSystem.Colors.windowBackground)
}
