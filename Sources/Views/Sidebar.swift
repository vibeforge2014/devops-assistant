import SwiftUI

/// The navigation sidebar. Two sections — Apps and Sites — plus a Tools section
/// for cross-project utilities (version editor, pages manager, settings).
struct Sidebar: View {
    @EnvironmentObject var catalog: ProjectCatalog
    @EnvironmentObject private var registry: ConsoleRegistry
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("应用") {
                ForEach(catalog.apps) { app in
                    Label {
                        HStack {
                            Text(app.name)
                            if registry.isAppRunning(app.id) {
                                // Live "this app is executing" indicator — a
                                // build/deploy keeps running in the background
                                // after switching away, so surface it here.
                                ProgressView()
                                    .controlSize(.small)
                                    .help("正在执行")
                            }
                            if !app.existsOnDisk {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("项目路径不存在")
                            }
                        }
                    } icon: {
                        icon(for: app.platform)
                    }
                    .tag(SidebarItem.app(app.id))
                }
            }

            Section("站点") {
                ForEach(catalog.sites) { site in
                    Label {
                        HStack {
                            Text(site.name)
                            if registry.isSiteRunning(site.id) {
                                ProgressView()
                                    .controlSize(.small)
                                    .help("正在执行")
                            }
                            if !site.existsOnDisk {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("本地克隆不存在")
                            }
                        }
                    } icon: {
                        Image(systemName: "globe")
                    }
                    .tag(SidebarItem.site(site.id))
                }
            }

            Section("工具") {
                Label("仪表盘", systemImage: "chart.bar.xaxis")
                    .tag(SidebarItem.dashboard)
                Label("发布历史", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.history)
                Label("版本号管理", systemImage: "number.circle")
                    .tag(SidebarItem.versionEditor)
                Label("发布页管理", systemImage: "globe.badge.chevron.backward")
                    .tag(SidebarItem.pages)
                Label("凭据设置", systemImage: "key.fill")
                    .tag(SidebarItem.settings)
            }
        }
        .navigationTitle("VibeForge")
        .listStyle(.sidebar)
        .frame(minWidth: 220)
    }

    @ViewBuilder
    private func icon(for platform: AppPlatform) -> some View {
        switch platform {
        case .ios: Image(systemName: "iphone")
        case .macos: Image(systemName: "macbook")
        case .tvos: Image(systemName: "appletv")
        case .web: Image(systemName: "globe")
        }
    }
}
