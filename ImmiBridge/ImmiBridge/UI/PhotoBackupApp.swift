import SwiftUI

@main
struct PhotoBackupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainRootView()
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.scheduler)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    appDelegate.checkForUpdates()
                }
            }
        }
    }
}

#if canImport(XCTest)
struct MainRootView: View {
    var body: some View { EmptyView() }
}
#else
struct MainRootView: View {
    @EnvironmentObject private var model: PhotoBackupViewModel
    @EnvironmentObject private var scheduler: BackupScheduler

    var body: some View {
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
    }
}
#endif
