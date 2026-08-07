import SwiftUI

@main
struct DevOpsAssistantApp: App {
    @StateObject private var catalog = ProjectCatalog()
    @State private var showOnboarding = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(catalog)
                .frame(minWidth: 980, minHeight: 620)
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView()
                }
                .onAppear {
                    // First run: if essential credentials are missing, walk the
                    // user through onboarding (which auto-imports what it can).
                    if !OnboardingService.isFullyConfigured {
                        showOnboarding = true
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {} // no new-window
            CommandMenu("运维") {
                Button("重新配置凭据…") { showOnboarding = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
