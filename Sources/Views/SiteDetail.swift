import AppKit
import SwiftUI

/// 单个 GitHub Pages 站点的详情视图。展示仓库信息、本地克隆状态与 git
/// 工作区快照(分支/未提交/领先落后/最近提交);「拉取最新」「提交并推送」
/// 两个快捷操作面向日常小改动,「一键发布」则打开带步骤流水线的发布向导
/// (拉取 → 提交 → 部署,含历史记录与运行日志)。过程输出实时显示在底部
/// 控制台。
struct SiteDetail: View {
    /// The runners are owned by `ConsoleRegistry` (injected), not as
    /// `@StateObject`s here, so switching sites in the sidebar no longer
    /// destroys them — console logs survive and a running deploy keeps
    /// streaming instead of being orphaned.
    @EnvironmentObject private var registry: ConsoleRegistry
    let site: SiteProject
    /// The publish coordinator is owned by `ReleaseCenter` and observed here
    /// so the page reacts to a backgrounded publish (banner, console switch).
    @ObservedObject private var publishCoordinator: SitePublishCoordinator
    private let center: ReleaseCenter

    @State private var commitMessage = ""
    @State private var showCommitDialog = false
    @State private var showPublish = false
    @State private var working = false
    @State private var status: SiteStatus?
    @State private var statusLoading = false

    private var runner: ShellRunner { registry.runnerForSite(site.id) }
    private var deployer: PagesDeployer { PagesDeployer(runner: runner) }
    private var publishRunning: Bool { publishCoordinator.isRunning }

    init(site: SiteProject, center: ReleaseCenter) {
        self.site = site
        self.center = center
        _publishCoordinator = ObservedObject(wrappedValue: center.siteCoordinator(for: site))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if !site.existsOnDisk {
                        missingCloneBanner
                    }

                    if publishRunning {
                        publishRunningBanner
                    }

                    infoCard

                    if site.existsOnDisk {
                        statusCard
                            .disabled(working || runner.isRunning || publishRunning)
                    }

                    actionRow
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            // While a publish runs in the background, the embedded console
            // mirrors the publish runner — otherwise the banner says "发布进行中"
            // above a console showing stale output from the last manual action.
            if publishRunning {
                HStack {
                    Label("发布日志", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            ConsolePanel(runner: publishRunning ? publishCoordinator.runner : runner)
                .frame(height: 200)
        }
        .navigationTitle(site.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // While a publish runs, the toolbar becomes the way back into
                // its (possibly dismissed) wizard sheet.
                if publishRunning {
                    Button {
                        showPublish = true
                    } label: {
                        Label("查看发布进度", systemImage: "arrow.triangle.2.circlepath")
                    }
                } else {
                    Button("一键发布") { showPublish = true }
                        .disabled(working || runner.isRunning || !site.existsOnDisk)
                }
            }
        }
        .sheet(isPresented: $showCommitDialog) {
            commitDialog
        }
        .sheet(isPresented: $showPublish) {
            SitePublishView(site: site, center: center)
        }
        .onAppear { refreshStatus() }
        .onChange(of: publishRunning) { _, running in
            // A backgrounded publish that just finished changed the repo —
            // refresh the status card instead of showing stale counts.
            if !running { refreshStatus() }
        }
        // A batch deploy from the pages manager works the same clone with a
        // different runner — block both directions of the race. Manual
        // actions and a backgrounded publish likewise share the clone.
        .disabled(working || runner.isRunning || publishRunning || registry.isPagesRunning())
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "globe")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(site.name).font(.largeTitle.bold())
                Text(site.repositoryURL)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Label(deployDescription, systemImage: "arrow.up.circle")
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(.secondary)
        }
    }

    private var deployDescription: String {
        site.deploy.displayName
    }

    // MARK: - Info card

    private var infoCard: some View {
        let liveURL = site.liveURL?.absoluteString ?? "—"
        let rows: [(String, String)] = [
            ("仓库", site.repositoryURL),
            ("本地路径", site.resolvedPath),
            ("部署方式", deployDescription),
            ("线上地址", liveURL),
            ("状态", site.existsOnDisk ? "已克隆" : "未克隆")
        ]
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0)
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Text(row.1)
                        .font(.callout)
                        .textSelection(.enabled)
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    // MARK: - Status card

    /// Live git snapshot: branch, pending work, ahead/behind, last commit.
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("仓库状态", systemImage: "info.circle")
                    .font(.subheadline.bold())
                Spacer()
                if statusLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        refreshStatus()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let status {
                statusRows(status)
            } else {
                Text("读取仓库状态…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    @ViewBuilder
    private func statusRows(_ status: SiteStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusBadge(text: status.branch ?? "—", icon: "arrow.triangle.branch")
                statusBadge(text: status.changedFiles > 0 ? "\(status.changedFiles) 个未提交变更" : "工作区干净",
                            icon: status.changedFiles > 0 ? "tray.full" : "tray",
                            highlighted: status.changedFiles > 0)
                if status.hasUpstream && (status.ahead > 0 || status.behind > 0) {
                    statusBadge(text: "↑\(status.ahead) ↓\(status.behind)",
                                icon: "arrow.up.arrow.down",
                                highlighted: status.behind > 0)
                }
                Spacer()
            }
            if let commit = status.lastCommit {
                Text("\(commit.shortHash) \(commit.subject) · \(commit.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func statusBadge(text: String, icon: String, highlighted: Bool = false) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(highlighted ? AnyShapeStyle(.orange.opacity(0.12)) : AnyShapeStyle(.quaternary),
                        in: Capsule())
            .foregroundStyle(highlighted ? .orange : .secondary)
    }

    // MARK: - Publish banner

    private var publishRunningBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("发布进行中").font(.headline)
                Text("流程在后台运行,完成后会收到系统通知")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("查看进度") { showPublish = true }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await pull() }
            } label: {
                Label("拉取最新", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!site.existsOnDisk)

            Button {
                commitMessage = ""
                showCommitDialog = true
            } label: {
                Label("提交并推送", systemImage: "paperplane.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!site.existsOnDisk)

            Spacer()

            if let url = site.liveURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("打开站点", systemImage: "safari")
                }
                .buttonStyle(.bordered)
                .help(url.absoluteString)
            }
        }
    }

    private var missingCloneBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text("本地克隆不存在").font(.headline)
                Text(site.resolvedPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                Task { await cloneRepo() }
            } label: {
                Label("克隆仓库", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Commit dialog

    private var commitDialog: some View {
        VStack(spacing: 16) {
            Text("提交并推送").font(.headline)
            TextField("commit message", text: $commitMessage)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirmCommit() }
            HStack {
                Button("取消", role: .cancel) {
                    showCommitDialog = false
                }
                Spacer()
                Button("推送") {
                    confirmCommit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Commands

    private func confirmCommit() {
        let message = commitMessage.trimmingCharacters(in: .whitespaces)
        guard !message.isEmpty else { return }
        showCommitDialog = false
        Task { await commitAndPush(message: message) }
    }

    private func pull() async {
        working = true; defer { working = false }
        runner.clear()
        await deployer.pull(site)
        refreshStatus()
    }

    private func commitAndPush(message: String) async {
        working = true; defer { working = false }
        runner.clear()
        await deployer.deploy(site, message: message)
        refreshStatus()
    }

    /// Clone the site repo into its configured local path. The parent directory
    /// is created first (so deeply nested paths resolve), then the empty target
    /// dir is created so `git clone <url> .` has somewhere to clone into.
    private func cloneRepo() async {
        working = true; defer { working = false }
        let target = URL(fileURLWithPath: site.resolvedPath)
        let parent = target.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        runner.log("▶ git clone — \(site.name)")
        _ = await runner.run(executable: "/usr/bin/git",
                             args: ["clone", site.repositoryURL, site.resolvedPath],
                             timeout: 1800)
        refreshStatus()
    }

    private func refreshStatus() {
        guard site.existsOnDisk else {
            status = nil
            return
        }
        statusLoading = true
        let path = site.resolvedPath
        Task {
            status = await SiteStatusService.status(at: path)
            statusLoading = false
        }
    }
}
