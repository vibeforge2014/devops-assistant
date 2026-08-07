import SwiftUI

/// The detail view for a single app project. Shows version, signing info, and
/// the four release actions (build, sign/notarize, TestFlight, App Store),
/// each streaming output into an embedded console.
struct ProjectDetail: View {
    @EnvironmentObject var runner: ShellRunner
    let app: AppProject

    @State private var version: VersionPair?
    @State private var showVersionEditor = false
    @State private var working = false

    private var buildService: BuildService { BuildService(runner: runner) }
    private var fastlane: FastlaneRunner { FastlaneRunner(runner: runner) }
    private var notary: NotaryService { NotaryService(runner: runner) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if !app.existsOnDisk {
                        missingPathBanner
                    }

                    actionGrid
                }
                .padding(24)
            }

            Divider()
            ConsolePanel()
                .frame(height: 220)
        }
        .navigationTitle(app.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("编辑版本号") { showVersionEditor = true }
                    .disabled(working)
            }
        }
        .sheet(isPresented: $showVersionEditor) {
            VersionEditSheet(app: app, current: version) { newVersion in
                version = newVersion
            }
        }
        .onAppear { reloadVersion() }
        .disabled(working)
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
                       subtitle: app.release.engine == .fastlane ? "fastlane \(app.release.betaLane ?? "beta")" : "需先生成 lane",
                       enabled: app.release.engine == .fastlane) {
                Task { await uploadBeta() }
            }
            ActionCard(title: "上传 App Store", icon: "shippingbox",
                       subtitle: app.release.engine == .fastlane ? "fastlane \(app.release.releaseLane ?? "release")" : "需先生成 lane",
                       enabled: app.release.engine == .fastlane) {
                Task { await uploadRelease() }
            }
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

    private var missingPathBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading) {
                Text("项目路径不存在").font(.headline)
                Text(app.resolvedPath).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([]) }
                .buttonStyle(.bordered)
        }
        .padding()
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Actions (commands)

    private func build() async {
        working = true; defer { working = false }
        await buildService.generateXcodeProject(at: app.resolvedPath)
        await buildService.archive(app: app, to: buildService.archivePath(for: app))
    }

    private func sign() async {
        working = true; defer { working = false }
        if app.release.notarize {
            let bundle = "\(buildService.archivePath(for: app))/Products/Applications/\(app.scheme).app"
            await notary.signAppBundle(at: bundle)
        } else if app.release.engine == .fastlane {
            await fastlane.runLane(app.release.betaLane == "beta" ? "certs" : "certs", app: app)
        }
    }

    private func uploadBeta() async {
        working = true; defer { working = false }
        await fastlane.runLane(app.release.betaLane ?? "beta", app: app)
    }

    private func uploadRelease() async {
        working = true; defer { working = false }
        await fastlane.runLane(app.release.releaseLane ?? "release", app: app)
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
