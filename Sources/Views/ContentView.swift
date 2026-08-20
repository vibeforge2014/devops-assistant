import SwiftUI

/// The main window: NavigationSplitView with a sidebar listing apps/sites
/// and a detail pane showing the selected item's actions.
struct ContentView: View {
    @EnvironmentObject var catalog: ProjectCatalog
    @EnvironmentObject private var releaseCenter: ReleaseCenter
    @EnvironmentObject private var navigation: NavigationModel

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $navigation.selection)
        } detail: {
            if let selection = navigation.selection {
                detailView(for: selection)
            } else {
                // Nothing selected: show the dashboard as the landing view.
                DashboardView()
            }
        }
        .onReceive(catalog.$data) { _ in
            switch navigation.selection {
            case .app(let id) where catalog.app(id: id) == nil,
                 .site(let id) where catalog.site(id: id) == nil:
                navigation.selection = .dashboard
            default:
                break
            }
        }
        // A clicked "release finished" notification navigates here.
        .onReceive(releaseCenter.$pendingFocusAppID) { id in
            guard let id, catalog.app(id: id) != nil else { return }
            navigation.selection = .app(id)
            releaseCenter.clearFocus()
        }
        .onReceive(releaseCenter.$pendingFocusSiteID) { id in
            guard let id, catalog.site(id: id) != nil else { return }
            navigation.selection = .site(id)
            releaseCenter.clearFocus()
        }
    }

    @ViewBuilder
    private func detailView(for item: SidebarItem) -> some View {
        switch item {
        case .app(let id):
            if let app = catalog.app(id: id) {
                ProjectDetail(app: app)
                    .id(id) // force fresh @State when switching apps
            } else {
                EmptyDetail()
            }
        case .site(let id):
            if let site = catalog.site(id: id) {
                SiteDetail(site: site, center: releaseCenter)
                    .id(id) // force fresh @State when switching sites
            } else {
                EmptyDetail()
            }
        case .dashboard:
            DashboardView()
        case .history:
            HistoryView()
        case .versionEditor:
            VersionEditorView()
        case .pages:
            PagesManagerView()
        case .projectManager:
            ProjectManagementView()
        case .settings:
            SettingsView()
        }
    }
}

/// A sidebar entry: either a specific app/site, or a tool view.
enum SidebarItem: Hashable {
    case app(String)
    case site(String)
    case dashboard
    case history
    case versionEditor
    case pages
    case projectManager
    case settings
}

/// App-level navigation state. Selection used to live as `@State` inside
/// `ContentView`, but more surfaces than the sidebar want to navigate now
/// (dashboard rows, the wizard's "查看发布历史") — lifting it here gives them
/// all a single switch to flip.
@MainActor
final class NavigationModel: ObservableObject {
    @Published var selection: SidebarItem? = .dashboard
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
