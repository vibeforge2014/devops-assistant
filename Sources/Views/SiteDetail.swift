import SwiftUI

/// 单个 GitHub Pages 站点的详情视图。展示仓库信息与本地克隆状态,提供
/// 「拉取最新」「提交并推送」两个操作,过程输出实时显示在底部控制台。
struct SiteDetail: View {
    /// The runner is owned by `ConsoleRegistry` (injected), not as a
    /// `@StateObject` here, so switching sites in the sidebar no longer
    /// destroys the runner — console logs survive and a running deploy keeps
    /// streaming instead of being orphaned.
    @EnvironmentObject private var registry: ConsoleRegistry
    let site: SiteProject

    @State private var commitMessage = ""
    @State private var showCommitDialog = false
    @State private var working = false

    private var runner: ShellRunner { registry.runnerForSite(site.id) }
    private var deployer: PagesDeployer { PagesDeployer(runner: runner) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if !site.existsOnDisk {
                        missingCloneBanner
                    }

                    infoCard

                    actionRow
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            ConsolePanel(runner: runner)
                .frame(height: 200)
        }
        .navigationTitle(site.name)
        .sheet(isPresented: $showCommitDialog) {
            commitDialog
        }
        .disabled(working || runner.isRunning)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "globe")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(site.name).font(.largeTitle.bold())
                Text(site.repo)
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
        switch site.deploy {
        case .gitPushMain: "push main 自动部署"
        case .ghPages: "gh-pages npm 部署"
        }
    }

    // MARK: - Info card

    private var infoCard: some View {
        let rows: [(String, String)] = [
            ("仓库", site.repo),
            ("本地路径", site.resolvedPath),
            ("部署方式", deployDescription),
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
    }

    private func commitAndPush(message: String) async {
        working = true; defer { working = false }
        runner.clear()
        await deployer.deploy(site, message: message)
    }

    /// Clone the site repo into its configured local path. The parent directory
    /// is created first (so deeply nested paths resolve), then the empty target
    /// dir is created so `git clone <url> .` has somewhere to clone into.
    private func cloneRepo() async {
        working = true; defer { working = false }
        let target = URL(fileURLWithPath: site.resolvedPath)
        let parent = target.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        runner.log("▶ git clone — \(site.name)")
        _ = await runner.run("git clone git@github.com:\(site.repo).git .", cwd: site.resolvedPath)
    }
}
