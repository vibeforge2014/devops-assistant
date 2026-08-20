import Foundation

// MARK: - Storefronts

/// The storefronts we surface prices for. iTunes lookup keys off the
/// alpha-2 `itunes` code (`?country=cn`); ASC territory filters key off the
/// alpha-3 `asc` code (`filter[territory]=CHN`) — both verified live.
struct StorefrontTerritory: Hashable {
    let itunes: String
    let asc: String
    let label: String
    let symbol: String

    static let all: [StorefrontTerritory] = [
        .init(itunes: "CN", asc: "CHN", label: "中国区", symbol: "¥"),
        .init(itunes: "US", asc: "USA", label: "美区", symbol: "$"),
    ]

    static func byASCCode(_ code: String) -> StorefrontTerritory? {
        all.first { $0.asc == code.uppercased() }
    }

    static func byITunesCode(_ code: String) -> StorefrontTerritory? {
        all.first { $0.itunes == code.uppercased() }
    }
}

// MARK: - Display models

/// One storefront's price for the app or an in-app purchase.
struct TerritoryPrice: Codable, Equatable, Identifiable {
    /// Alpha-3 territory code ("CHN"/"USA") — the ASC-side identity.
    let territory: String
    /// Customer-facing price as served ("2.99"), or a storefront-formatted
    /// string from iTunes ("¥6.00"/"免费").
    let formatted: String
    /// ISO currency ("CNY"/"USD") when known.
    let currency: String?

    var id: String { territory }

    var storefront: StorefrontTerritory? { StorefrontTerritory.byASCCode(territory) }

    /// "中国区 ¥6.00" / "美区 $2.99" — falls back to the raw string when the
    /// currency/symbol can't be mapped.
    var displayLabel: String {
        guard let storefront else { return formatted }
        if formatted.hasPrefix(storefront.symbol) || formatted == "免费" || formatted == "Free" {
            return "\(storefront.label) \(formatted)"
        }
        if let amount = Double(formatted), amount > 0 {
            return "\(storefront.label) \(storefront.symbol)\(formatted)"
        }
        return "\(storefront.label) \(formatted)"
    }
}

enum IAPKind: Codable, Equatable {
    case consumable
    case nonConsumable
    case nonRenewing
    case autoRenewable
    case unknown(String)

    var displayName: String {
        switch self {
        case .consumable: "消耗型"
        case .nonConsumable: "非消耗型"
        case .nonRenewing: "非续期订阅"
        case .autoRenewable: "自动续期"
        case .unknown: "内购"
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "CONSUMABLE": self = .consumable
        case "NON_CONSUMABLE": self = .nonConsumable
        case "NON_RENEWING_SUBSCRIPTION": self = .nonRenewing
        default: self = .unknown(rawValue)
        }
    }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .consumable: try c.encode("CONSUMABLE")
        case .nonConsumable: try c.encode("NON_CONSUMABLE")
        case .nonRenewing: try c.encode("NON_RENEWING_SUBSCRIPTION")
        case .autoRenewable: try c.encode("AUTO_RENEWABLE")
        case .unknown(let raw): try c.encode(raw)
        }
    }
}

enum IAPStateInfo {
    /// Human label for the raw ASC state string, unknown values pass through.
    static func label(for raw: String) -> String {
        switch raw {
        case "APPROVED": "已上架"
        case "READY_FOR_REVIEW": "待提交审核"
        case "WAITING_FOR_REVIEW": "等待审核"
        case "IN_REVIEW": "审核中"
        case "REJECTED": "已拒绝"
        case "DELETED": "已删除"
        case "MISSING_EXPORT_COMPLIANCE": "缺出口合规信息"
        case "DEVELOPER_REMOVED_FROM_SALE": "开发者下架"
        default: raw
        }
    }

    /// Style hint for the state chip.
    static func isLive(_ raw: String) -> Bool { raw == "APPROVED" }
    static func isProblem(_ raw: String) -> Bool {
        raw == "REJECTED" || raw == "DELETED" || raw == "DEVELOPER_REMOVED_FROM_SALE"
    }
}

/// One in-app purchase (non-subscription) or auto-renewable subscription.
struct IAPInfo: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let productId: String
    let kind: IAPKind
    let state: String
    /// "ONE_MONTH"/"ONE_YEAR"/… (subscriptions only) → "每月"/"每年".
    let period: String?
    let prices: [TerritoryPrice]
    /// Price points for this item couldn't be fetched (network/ASC hiccup) —
    /// distinguishes "获取失败" from a genuinely unset price.
    var priceFetchFailed: Bool = false

    var periodLabel: String? {
        switch period {
        case "ONE_WEEK": "每周"
        case "ONE_MONTH": "每月"
        case "TWO_MONTHS": "每两月"
        case "THREE_MONTHS": "每季度"
        case "SIX_MONTHS": "每半年"
        case "ONE_YEAR": "每年"
        default: nil
        }
    }

    /// "¥8.00 · $1.29" — every configured storefront, cheap join for rows.
    var priceSummary: String {
        if priceFetchFailed { return "价格获取失败" }
        let parts = StorefrontTerritory.all.compactMap { t in
            prices.first { $0.territory == t.asc }?.displayLabel
        }
        return parts.isEmpty ? "未设价" : parts.joined(separator: " · ")
    }
}

/// Everything the App Store section shows for one app.
struct StoreAppInfo: Codable, Equatable {
    /// Name as listed on the storefront (localized) — nil when unreleased.
    var trackName: String?
    /// Name as configured in App Store Connect (fallback display name).
    var ascAppName: String?
    var currentVersion: String?
    var rating: Double?
    var ratingCount: Int?
    var storeURL: String?
    var appPrices: [TerritoryPrice]
    /// Whether iTunes lookup found the app on any storefront (i.e. released).
    var isLive: Bool
    /// The storefront lookups themselves failed (network) — distinct from
    /// "looked and not listed", which is what isLive == false means.
    var storeFetchFailed: Bool = false
    var inAppPurchases: [IAPInfo]
    var fetchedAt: Date

    var displayName: String { trackName ?? ascAppName ?? "" }

    var priceSummary: String {
        let parts = StorefrontTerritory.all.compactMap { t in
            appPrices.first { $0.territory == t.asc }?.displayLabel
        }
        return parts.isEmpty ? "未设价" : parts.joined(separator: " · ")
    }

    var hasSubscriptions: Bool {
        inAppPurchases.contains { $0.kind == .autoRenewable }
    }
}

// MARK: - iTunes lookup parsing

struct ITunesLookupResponse: Codable {
    let resultCount: Int
    let results: [ITunesApp]?
}

struct ITunesApp: Codable {
    let trackName: String?
    let formattedPrice: String?
    let price: Double?
    let currency: String?
    let version: String?
    let averageUserRating: Double?
    let userRatingCount: Int?
    let trackViewUrl: String?
}

// MARK: - ASC API parsing

/// A ASC JSON:API document with no includes.
struct ASCListResponse<Attributes: Codable>: Codable {
    struct Item: Codable {
        let id: String
        let attributes: Attributes?
    }
    let data: [Item]?
}

struct ASCAppAttributes: Codable {
    let bundleId: String?
    let name: String?
}

struct ASCIAPAttributes: Codable {
    let name: String?
    let productId: String?
    let type: String?
    let state: String?
}

struct ASCSubscriptionGroupAttributes: Codable {
    let referenceName: String?
}

struct ASCSubscriptionAttributes: Codable {
    let name: String?
    let productId: String?
    let state: String?
    let subscriptionPeriod: String?
}

/// `customerPrice` appears as a plain string ("2.99") in subscription price
/// points; older/other endpoints may shape it as an object — accept both.
struct FlexiblePrice: Codable, Equatable {
    let amount: String?
    let currency: String?

    init(amount: String?, currency: String?) {
        self.amount = amount
        self.currency = currency
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .init(amount: s, currency: nil)
            return
        }
        struct Shaped: Codable { let amount: String?; let value: String?; let currency: String? }
        if let shaped = try? c.decode(Shaped.self) {
            self = .init(amount: shaped.amount ?? shaped.value, currency: shaped.currency)
            return
        }
        self = .init(amount: nil, currency: nil)
    }
}

/// The compound `/v1/subscriptions/{id}/prices?include=…` response: each
/// data item points at one price point and one territory, both expanded in
/// `included`. Attribute shapes are unioned tolerantly because included
/// mixes two resource types.
struct ASCSubscriptionPricesResponse: Codable {
    struct Item: Codable {
        /// A relationship is `{"data": {"type": …, "id": …}}`.
        struct ResourceID: Codable { let id: String? }
        struct RefID: Codable { let data: ResourceID? }
        struct Refs: Codable {
            let subscriptionPricePoint: RefID?
            let territory: RefID?
        }
        let relationships: Refs?
    }

    struct Included: Codable {
        let type: String?
        let id: String
        // Union of subscriptionPricePoint {customerPrice, proceeds} and
        // territory {currency} attributes — irrelevant keys stay nil.
        let attributes: Attributes?

        struct Attributes: Codable {
            let customerPrice: FlexiblePrice?
            let proceeds: String?
            let currency: String?
        }
    }

    let data: [Item]?
    let included: [Included]?

    /// Territory code → customer price amount for this subscription.
    func pricesByTerritory() -> [String: FlexiblePrice] {
        var pricePoints: [String: FlexiblePrice] = [:]
        var territoryByPricePoint: [String: String] = [:]
        var currencies: [String: String] = [:]

        for inc in included ?? [] {
            if inc.type == "subscriptionPricePoints" {
                pricePoints[inc.id] = inc.attributes?.customerPrice
            } else if inc.type == "territories" {
                currencies[inc.id] = inc.attributes?.currency
            }
        }
        for item in data ?? [] {
            guard let ppID = item.relationships?.subscriptionPricePoint?.data?.id,
                  let territoryID = item.relationships?.territory?.data?.id else { continue }
            territoryByPricePoint[ppID] = territoryID
        }

        var result: [String: FlexiblePrice] = [:]
        for (ppID, territoryID) in territoryByPricePoint {
            guard let price = pricePoints[ppID] else { continue }
            let withCurrency = FlexiblePrice(amount: price.amount,
                                             currency: price.currency ?? currencies[territoryID])
            result[territoryID] = withCurrency
        }
        return result
    }
}

/// Non-subscription IAP price points (`/v2/inAppPurchasesV2/{id}/pricePoints`).
/// Could not be verified against a live IAP (this account has none), so both
/// plausible response shapes are tolerated: territory as a relationship on
/// each item, or omitted entirely.
struct ASCIAPPricePointsResponse: Codable {
    struct ResourceID: Codable { let id: String? }
    struct RefID: Codable { let data: ResourceID? }
    struct PricePointAttributes: Codable {
        let customerPrice: FlexiblePrice?
        let proceeds: String?
    }
    struct Item: Codable {
        struct Refs: Codable { let territory: RefID? }
        let attributes: PricePointAttributes?
        let relationships: Refs?
    }
    let data: [Item]?

    func pricesByTerritory() -> [String: FlexiblePrice] {
        var result: [String: FlexiblePrice] = [:]
        for item in data ?? [] {
            guard let price = item.attributes?.customerPrice else { continue }
            let territory = item.relationships?.territory?.data?.id ?? ""
            result[territory] = price
        }
        return result
    }
}
