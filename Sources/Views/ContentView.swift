import SwiftUI

/// The main window: NavigationSplitView with a sidebar listing apps/sites
/// and a detail pane showing the selected item's actions.
struct ContentView: View {
    @EnvironmentObject var catalog: ProjectCatalog
    @State private var selection: SidebarItem?

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
        } detail: {
            if let selection {
                detailView(for: selection)
            } else {
                EmptyDetail()
            }
        }
    }

    @ViewBuilder
    private func detailView(for item: SidebarItem) -> some View {
        switch item {
        case .app(let id):
            if let app = catalog.app(id: id) {
                ProjectDetail(app: app)
            } else {
                EmptyDetail()
            }
        case .site(let id):
            if let site = catalog.site(id: id) {
                SiteDetail(site: site)
            } else {
                EmptyDetail()
            }
        case .versionEditor:
            VersionEditorView()
        case .pages:
            PagesManagerView()
        case .settings:
            SettingsView()
        }
    }
}

/// A sidebar entry: either a specific app/site, or a tool view.
enum SidebarItem: Hashable {
    case app(String)
    case site(String)
    case versionEditor
    case pages
    case settings
}

/// Empty placeholder for when nothing is selected.
struct EmptyDetail: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("从侧栏选择一个项目或工具")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("VibeForge DevOps Assistant")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
