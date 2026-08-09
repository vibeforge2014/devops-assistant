import Foundation

enum ProjectCatalogError: LocalizedError, Equatable {
    case invalidID
    case duplicateID(String)
    case emptyField(String)
    case invalidRepositoryURL
    case projectNotFound(String)
    case idCannotChange
    case projectBusy
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidID:
            return "项目 ID 只能包含小写字母、数字和连字符，且必须以字母或数字开头"
        case .duplicateID(let id): return "项目 ID \(id) 已存在"
        case .emptyField(let field): return "\(field)不能为空"
        case .invalidRepositoryURL:
            return "请输入完整的 GitHub SSH 或 HTTPS 仓库地址"
        case .projectNotFound(let id): return "找不到项目 \(id)"
        case .idCannotChange: return "项目 ID 创建后不能修改"
        case .projectBusy: return "项目正在执行任务，暂时不能修改或删除"
        case .persistenceFailed(let detail): return "无法保存项目目录：\(detail)"
        }
    }
}

/// The user-editable source of truth for apps and sites. On first launch the
/// bundled catalog is copied to Application Support; subsequent launches only
/// read the user copy. Mutations are published only after an atomic save.
@MainActor
final class ProjectCatalog: ObservableObject {
    @Published private(set) var data = ProjectCatalogData(apps: [], sites: [])
    @Published private(set) var errorMessage: String?

    private let fileURL: URL
    private let bundledURL: URL?
    private let fileManager: FileManager

    convenience init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = support.appendingPathComponent("com.vibeforge.devops-assistant", isDirectory: true)
        self.init(
            fileURL: directory.appendingPathComponent("projects.json"),
            bundledURL: Bundle.main.url(forResource: "projects", withExtension: "json"),
            fileManager: fm
        )
    }

    /// Injectable paths keep persistence and migration tests isolated.
    init(fileURL: URL, bundledURL: URL?, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.bundledURL = bundledURL
        self.fileManager = fileManager
        load()
    }

    func load() {
        errorMessage = nil
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                data = try decode(from: fileURL)
            } catch {
                errorMessage = "用户项目配置无法读取，已临时使用内置清单：\(error.localizedDescription)"
                loadBundledWithoutOverwriting()
            }
            return
        }

        guard let bundledURL else {
            errorMessage = "找不到内置项目清单"
            return
        }
        do {
            let seeded = try decode(from: bundledURL)
            data = seeded
            do { try persist(seeded) }
            catch { errorMessage = error.localizedDescription }
        } catch {
            errorMessage = "内置项目清单无法读取：\(error.localizedDescription)"
        }
    }

    var apps: [AppProject] { data.apps }
    var sites: [SiteProject] { data.sites }
    var availableApps: [AppProject] { data.apps.filter(\.existsOnDisk) }
    var availableSites: [SiteProject] { data.sites.filter(\.existsOnDisk) }

    func app(id: String) -> AppProject? { data.apps.first { $0.id == id } }
    func site(id: String) -> SiteProject? { data.sites.first { $0.id == id } }

    func addApp(_ app: AppProject) throws {
        try validateApp(app)
        guard self.app(id: app.id) == nil else { throw ProjectCatalogError.duplicateID(app.id) }
        try commit(ProjectCatalogData(apps: data.apps + [app], sites: data.sites))
    }

    func updateApp(_ app: AppProject, originalID: String) throws {
        guard app.id == originalID else { throw ProjectCatalogError.idCannotChange }
        guard let index = data.apps.firstIndex(where: { $0.id == originalID }) else {
            throw ProjectCatalogError.projectNotFound(originalID)
        }
        try validateApp(app)
        var apps = data.apps
        apps[index] = app
        try commit(ProjectCatalogData(apps: apps, sites: data.sites))
    }

    func deleteApp(id: String) throws {
        guard data.apps.contains(where: { $0.id == id }) else {
            throw ProjectCatalogError.projectNotFound(id)
        }
        try commit(ProjectCatalogData(apps: data.apps.filter { $0.id != id }, sites: data.sites))
    }

    func addSite(_ site: SiteProject) throws {
        try validateSite(site)
        guard self.site(id: site.id) == nil else { throw ProjectCatalogError.duplicateID(site.id) }
        try commit(ProjectCatalogData(apps: data.apps, sites: data.sites + [site]))
    }

    func updateSite(_ site: SiteProject, originalID: String) throws {
        guard site.id == originalID else { throw ProjectCatalogError.idCannotChange }
        guard let index = data.sites.firstIndex(where: { $0.id == originalID }) else {
            throw ProjectCatalogError.projectNotFound(originalID)
        }
        try validateSite(site)
        var sites = data.sites
        sites[index] = site
        try commit(ProjectCatalogData(apps: data.apps, sites: sites))
    }

    func deleteSite(id: String) throws {
        guard data.sites.contains(where: { $0.id == id }) else {
            throw ProjectCatalogError.projectNotFound(id)
        }
        try commit(ProjectCatalogData(apps: data.apps, sites: data.sites.filter { $0.id != id }))
    }

    static func isValidRepositoryURL(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^git@github\.com:[^/\s]+/[^/\s]+(?:\.git)?$"#,
                       options: .regularExpression) != nil { return true }
        guard let url = URL(string: value),
              ["https", "ssh"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == "github.com" else { return false }
        return url.path.split(separator: "/").count == 2
    }

    func validateApp(_ app: AppProject) throws {
        try validateCommon(id: app.id, name: app.name, path: app.path,
                           repositoryURL: app.repositoryURL)
        if app.scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProjectCatalogError.emptyField("Scheme")
        }
        if app.bundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProjectCatalogError.emptyField("Bundle ID")
        }
    }

    func validateSite(_ site: SiteProject) throws {
        try validateCommon(id: site.id, name: site.name, path: site.path,
                           repositoryURL: site.repositoryURL)
    }

    private func validateCommon(id: String, name: String, path: String,
                                repositoryURL: String) throws {
        guard id.range(of: #"^[a-z0-9][a-z0-9-]*$"#,
                       options: .regularExpression) != nil else {
            throw ProjectCatalogError.invalidID
        }
        for (label, value) in [("名称", name), ("本地目录", path), ("仓库地址", repositoryURL)] {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ProjectCatalogError.emptyField(label)
            }
        }
        guard Self.isValidRepositoryURL(repositoryURL) else {
            throw ProjectCatalogError.invalidRepositoryURL
        }
    }

    private func commit(_ candidate: ProjectCatalogData) throws {
        try persist(candidate)
        data = candidate
        errorMessage = nil
    }

    private func persist(_ candidate: ProjectCatalogData) throws {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded = try encoder.encode(candidate)
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            throw ProjectCatalogError.persistenceFailed(error.localizedDescription)
        }
    }

    private func decode(from url: URL) throws -> ProjectCatalogData {
        try JSONDecoder().decode(ProjectCatalogData.self, from: Data(contentsOf: url))
    }

    private func loadBundledWithoutOverwriting() {
        guard let bundledURL, let fallback = try? decode(from: bundledURL) else { return }
        data = fallback
    }
}
