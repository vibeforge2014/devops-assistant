import SwiftUI

/// The first-screen command center: a read-only overview of every app (with
/// version + path status) and site (with clone status), plus the most recent
/// releases. Shown both as the landing view (nothing selected) and as its own
/// sidebar entry. Reads versions synchronously from disk on appear — cheap,
/// since it's a one-line regex per app for a 7-app matrix.
struct DashboardView: View {
    @EnvironmentObject var catalog: ProjectCatalog
    @EnvironmentObject var historyStore: HistoryStore
    @EnvironmentObject private var registry: ConsoleRegistry
    @EnvironmentObject private var navigation: NavigationModel

    /// app.id → current version, loaded once on appear.
    @State private var versions: [String: VersionPair] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                intro
                statsRow
                appsSection
                sitesSection
                recentReleasesSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("仪表盘")
        .onAppear { loadVersions() }
        // New/edited projects change what loadVersions should read; a finished
        // release (record appended) changed the on-disk build numbers.
        .onReceive(catalog.$data) { _ in loadVersions() }
        .onReceive(historyStore.$records) { _ in loadVersions() }
    }

    // MARK: - Intro

    private var intro: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("VibeForge 矩阵总览").font(.headline)
                Text("所有应用与站点的一屏概览:版本、路径/克隆状态、最近发布。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatBadge(label: "应用", count: catalog.apps.count,
                      available: catalog.availableApps.count, icon: "iphone")
            StatBadge(label: "站点", count: catalog.sites.count,
                      available: catalog.availableSites.count, icon: "globe")
            StatBadge(label: "发布记录", count: historyStore.records.count,
                      available: nil, icon: "clock.arrow.circlepath")
        }
    }

    // MARK: - Apps

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("应用", systemImage: "square.grid.2x2")
            VStack(spacing: 6) {
                ForEach(catalog.apps) { app in
                    appRow(app)
                }
            }
        }
    }

    private func appRow(_ app: AppProject) -> some View {
        let version = versions[app.id]
        return Button {
            navigation.selection = .app(app.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: platformIcon(app.platform))
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(app.name).font(.headline)
                        Text(app.platform.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                        if registry.isAppRunning(app.id) {
                            ProgressView()
                                .controlSize(.mini)
                                .help("正在执行任务")
                        }
                        if !app.existsOnDisk {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("项目路径不存在")
                        }
                    }
                    Text(app.bundleId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(version?.marketing ?? "—")
                        .font(.callout.monospacedDigit().bold())
                    Text("build \(version?.build ?? "—")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 90, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(captionChevronFont)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("打开 \(app.name)")
    }

    private var captionChevronFont: Font { .caption.weight(.semibold) }

    // MARK: - Sites

    private var sitesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("站点", systemImage: "globe")
            VStack(spacing: 6) {
                ForEach(catalog.sites) { site in
                    siteRow(site)
                }
            }
        }
    }

    private func siteRow(_ site: SiteProject) -> some View {
        Button {
            navigation.selection = .site(site.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(site.name).font(.headline)
                        if registry.isSiteRunning(site.id) {
                            ProgressView()
                                .controlSize(.mini)
                                .help("正在执行任务")
                        }
                        if !site.existsOnDisk {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("本地克隆不存在")
                        }
                    }
                    Text(site.repositoryURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(deployLabel(site.deploy))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(captionChevronFont)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("打开 \(site.name)")
    }

    // MARK: - Recent releases

    private var recentReleasesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("最近发布", systemImage: "clock.arrow.circlepath")
                Spacer()
                if !historyStore.records.isEmpty {
                    Button {
                        navigation.selection = .history
                    } label: {
                        Label("查看全部", systemImage: "arrow.right.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            let recent = Array(historyStore.records.prefix(5))
            if recent.isEmpty {
                ContentUnavailableView(
                    "还没有发布记录",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("完成一次发布后,这里会显示最近 5 次记录。")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 6) {
                    ForEach(recent) { record in
                        recentRow(record)
                    }
                }
            }
        }
    }

    private func recentRow(_ record: ReleaseRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: record.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(record.success ? .green : .red)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(record.appName).font(.headline)
                    Text(record.versionLabel)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("\(targetLabel(record.target)) · \(record.timestamp.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let step = record.failureStep {
                Text("失败于 \(step)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage).font(.headline)
            .padding(.bottom, 2)
    }

    private func platformIcon(_ p: AppPlatform) -> String {
        switch p {
        case .ios: "iphone"
        case .macos: "macbook"
        case .tvos: "appletv"
        case .web: "globe"
        }
    }

    private func deployLabel(_ method: DeployMethod) -> String {
        switch method {
        case .gitPushMain: "push 部署"
        case .ghPages: "gh-pages"
        case .cloudflarePages: "Cloudflare"
        }
    }

    private func targetLabel(_ raw: String) -> String {
        ReleaseTarget(rawValue: raw)?.title ?? raw
    }

    private func loadVersions() {
        versions.removeAll()
        for app in catalog.apps {
            versions[app.id] = VersionManager.read(app)
        }
    }
}

/// A small "X / Y available" stat card used in the dashboard summary row.
private struct StatBadge: View {
    let label: String
    let count: Int
    /// When not nil, rendered as "count / available" (e.g. apps present on disk).
    let available: Int?
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(display)
                .font(.title3.monospacedDigit().bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    private var display: String {
        if let available { "\(available)/\(count)" } else { "\(count)" }
    }
}
