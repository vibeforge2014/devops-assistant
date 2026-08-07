import SwiftUI

@main
struct DevOpsAssistantApp: App {
    @StateObject private var catalog = ProjectCatalog()
    @StateObject private var runner = ShellRunner()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(catalog)
                .environmentObject(runner)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {} // no new-window
            CommandMenu("运维") {
                Button("清空控制台") { runner.clear() }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
