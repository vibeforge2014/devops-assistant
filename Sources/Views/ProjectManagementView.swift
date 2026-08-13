import SwiftUI
import UniformTypeIdentifiers

struct ProjectManagementView: View {
    @EnvironmentObject private var catalog: ProjectCatalog
    @EnvironmentObject private var registry: ConsoleRegistry

    @State private var section: ManagedProjectKind = .apps
    @State private var editor: ProjectEditor?
    @State private var deleteTarget: ProjectDeleteTarget?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("项目类型", selection: $section) {
                ForEach(ManagedProjectKind.allCases) { kind in Text(kind.title).tag(kind) }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top], 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let message = catalog.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let notice = catalog.rescanNotice {
                        HStack {
                            Label(notice, systemImage: "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.green)
                            Spacer()
                            Button { catalog.dismissRescanNotice() } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    header
                    if section == .apps { appList } else { siteList }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("项目管理")
        .sheet(item: $editor) { editor in
            switch editor.value {
            case .app(let app):
                AppProjectEditor(original: app) { self.editor = nil }
                    .environmentObject(catalog).environmentObject(registry)
            case .site(let site):
                SiteProjectEditor(original: site) { self.editor = nil }
                    .environmentObject(catalog).environmentObject(registry)
            }
        }
        .confirmationDialog("从管理清单删除？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        ), presenting: deleteTarget) { target in
            Button("删除 \(target.name)", role: .destructive) { delete(target) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("只会移出项目清单，不会删除本地目录、Git 仓库、发布历史或凭据。")
        }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("好", role: .cancel) { errorMessage = nil } }
        message: { Text(errorMessage ?? "未知错误") }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title).font(.title2.bold())
                Text(section == .apps
                     ? "配置源码目录、GitHub 仓库以及构建发布参数。"
                     : "配置发布站点的本地克隆、GitHub 仓库和部署方式。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                catalog.rescanPaths()
            } label: { Label("重新扫描路径", systemImage: "magnifyingglass") }
                .buttonStyle(.bordered)
                .help("自动重新定位已移动或丢失的项目目录")
            Button {
                editor = ProjectEditor(value: section == .apps ? .app(nil) : .site(nil))
            } label: { Label("新增", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }
    }

    private var appList: some View {
        VStack(spacing: 8) {
            if catalog.apps.isEmpty { emptyView("还没有应用项目", icon: "iphone") }
            ForEach(catalog.apps) { app in
                projectRow(name: app.name, id: app.id, path: app.resolvedPath,
                           repositoryURL: app.repositoryURL, exists: app.existsOnDisk,
                           running: registry.isAppRunning(app.id),
                           edit: { editor = ProjectEditor(value: .app(app)) },
                           delete: { deleteTarget = .app(app) })
            }
        }
    }

    private var siteList: some View {
        VStack(spacing: 8) {
            if catalog.sites.isEmpty { emptyView("还没有站点项目", icon: "globe") }
            ForEach(catalog.sites) { site in
                projectRow(name: site.name, id: site.id, path: site.resolvedPath,
                           repositoryURL: site.repositoryURL, exists: site.existsOnDisk,
                           running: registry.isSiteRunning(site.id),
                           edit: { editor = ProjectEditor(value: .site(site)) },
                           delete: { deleteTarget = .site(site) })
            }
        }
    }

    private func projectRow(name: String, id: String, path: String,
                            repositoryURL: String, exists: Bool, running: Bool,
                            edit: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: exists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(exists ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                HStack { Text(name).font(.headline); Text(id).font(.caption).foregroundStyle(.secondary) }
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(repositoryURL).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if running { ProgressView().controlSize(.small).help("项目正在执行任务") }
            Button("编辑", action: edit).disabled(running)
            Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                .disabled(running)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    private func emptyView(_ title: String, icon: String) -> some View {
        ContentUnavailableView(title, systemImage: icon,
                               description: Text("点击右上角“新增”加入项目。"))
            .frame(maxWidth: .infinity).padding(.vertical, 30)
    }

    private func delete(_ target: ProjectDeleteTarget) {
        do {
            switch target {
            case .app(let app):
                guard !registry.isAppRunning(app.id) else {
                    throw ProjectCatalogError.projectBusy
                }
                try catalog.deleteApp(id: app.id)
            case .site(let site):
                guard !registry.isSiteRunning(site.id) else {
                    throw ProjectCatalogError.projectBusy
                }
                try catalog.deleteSite(id: site.id)
            }
        } catch { errorMessage = error.localizedDescription }
    }
}

private enum ManagedProjectKind: String, CaseIterable, Identifiable {
    case apps, sites
    var id: String { rawValue }
    var title: String { self == .apps ? "应用" : "站点" }
}

private struct ProjectEditor: Identifiable {
    enum Value { case app(AppProject?), site(SiteProject?) }
    let id = UUID()
    let value: Value
}

private enum ProjectDeleteTarget: Identifiable {
    case app(AppProject), site(SiteProject)
    var id: String { switch self { case .app(let p): "app:\(p.id)"; case .site(let p): "site:\(p.id)" } }
    var name: String { switch self { case .app(let p): p.name; case .site(let p): p.name } }
}

private struct AppProjectEditor: View {
    @EnvironmentObject private var catalog: ProjectCatalog
    @EnvironmentObject private var registry: ConsoleRegistry
    @Environment(\.dismiss) private var dismiss

    let original: AppProject?
    let onSaved: () -> Void
    @State private var draft: AppDraft
    @State private var advanced = false
    @State private var showFolderPicker = false
    @State private var errorMessage: String?
    @State private var saving = false
    @State private var pendingOrigin: (AppProject, GitOriginState)?
    @State private var showOriginChoice = false

    init(original: AppProject?, onSaved: @escaping () -> Void) {
        self.original = original
        self.onSaved = onSaved
        _draft = State(initialValue: AppDraft(original))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("基础信息") {
                    TextField("项目 ID", text: $draft.id).disabled(original != nil)
                    TextField("名称", text: $draft.name)
                    pathField
                    TextField("GitHub 仓库 URL", text: $draft.repositoryURL)
                        .font(.system(.body, design: .monospaced))
                    Picker("平台", selection: $draft.platform) {
                        ForEach(AppPlatform.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    TextField("Scheme", text: $draft.scheme)
                    TextField("Bundle ID", text: $draft.bundleID)
                    Picker("版本来源", selection: $draft.versionSource) {
                        ForEach(VersionSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                Section {
                    DisclosureGroup("高级发布配置", isExpanded: $advanced) {
                        Picker("发布引擎", selection: $draft.engine) {
                            ForEach(ReleaseEngine.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("签名方式", selection: $draft.signing) {
                            ForEach(SigningMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        TextField("Beta lane（可选）", text: $draft.betaLane)
                        TextField("Release lane（可选）", text: $draft.releaseLane)
                        TextField("Signing lane（可选）", text: $draft.signingLane)
                        TextField("Match 仓库 URL（可选）", text: $draft.matchGitURL)
                        Toggle("需要 macOS 公证", isOn: $draft.notarize)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            editorActions
        }
        .frame(width: 620, height: 650)
        .navigationTitle(original == nil ? "新增应用" : "编辑应用")
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { chooseFolder($0) }
        .confirmationDialog("本地 origin 与新地址不一致", isPresented: $showOriginChoice) {
            Button("同步 origin 并保存") { Task { await syncOriginAndSave() } }
            Button("仅保存配置") { if let candidate = pendingOrigin?.0 { persist(candidate) } }
            Button("取消", role: .cancel) { pendingOrigin = nil }
        } message: { Text("可以同步修改本地 Git 仓库的 origin，或只更新助手中的配置。") }
        .errorAlert($errorMessage)
    }

    private var pathField: some View {
        HStack { TextField("本地目录", text: $draft.path); Button("选择…") { showFolderPicker = true } }
    }

    private var editorActions: some View {
        HStack {
            Button("取消") { dismiss() }
            Spacer()
            if saving { ProgressView().controlSize(.small) }
            Button("保存") { prepareSave() }.buttonStyle(.borderedProminent).disabled(saving)
        }.padding(16)
    }

    private func prepareSave() {
        let candidate = draft.project
        do { try catalog.validateApp(candidate) }
        catch { errorMessage = error.localizedDescription; return }
        guard !registry.isAppRunning(candidate.id) else { errorMessage = "项目正在执行任务，暂时不能修改"; return }
        guard let original, original.repositoryURL != candidate.repositoryURL else { persist(candidate); return }
        saving = true
        Task {
            let state = await GitRemoteService().originState(at: candidate.resolvedPath)
            saving = false
            if state == .notRepository || state == .configured(candidate.repositoryURL) { persist(candidate) }
            else { pendingOrigin = (candidate, state); showOriginChoice = true }
        }
    }

    private func syncOriginAndSave() async {
        guard let (candidate, state) = pendingOrigin else { return }
        saving = true
        let result = await GitRemoteService().setOrigin(candidate.repositoryURL, state: state,
                                                       at: candidate.resolvedPath,
                                                       runner: registry.runnerForApp(candidate.id))
        saving = false
        guard result.succeeded else { errorMessage = "无法更新本地 Git origin，项目配置未保存"; return }
        persist(candidate)
    }

    private func persist(_ candidate: AppProject) {
        do {
            if let original { try catalog.updateApp(candidate, originalID: original.id) }
            else { try catalog.addApp(candidate) }
            onSaved()
        } catch { errorMessage = error.localizedDescription }
    }

    private func chooseFolder(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        draft.path = url.path
    }
}

private struct SiteProjectEditor: View {
    @EnvironmentObject private var catalog: ProjectCatalog
    @EnvironmentObject private var registry: ConsoleRegistry
    @Environment(\.dismiss) private var dismiss

    let original: SiteProject?
    let onSaved: () -> Void
    @State private var draft: SiteDraft
    @State private var showFolderPicker = false
    @State private var errorMessage: String?
    @State private var saving = false
    @State private var pendingOrigin: (SiteProject, GitOriginState)?
    @State private var showOriginChoice = false

    init(original: SiteProject?, onSaved: @escaping () -> Void) {
        self.original = original
        self.onSaved = onSaved
        _draft = State(initialValue: SiteDraft(original))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("站点信息") {
                    TextField("项目 ID", text: $draft.id).disabled(original != nil)
                    TextField("名称", text: $draft.name)
                    HStack { TextField("本地目录", text: $draft.path); Button("选择…") { showFolderPicker = true } }
                    TextField("GitHub 仓库 URL", text: $draft.repositoryURL)
                        .font(.system(.body, design: .monospaced))
                    Picker("部署方式", selection: $draft.deploy) {
                        ForEach(DeployMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("保存") { prepareSave() }.buttonStyle(.borderedProminent).disabled(saving)
            }.padding(16)
        }
        .frame(width: 600, height: 430)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { draft.path = url.path }
        }
        .confirmationDialog("本地 origin 与新地址不一致", isPresented: $showOriginChoice) {
            Button("同步 origin 并保存") { Task { await syncOriginAndSave() } }
            Button("仅保存配置") { if let candidate = pendingOrigin?.0 { persist(candidate) } }
            Button("取消", role: .cancel) { pendingOrigin = nil }
        } message: { Text("可以同步修改本地 Git 仓库的 origin，或只更新助手中的配置。") }
        .errorAlert($errorMessage)
    }

    private func prepareSave() {
        let candidate = draft.project
        do { try catalog.validateSite(candidate) }
        catch { errorMessage = error.localizedDescription; return }
        guard !registry.isSiteRunning(candidate.id) else { errorMessage = "项目正在执行任务，暂时不能修改"; return }
        guard let original, original.repositoryURL != candidate.repositoryURL else { persist(candidate); return }
        saving = true
        Task {
            let state = await GitRemoteService().originState(at: candidate.resolvedPath)
            saving = false
            if state == .notRepository || state == .configured(candidate.repositoryURL) { persist(candidate) }
            else { pendingOrigin = (candidate, state); showOriginChoice = true }
        }
    }

    private func syncOriginAndSave() async {
        guard let (candidate, state) = pendingOrigin else { return }
        saving = true
        let result = await GitRemoteService().setOrigin(candidate.repositoryURL, state: state,
                                                       at: candidate.resolvedPath,
                                                       runner: registry.runnerForSite(candidate.id))
        saving = false
        guard result.succeeded else { errorMessage = "无法更新本地 Git origin，项目配置未保存"; return }
        persist(candidate)
    }

    private func persist(_ candidate: SiteProject) {
        do {
            if let original { try catalog.updateSite(candidate, originalID: original.id) }
            else { try catalog.addSite(candidate) }
            onSaved()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct AppDraft {
    var id = "", name = "", path = "", repositoryURL = "", scheme = "", bundleID = ""
    var platform: AppPlatform = .ios
    var versionSource: VersionSource = .projectYml
    var engine: ReleaseEngine = .native
    var signing: SigningMethod = .manual
    var betaLane = "", releaseLane = "", signingLane = "", matchGitURL = ""
    var notarize = false

    init(_ app: AppProject?) {
        guard let app else { return }
        id = app.id; name = app.name; path = app.path; repositoryURL = app.repositoryURL
        platform = app.platform; scheme = app.scheme; bundleID = app.bundleId
        versionSource = app.versionSource; engine = app.release.engine; signing = app.release.signing
        betaLane = app.release.betaLane ?? ""; releaseLane = app.release.releaseLane ?? ""
        signingLane = app.release.signingLane ?? ""; matchGitURL = app.release.matchGitURL ?? ""
        notarize = app.release.notarize
    }

    var project: AppProject {
        AppProject(id: id.trimmed, name: name.trimmed, path: path.trimmed,
                   repositoryURL: repositoryURL.trimmed, platform: platform,
                   scheme: scheme.trimmed, bundleId: bundleID.trimmed,
                   versionSource: versionSource,
                   release: ReleaseConfig(engine: engine, betaLane: betaLane.nilIfEmpty,
                                          releaseLane: releaseLane.nilIfEmpty,
                                          signingLane: signingLane.nilIfEmpty,
                                          signing: signing, matchGitURL: matchGitURL.nilIfEmpty,
                                          notarize: notarize))
    }
}

private struct SiteDraft {
    var id = "", name = "", path = "", repositoryURL = ""
    var deploy: DeployMethod = .gitPushMain
    init(_ site: SiteProject?) {
        guard let site else { return }
        id = site.id; name = site.name; path = site.path
        repositoryURL = site.repositoryURL; deploy = site.deploy
    }
    var project: SiteProject {
        SiteProject(id: id.trimmed, name: name.trimmed, path: path.trimmed,
                    repositoryURL: repositoryURL.trimmed, deploy: deploy)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { trimmed.isEmpty ? nil : trimmed }
}

private extension View {
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert("操作失败", isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) { Button("好", role: .cancel) { message.wrappedValue = nil } }
        message: { Text(message.wrappedValue ?? "未知错误") }
    }
}
