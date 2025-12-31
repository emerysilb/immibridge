import SwiftUI

@available(macOS 12.0, *)
struct MenuBarView: View {
    @EnvironmentObject var model: PhotoBackupViewModel
    @EnvironmentObject var scheduler: BackupScheduler

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status header
            HStack(spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Progress bar (if running)
            if model.isRunning && model.progressTotal > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: model.progressValue, total: model.progressTotal)
                        .progressViewStyle(.linear)
                    HStack {
                        Text("\(Int(model.progressValue))/\(Int(model.progressTotal))")
                        Spacer()
                        if model.uploadedCount > 0 {
                            Text("\(model.uploadedCount) uploaded")
                                .foregroundStyle(.green)
                        }
                        if model.errorCount > 0 {
                            Text("\(model.errorCount) errors")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            Divider()

            // Quick actions
            VStack(spacing: 2) {
                if model.isRunning {
                    if model.isPaused {
                        MenuBarButton(title: "Resume Backup", icon: "play.fill") {
                            model.resume()
                        }
                    } else {
                        MenuBarButton(title: "Pause Backup", icon: "pause.fill") {
                            model.pause()
                        }
                    }
                    MenuBarButton(title: "Stop Backup", icon: "stop.fill", isDestructive: true) {
                        model.cancel()
                    }
                } else {
                    if model.hasResumableSession {
                        MenuBarButton(title: "Resume Previous Backup", icon: "play.fill") {
                            model.resume()
                        }
                        MenuBarButton(title: "Start Fresh Backup", icon: "arrow.clockwise") {
                            model.start()
                        }
                    } else {
                        MenuBarButton(title: "Run Backup Now", icon: "play.fill") {
                            model.start()
                        }
                    }
                    MenuBarButton(title: "Sync Metadata Only", icon: "arrow.triangle.2.circlepath") {
                        model.startMetadataSync()
                    }
                }
            }
            .padding(.vertical, 4)

            Divider()

            // Schedule info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: scheduler.isEnabled ? "clock.fill" : "clock")
                        .foregroundStyle(scheduler.isEnabled ? .blue : .secondary)
                    Text(scheduler.isEnabled ? "Scheduled" : "No Schedule")
                        .font(.subheadline)
                    Spacer()
                }
                if scheduler.isEnabled, let next = scheduler.nextBackupDate {
                    Text("Next: \(next, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // App actions
            VStack(spacing: 2) {
                MenuBarButton(title: "Open Main Window", icon: "macwindow") {
                    openMainWindow()
                }
                MenuBarButton(title: "Quit", icon: "power", isDestructive: true) {
                    NSApp.terminate(nil)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 260)
        .background(DesignSystem.Colors.windowBackground)
    }

    private var statusIcon: some View {
        Group {
            if model.isRunning && !model.isPaused {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.blue)
            } else if model.isPaused {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.orange)
            } else if model.errorCount > 0 {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .font(.title)
    }

    private var statusTitle: String {
        if model.isRunning {
            return model.isPaused ? "Paused" : "Backing Up..."
        }
        if model.errorCount > 0 {
            return "Completed with Errors"
        }
        return "Ready"
    }

    private var statusSubtitle: String {
        if model.isRunning && !model.isPaused {
            return model.currentAssetName.isEmpty ? "Preparing..." : model.currentAssetName
        }
        if model.isPaused {
            return "Tap Resume to continue"
        }
        if model.uploadedCount > 0 || model.skippedCount > 0 {
            return "\(model.uploadedCount) uploaded, \(model.skippedCount) skipped"
        }
        return scheduler.isEnabled ? "Scheduled backup active" : "No recent backup"
    }

    private func openMainWindow() {
        // Prefer reusing an existing non-panel window (menu bar extra uses a panel).
        if let existing = NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible })
            ?? NSApp.windows.first(where: { !($0 is NSPanel) })
        {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Create a new main window if none exist (only available on macOS 13+).
        // Post notification to request window opening (handled by WindowOpenerView)
        NotificationCenter.default.post(name: .openMainWindowRequested, object: nil)

        // SwiftUI creates the window asynchronously; bring it to front once it exists.
        Task { @MainActor in
            for _ in 0..<20 {
                if let w = NSApp.windows.first(where: { !($0 is NSPanel) }) {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    w.makeKeyAndOrderFront(nil)
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
        }
    }
}

// Notification name for requesting main window to open
extension Notification.Name {
    static let openMainWindowRequested = Notification.Name("openMainWindowRequested")
}

/// Helper view that handles window opening on macOS 13+
/// Add this to your app's main WindowGroup or Scene
@available(macOS 13.0, *)
struct WindowOpenerView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindowRequested)) { _ in
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
    }
}

struct MenuBarButton: View {
    let title: String
    let icon: String
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 20)
                Text(title)
                Spacer()
            }
            .foregroundStyle(isDestructive ? .red : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.clear)
        .onHover { isHovered in
            // Hover effect handled by system
        }
    }
}

@available(macOS 12.0, *)
#Preview {
    MenuBarView()
        .environmentObject(PhotoBackupViewModel())
        .environmentObject(BackupScheduler())
}
