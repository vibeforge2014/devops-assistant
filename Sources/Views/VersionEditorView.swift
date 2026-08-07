import SwiftUI

/// 跨项目版本号管理视图。列出所有本地可用的 app,显示当前 marketing/build
/// 版本,支持「bump build」自增构建号或打开 sheet 手动编辑。
struct VersionEditorView: View {
    @EnvironmentObject var catalog: ProjectCatalog

    /// app.id → 当前版本缓存,onAppear 时批量读取,bump / 编辑后局部刷新。
    @State private var versions: [String: VersionPair] = [:]
    @State private var editingApp: AppProject?
    @State private var editingCurrent: VersionPair?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                intro

                if catalog.availableApps.isEmpty {
                    ContentUnavailableView(
                        "没有可用的应用",
                        systemImage: "number.circle",
                        description: Text("未检测到任何本地项目路径,请先克隆或配置项目。")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    VStack(spacing: 8) {
                        ForEach(catalog.availableApps) { app in
                            versionRow(for: app)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("版本号管理")
        .sheet(item: $editingApp) { app in
            VersionEditSheet(app: app, current: editingCurrent ?? versions[app.id]) { saved in
                versions[app.id] = saved
            }
        }
        .onAppear { reloadAll() }
    }

    // MARK: - Intro

    private var intro: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "number.circle.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("跨应用统一管理 MARKETING_VERSION 与 build 号。")
                    .font(.callout)
                Text("点击「bump build」自增构建号,或「编辑」手动修改后再保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Rows

    private func versionRow(for app: AppProject) -> some View {
        let version = versions[app.id]
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.headline)
                Text(app.bundleId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(version?.marketing ?? "—")
                    .font(.title3.monospacedDigit().bold())
                Text("build \(version?.build ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 120, alignment: .trailing)

            Button {
                Task { await bump(app) }
            } label: {
                Label("bump build", systemImage: "arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                editingCurrent = version
                editingApp = app
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    // MARK: - Commands

    private func bump(_ app: AppProject) async {
        guard let newVersion = VersionManager.bumpBuild(app) else { return }
        versions[app.id] = newVersion
    }

    private func reloadAll() {
        versions.removeAll()
        for app in catalog.availableApps {
            versions[app.id] = VersionManager.read(app)
        }
    }
}

/// 版本号编辑 sheet:修改 marketing / build 并写回项目。被 VersionEditorView
/// 与 ProjectDetail 共同复用,所以定义在此处以全局可见。
struct VersionEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let app: AppProject
    let current: VersionPair?
    let onSaved: (VersionPair) -> Void

    @State private var marketing: String = ""
    @State private var build: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("编辑版本号 — \(app.name)").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("MARKETING_VERSION")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("例如 0.2.5", text: $marketing)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("CURRENT_PROJECT_VERSION")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("例如 8", text: $build)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("取消", role: .cancel) { dismiss() }
                Spacer()
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { populate() }
    }

    private var canSave: Bool {
        !marketing.trimmingCharacters(in: .whitespaces).isEmpty &&
        !build.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func populate() {
        marketing = current?.marketing ?? ""
        build = current?.build ?? ""
    }

    private func save() {
        let pair = VersionPair(
            marketing: marketing.trimmingCharacters(in: .whitespaces),
            build: build.trimmingCharacters(in: .whitespaces)
        )
        guard VersionManager.write(pair, to: app) else { return }
        onSaved(pair)
        dismiss()
    }
}
