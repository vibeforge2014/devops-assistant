import SwiftUI

@main
struct DevOpsAssistantApp: App {
    @StateObject private var catalog = ProjectCatalog()
    @StateObject private var runner = ShellRunner()
    @State private var showOnboarding = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(catalog)
                .environmentObject(runner)
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
                Button("清空控制台") { runner.clear() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("重新配置凭据…") { showOnboarding = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
