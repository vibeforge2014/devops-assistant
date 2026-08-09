import SwiftUI

/// The detail view for a single app project. Shows version, signing info, and
/// the four release actions (build, sign/notarize, TestFlight, App Store),
/// each streaming output into an embedded console.
struct ProjectDetail: View {
    /// The runner is owned by `ConsoleRegistry` (injected), not as a
    /// `@StateObject` here. Lifting ownership out of the view means switching
    /// apps in the sidebar (which `ContentView` rebuilds via `.id(id)`) no
    /// longer destroys the runner — so live console logs survive the switch
    /// and a running build keeps streaming instead of being orphaned.
    @EnvironmentObject private var registry: ConsoleRegistry
    @EnvironmentObject var catalog: ProjectCatalog
    @EnvironmentObject private var historyStore: HistoryStore
    let app: AppProject

    private var runner: ShellRunner { registry.runnerForApp(app.id) }

    @State private var version: VersionPair?
    @State private var showVersionEditor = false
    @State private var showReleaseFlow = false
    @State private var working = false

    private var buildService: BuildService { BuildService(runner: runner) }
    private var fastlane: FastlaneRunner { FastlaneRunner(runner: runner) }
    private var notary: NotaryService { NotaryService(runner: runner) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    gitSection

                    actionGrid
                }
                .padding(24)
            }

            Divider()
            ConsolePanel(runner: runner)
                .frame(height: 220)
        }
        .navigationTitle(app.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("一键发布") { showReleaseFlow = true }
                    .disabled(working || runner.isRunning)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("编辑版本号") { showVersionEditor = true }
                    .disabled(working || runner.isRunning)
            }
        }
        .sheet(isPresented: $showVersionEditor) {
            VersionEditSheet(app: app, current: version) { newVersion in
                version = newVersion
            }
        }
        .sheet(isPresented: $showReleaseFlow) {
            ReleaseFlowView(app: app, catalog: catalog, historyStore: historyStore)
        }
        .onAppear { reloadVersion() }
        .disabled(working || runner.isRunning)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    platformIcon
                    Text(app.name).font(.largeTitle.bold())
                    Text(app.platform.displayName)
                        .font(.subheadline)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Text(app.bundleId)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(version?.marketing ?? "—")
                    .font(.title2.monospacedDigit().bold())
                Text("build \(version?.build ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var platformIcon: some View {
        Image(systemName: icon)
            .font(.title)
            .foregroundStyle(.tint)
    }

    private var icon: String {
        switch app.platform {
        case .ios: "iphone"
        case .macos: "macbook"
        case .tvos: "appletv"
        case .web: "globe"
        }
    }

    // MARK: - Actions

    private var actionGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ActionCard(title: "构建打包", icon: "hammer",
                       subtitle: app.release.engine == .fastlane ? "xcodegen + fastlane" : "xcodegen + xcodebuild") {
                Task { await build() }
            }
            ActionCard(title: app.release.notarize ? "签名 + 公证" : "签名",
                       icon: app.release.notarize ? "shield.lefthalf.filled" : "checkmark.seal",
                       subtitle: signingLabel) {
                Task { await sign() }
            }
            ActionCard(title: "上传 TestFlight", icon: "paperplane",
                       subtitle: localUploadLabel,
                       enabled: ReleaseTarget.available(for: app).contains(.testFlight)) {
                Task { await uploadBeta() }
            }
            ActionCard(title: "上传 App Store", icon: "shippingbox",
                       subtitle: app.release.engine == .fastlane ? "fastlane \(app.release.releaseLane ?? "release")" : "需先生成 lane",
                       enabled: app.release.engine == .fastlane) {
                Task { await uploadRelease() }
            }
            if app.platform == .ios {
                ActionCard(title: "打包 IPA", icon: "shippingbox.fill",
                           subtitle: "本地 xcodebuild -exportArchive") {
                    Task { await packageIPA() }
                }
            }
            if app.platform == .macos {
                ActionCard(title: "打包 DMG", icon: "externaldrive.fill",
                           subtitle: "本地签名 + hdiutil") {
                    Task { await packageDMG() }
                }
            }
        }
    }

    private var localUploadLabel: String {
        switch LocalTestFlightService(runner: runner).method(for: app) {
        case .script(let path, _): "本地脚本 · \((path as NSString).lastPathComponent)"
        case .fastlane(let lane): "本地 Fastlane · \(lane)"
        case .builtIn: "内置 IPA + altool"
        }
    }

    private var signingLabel: String {
        switch app.release.signing {
        case .match: "fastlane match"
        case .sigh: "cert + sigh"
        case .developerID: "Developer ID + notarytool"
        case .manual: "手动 ExportOptions"
        }
    }

    // MARK: - Git section

    /// Git operations for the project: clone when absent, pull/status when present.
    private var gitSection: some View {
        Group {
            if app.existsOnDisk {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("源码仓库").font(.headline)
                        Text(app.resolvedPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button { Task { await gitPull() } } label: {
                        Label("拉取最新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    Button { Task { await gitStatus() } } label: {
                        Label("状态", systemImage: "info.circle")
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
            } else {
                cloneBanner
            }
        }
    }

    /// Shown when the project path doesn't exist — offers to clone from the
    /// repository URL stored in the editable catalog.
    private var cloneBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("项目路径不存在").font(.headline)
                Text(app.resolvedPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { Task { await cloneRepo() } } label: {
                Label("克隆仓库", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Git commands

    private func gitPull() async {
        working = true; defer { working = false }
        await runner.run("git pull --ff-only", cwd: app.resolvedPath)
        reloadVersion()
    }

    private func gitStatus() async {
        working = true; defer { working = false }
        await runner.run("git status -sb && echo '---' && git log --oneline -5", cwd: app.resolvedPath)
    }

    private func cloneRepo() async {
        working = true; defer { working = false }
        let parent = (app.resolvedPath as NSString).deletingLastPathComponent
        let dirName = (app.resolvedPath as NSString).lastPathComponent
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: parent), withIntermediateDirectories: true)
        } catch {
            runner.log("✗ 无法创建父目录：\(error.localizedDescription)")
            return
        }
        runner.log("▶ git clone \(app.repositoryURL) → \(dirName)")
        _ = await runner.run(executable: "/usr/bin/git",
                             args: ["clone", app.repositoryURL, app.resolvedPath],
                             timeout: 1800)
        if app.existsOnDisk { reloadVersion() }
    }

    // MARK: - Actions (commands)

    private func build() async {
        working = true; defer { working = false }
        runner.clear()
        let generated = await buildService.generateXcodeProject(at: app.resolvedPath)
        guard generated.succeeded else { return }
        await buildService.archive(app: app, to: buildService.archivePath(for: app))
    }

    private func sign() async {
        working = true; defer { working = false }
        runner.clear()
        if app.release.notarize {
            let bundle = "\(buildService.archivePath(for: app))/Products/Applications/\(app.scheme).app"
            await notary.distribute(app: app, appBundle: bundle)
        } else if let lane = app.release.signingLane {
            await fastlane.runLane(lane, app: app)
        } else {
            runner.log("ℹ 该项目没有独立签名步骤;签名由上传 lane 或项目配置处理")
        }
    }

    private func uploadBeta() async {
        working = true; defer { working = false }
        runner.clear()
        guard uploadPreflightPassed(for: .testFlight) else { return }
        await LocalTestFlightService(runner: runner).upload(app: app)
    }

    private func uploadRelease() async {
        working = true; defer { working = false }
        runner.clear()
        guard uploadPreflightPassed(for: .appStore) else { return }
        await fastlane.runLane(app.release.releaseLane ?? "release", app: app)
    }

    private func packageIPA() async {
        working = true; defer { working = false }
        runner.clear()
        _ = await ArtifactPackagingService(runner: runner).packageIPA(app: app)
    }

    private func packageDMG() async {
        working = true; defer { working = false }
        runner.clear()
        _ = await ArtifactPackagingService(runner: runner).packageDMG(app: app)
    }

    /// Detail-page shortcuts used to bypass the release wizard's preflight.
    /// Fail fast here as well so missing credentials/dependencies don't turn
    /// into a long build followed by a cryptic fastlane error.
    private func uploadPreflightPassed(for target: ReleaseTarget) -> Bool {
        let failed = ReleasePreflight.run(app: app, target: target, catalog: catalog.data)
            .filter { $0.status == .failed }
        guard !failed.isEmpty else { return true }
        runner.log("✗ 发布预检未通过,未启动 Fastlane")
        for check in failed {
            runner.log("• \(check.title): \(check.detail)")
        }
        return false
    }

    // MARK: - Helpers

    private func reloadVersion() {
        version = VersionManager.read(app)
    }
}

/// A tappable card representing one release action.
struct ActionCard: View {
    let title: String
    let icon: String
    let subtitle: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
