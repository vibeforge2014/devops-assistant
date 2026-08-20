import Foundation
import SwiftUI

/// Fetches and caches each app's App Store presence: storefront prices
/// (public iTunes lookup) plus the full in-app purchase / subscription list
/// with CN+US prices (App Store Connect API). App-level object so the cache
/// survives sidebar navigation; a disk snapshot makes it survive relaunches.
///
/// Error policy: top-level ASC failures (app lookup, IAP list, subscription
/// groups) fail the whole refresh — an empty IAP list must mean "none
/// configured", never "the requests died silently". Per-item price failures
/// degrade to a 价格获取失败 marker on that row instead.
@MainActor
final class AppStoreInfoService: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var states: [String: LoadState] = [:]
    @Published private(set) var infos: [String: StoreAppInfo] = [:]

    /// Re-fetch automatically at most this often (manual refresh always can).
    static let stalenessTTL: TimeInterval = 10 * 60

    /// Cap on in-flight ASC price-point requests — a matrix refresh can
    /// otherwise fire dozens of concurrent GETs through this machine's slow
    /// proxy and trip ASC rate limiting.
    static let maxConcurrentFetches = 4

    private let fileURL: URL

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSupport.appendingPathComponent("com.vibeforge.devops-assistant", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("store-info.json", isDirectory: false)
        loadSnapshot()
    }

    // MARK: - Accessors

    func info(for app: AppProject) -> StoreAppInfo? { infos[app.id] }

    func state(for app: AppProject) -> LoadState { states[app.id] ?? .idle }

    func isStale(_ app: AppProject) -> Bool {
        guard let info = infos[app.id] else { return true }
        return Date().timeIntervalSince(info.fetchedAt) > Self.stalenessTTL
    }

    func refreshIfNeeded(_ app: AppProject) {
        guard state(for: app) != .loading, isStale(app) else { return }
        Task { await refresh(app) }
    }

    /// Drop cached state for projects removed from the catalog (pass the
    /// SURVIVING ids), so a new project reusing an id can't inherit the old
    /// one's price data.
    func evict(keepingAppIDs: Set<String>) {
        for id in states.keys where !keepingAppIDs.contains(id) {
            states[id] = nil
            infos[id] = nil
        }
    }

    // MARK: - Fetch

    func refresh(_ app: AppProject) async {
        guard states[app.id] != .loading else { return }
        states[app.id] = .loading

        // The two sources are independent — don't make the (slow, proxied)
        // ASC chain delay the iTunes half or vice versa.
        async let itunesResult = fetchITunesPrices(bundleId: app.bundleId)
        async let ascResult = fetchASCInAppPurchases(bundleId: app.bundleId)
        let (itunes, asc) = await (itunesResult, ascResult)

        switch asc {
        case .failure(let error):
            // Without ASC the section's核心内容 (IAP list) is missing — treat
            // as a failure even if iTunes returned something.
            states[app.id] = .failed(error.errorDescription ?? "获取失败")
            return
        case .success(let ascData):
            var info = merge(appName: app.name, itunes: itunes, asc: ascData)
            info.fetchedAt = Date()
            infos[app.id] = info
            states[app.id] = .loaded
            saveSnapshot()
        }
    }

    // MARK: - iTunes lookup (public)

    struct ITunesFetch {
        var app: ITunesApp?
        var prices: [TerritoryPrice] = []
        var failedTerritories: [String] = []
    }

    /// One storefront lookup: `failed` distinguishes a dead request from a
    /// clean "not listed on this storefront" (app == nil && !failed).
    private struct TerritoryLookup {
        let territory: StorefrontTerritory
        let app: ITunesApp?
        let failed: Bool
    }

    private static func lookupTerritory(bundleId: String,
                                        territory: StorefrontTerritory) async -> TerritoryLookup {
        var comps = URLComponents(string: "https://itunes.apple.com/lookup")
        comps?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleId),
            URLQueryItem(name: "country", value: territory.itunes),
        ]
        guard let url = comps?.url else {
            return .init(territory: territory, app: nil, failed: true)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ITunesLookupResponse.self, from: data) else {
            return .init(territory: territory, app: nil, failed: true)
        }
        return .init(territory: territory, app: decoded.results?.first, failed: false)
    }

    private func fetchITunesPrices(bundleId: String) async -> ITunesFetch {
        var result = ITunesFetch()
        await withTaskGroup(of: TerritoryLookup.self) { group in
            for territory in StorefrontTerritory.all {
                group.addTask {
                    await Self.lookupTerritory(bundleId: bundleId, territory: territory)
                }
            }
            for await lookup in group {
                if lookup.failed {
                    result.failedTerritories.append(lookup.territory.label)
                    continue
                }
                guard let found = lookup.app else { continue } // not listed here
                result.app = result.app ?? found
                if let price = found.formattedPrice {
                    result.prices.append(TerritoryPrice(territory: lookup.territory.asc,
                                                        formatted: price,
                                                        currency: found.currency))
                }
            }
        }
        return result
    }

    // MARK: - ASC chain

    struct ASCFetch {
        var appName: String?
        var appFound = false
        var purchases: [IAPInfo] = []
    }

    private func fetchASCInAppPurchases(bundleId: String) async -> Result<ASCFetch, ASCAPIError> {
        let client = ASCAPIClient.shared
        var fetch = ASCFetch()

        // 1. Resolve the ASC app id for this bundle id.
        let encoded = bundleId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundleId
        let appsData: Data
        do {
            appsData = try await client.get("v1/apps?filter%5BbundleId%5D=\(encoded)&limit=1")
        } catch let error as ASCAPIError {
            return .failure(error)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
        guard let apps = try? JSONDecoder().decode(ASCListResponse<ASCAppAttributes>.self, from: appsData),
              let appID = apps.data?.first?.id else {
            // Not an ASC-side failure: the bundle id simply has no app record
            // (typo in the catalog, or app not yet created).
            fetch.appFound = false
            return .success(fetch)
        }
        fetch.appFound = true
        fetch.appName = apps.data?.first?.attributes?.name

        async let nonSubs = fetchNonSubscriptions(appID: appID, client: client)
        async let subs = fetchSubscriptions(appID: appID, client: client)
        do {
            let (nonSubList, subList) = try await (nonSubs, subs)
            fetch.purchases = (nonSubList + subList)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch let error as ASCAPIError {
            return .failure(error)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
        return .success(fetch)
    }

    private func fetchNonSubscriptions(appID: String, client: ASCAPIClient) async throws -> [IAPInfo] {
        let territories = StorefrontTerritory.all.map(\.asc).joined(separator: ",")
        // Top-level list failures propagate: an unseen error must not render
        // as "无内购项目".
        let data = try await client.get("v1/apps/\(appID)/inAppPurchasesV2?limit=200")
        let list = try JSONDecoder().decode(ASCListResponse<ASCIAPAttributes>.self, from: data)

        // Price points per IAP, windowed to `maxConcurrentFetches`.
        return await withTaskGroup(of: IAPInfo?.self) { group in
            var iterator = list.data?.makeIterator()
            func addNext() -> Bool {
                guard let item = iterator?.next() else { return false }
                let attrs = item.attributes
                let iapID = item.id
                group.addTask {
                    var prices: [TerritoryPrice] = []
                    var priceFailed = false
                    do {
                        let priceData = try await client.get(
                            "v2/inAppPurchasesV2/\(iapID)/pricePoints?filter%5Bterritory%5D=\(territories)&limit=50")
                        let points = try JSONDecoder().decode(ASCIAPPricePointsResponse.self, from: priceData)
                        prices = Self.territoryPrices(from: points.pricesByTerritory())
                    } catch {
                        priceFailed = true
                    }
                    return IAPInfo(
                        id: iapID,
                        name: attrs?.name ?? attrs?.productId ?? iapID,
                        productId: attrs?.productId ?? "",
                        kind: IAPKind(rawValue: attrs?.type ?? ""),
                        state: attrs?.state ?? "",
                        period: nil,
                        prices: prices,
                        priceFetchFailed: priceFailed)
                }
                return true
            }
            for _ in 0..<Self.maxConcurrentFetches where addNext() {}
            var result: [IAPInfo] = []
            for await info in group {
                if let info { result.append(info) }
                _ = addNext()
            }
            return result
        }
    }

    private func fetchSubscriptions(appID: String, client: ASCAPIClient) async throws -> [IAPInfo] {
        let territories = StorefrontTerritory.all.map(\.asc).joined(separator: ",")
        let groupsData = try await client.get(
            "v1/apps/\(appID)/subscriptionGroups?limit=50")
        let groups = try JSONDecoder().decode(ASCListResponse<ASCSubscriptionGroupAttributes>.self, from: groupsData)

        var result: [IAPInfo] = []
        for group in groups.data ?? [] {
            let subsData = try await client.get(
                "v1/subscriptionGroups/\(group.id)/subscriptions?limit=100")
            let subs = try JSONDecoder().decode(ASCListResponse<ASCSubscriptionAttributes>.self, from: subsData)
            for sub in subs.data ?? [] {
                let attrs = sub.attributes
                var prices: [TerritoryPrice] = []
                var priceFailed = false
                do {
                    let priceData = try await client.get(
                        "v1/subscriptions/\(sub.id)/prices?filter%5Bterritory%5D=\(territories)&include=subscriptionPricePoint%2Cterritory&limit=20")
                    let pricesResponse = try JSONDecoder().decode(ASCSubscriptionPricesResponse.self, from: priceData)
                    prices = Self.territoryPrices(from: pricesResponse.pricesByTerritory())
                } catch {
                    priceFailed = true
                }
                result.append(IAPInfo(
                    id: sub.id,
                    name: attrs?.name ?? attrs?.productId ?? sub.id,
                    productId: attrs?.productId ?? "",
                    kind: .autoRenewable,
                    state: attrs?.state ?? "",
                    period: attrs?.subscriptionPeriod,
                    prices: prices,
                    priceFetchFailed: priceFailed))
            }
        }
        return result
    }

    /// Shared mapping from {territory code → price} into display prices.
    nonisolated static func territoryPrices(from map: [String: FlexiblePrice]) -> [TerritoryPrice] {
        StorefrontTerritory.all.compactMap { territory in
            guard let price = map[territory.asc] ?? map[""], let amount = price.amount,
                  !amount.isEmpty else { return nil }
            return TerritoryPrice(territory: territory.asc,
                                  formatted: amount,
                                  currency: price.currency)
        }
    }

    // MARK: - Merge

    private func merge(appName: String, itunes: ITunesFetch, asc: ASCFetch) -> StoreAppInfo {
        var info = StoreAppInfo(
            trackName: itunes.app?.trackName,
            ascAppName: asc.appName ?? appName,
            currentVersion: itunes.app?.version,
            rating: itunes.app?.averageUserRating,
            ratingCount: itunes.app?.userRatingCount,
            storeURL: itunes.app?.trackViewUrl,
            appPrices: itunes.prices,
            isLive: itunes.app != nil,
            storeFetchFailed: !itunes.failedTerritories.isEmpty && itunes.app == nil,
            inAppPurchases: asc.purchases,
            fetchedAt: Date())
        if info.isLive, itunes.app?.price != nil, itunes.app?.formattedPrice == nil {
            // Free apps sometimes omit formattedPrice — synthesize from price.
            info.appPrices = StorefrontTerritory.all.compactMap { t in
                itunes.prices.first { $0.territory == t.asc } ?? TerritoryPrice(
                    territory: t.asc, formatted: "免费", currency: nil)
            }
        }
        return info
    }

    // MARK: - Disk snapshot

    private struct Snapshot: Codable {
        var infos: [String: StoreAppInfo]
    }

    /// Best-effort persist so relaunching shows last-known prices instantly;
    /// a corrupt file is ignored (next refresh rebuilds it).
    private func saveSnapshot() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Snapshot(infos: infos)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func loadSnapshot() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return }
        infos = snapshot.infos
    }
}
