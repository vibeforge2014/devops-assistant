import Foundation

/// Loads and caches the project catalog from the bundled `projects.json`.
/// The catalog is the single source of truth for which apps and sites the
/// assistant knows about.
@MainActor
final class ProjectCatalog: ObservableObject {
    @Published private(set) var data = ProjectCatalogData(apps: [], sites: [])

    init() {
        load()
    }

    /// Reload from the bundled resource.
    func load() {
        guard let url = Bundle.main.url(forResource: "projects", withExtension: "json") else {
            assertionFailure("projects.json not found in bundle")
            return
        }
        do {
            let raw = try Data(contentsOf: url)
            data = try JSONDecoder().decode(ProjectCatalogData.self, from: raw)
        } catch {
            assertionFailure("Failed to decode projects.json: \(error)")
        }
    }

    var apps: [AppProject] { data.apps }
    var sites: [SiteProject] { data.sites }

    /// Apps whose project root currently exists on disk.
    var availableApps: [AppProject] {
        data.apps.filter(\.existsOnDisk)
    }

    /// Sites whose local clone currently exists.
    var availableSites: [SiteProject] {
        data.sites.filter(\.existsOnDisk)
    }

    func app(id: String) -> AppProject? {
        data.apps.first { $0.id == id }
    }

    func site(id: String) -> SiteProject? {
        data.sites.first { $0.id == id }
    }
}
