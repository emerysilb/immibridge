import SwiftUI

@main
struct PhotoBackupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = PhotoBackupViewModel()
    @StateObject private var scheduler = BackupScheduler()

    var body: some Scene {
        WindowGroup(id: "main") {
            Group {
                if model.shouldShowSetupWizard {
                    SetupWizardView()
                        .environmentObject(model)
                        .environmentObject(scheduler)
                } else {
                    ContentView()
                        .environmentObject(model)
                        .environmentObject(scheduler)
                }
            }
            .onAppear {
                appDelegate.mainWindowVisible = true
            }
            .onDisappear {
                appDelegate.mainWindowVisible = false
            }
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(scheduler)
        } label: {
            Image(systemName: menuBarIcon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(menuBarIconColor)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: String {
        if model.isRunning {
            return model.isPaused ? "pause.circle.fill" : "arrow.clockwise.circle.fill"
        }
        if model.errorCount > 0 && !model.isRunning {
            return "exclamationmark.circle.fill"
        }
        return scheduler.isEnabled ? "clock.circle" : "arrow.clockwise.circle"
    }

    private var menuBarIconColor: Color {
        if model.isRunning && !model.isPaused {
            return .blue
        }
        if model.isPaused {
            return .orange
        }
        if model.errorCount > 0 && !model.isRunning {
            return .red
        }
        return .primary
    }
}
