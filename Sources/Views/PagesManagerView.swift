import SwiftUI

/// 批量管理发布页站点视图。可多选站点后统一「提交并推送」,触发各站点的
/// GitHub Pages 自动部署;过程输出实时显示在底部控制台。
struct PagesManagerView: View {
    /// The runner is owned by `ConsoleRegistry` (injected), not as a
    /// `@StateObject` here, so it survives view rebuilds.
    @EnvironmentObject private var registry: ConsoleRegistry
    @EnvironmentObject var catalog: ProjectCatalog

    @State private var selected: Set<String> = []
    @State private var working = false
    @State private var commitMessage = "更新发布页"
    @State private var showCommitDialog = false

    private var runner: ShellRunner { registry.runnerForPages() }
    private var deployer: PagesDeployer { PagesDeployer(runner: runner) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    notice
                    toolbar
                    siteList
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            ConsolePanel(runner: runner)
                .frame(height: 200)
        }
        .navigationTitle("发布页管理")
        .sheet(isPresented: $showCommitDialog) {
            commitDialog
        }
        .disabled(working || runner.isRunning)
    }

    // MARK: - Notice

    private var notice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "globe.badge.chevron.backward")
                .foregroundStyle(.tint)
            Text("选中站点后批量提交并推送,触发 GitHub Pages 自动部署。")
                .font(.callout)
            Spacer()
        }
        .padding()
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                toggleAll()
            } label: {
                Label(allSelected ? "取消全选" : "全选",
                      systemImage: allSelected ? "circle" : "checkmark.circle.fill")
            }
            .buttonStyle(.bordered)
            .disabled(catalog.availableSites.isEmpty)

            Button {
                showCommitDialog = true
            } label: {
                Label("统一提交并推送", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty)

            Spacer()
        }
    }

    // MARK: - Site list

    private var siteList: some View {
        Group {
            if catalog.availableSites.isEmpty {
                ContentUnavailableView(
                    "没有可用的站点",
                    systemImage: "globe",
                    description: Text("未检测到任何本地站点克隆,请先克隆仓库。")
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            } else {
                VStack(spacing: 6) {
                    ForEach(catalog.availableSites) { site in
                        siteRow(site)
                    }
                }
            }
        }
    }

    private func siteRow(_ site: SiteProject) -> some View {
        let isSelected = selected.contains(site.id)
        return Button {
            toggle(site.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(site.name).font(.headline)
                    Text(site.repositoryURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text(deployDescription(site.deploy))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        }
        .buttonStyle(.plain)
    }

    private func deployDescription(_ method: DeployMethod) -> String {
        switch method {
        case .gitPushMain: "push main 自动部署"
        case .ghPages: "gh-pages npm 部署"
        }
    }

    // MARK: - Commit dialog

    private var commitDialog: some View {
        VStack(spacing: 16) {
            Text("统一提交并推送").font(.headline)
            Text("将向 \(selected.count) 个站点提交并推送。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("commit message", text: $commitMessage)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("取消", role: .cancel) { showCommitDialog = false }
                Spacer()
                Button("推送") { confirmCommit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Commands

    private var allSelected: Bool {
        !catalog.availableSites.isEmpty &&
        selected.count == catalog.availableSites.count
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func toggleAll() {
        if allSelected {
            selected.removeAll()
        } else {
            selected = Set(catalog.availableSites.map(\.id))
        }
    }

    private func confirmCommit() {
        let message = commitMessage.trimmingCharacters(in: .whitespaces)
        guard !message.isEmpty, !selected.isEmpty else { return }
        showCommitDialog = false
        Task { await deployAll(message: message) }
    }

    private func deployAll(message: String) async {
        working = true; defer { working = false }
        runner.clear()
        let targets = catalog.availableSites.filter { selected.contains($0.id) }
        for site in targets {
            let result = await deployer.deploy(site, message: message)
            if !result.succeeded {
                runner.log("✗ \(site.name) 部署失败,继续处理其余站点")
            }
        }
    }
}
