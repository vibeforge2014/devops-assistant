import Foundation
import XCTest

/// Parsing against fixture JSON mirroring the live response shapes captured
/// on 2026-08-16 (iTunes lookup + ASC subscription prices).
final class AppStoreInfoParsingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - iTunes lookup

    func testParsesLiveITunesLookup() throws {
        // Real response (Dropbox, CN storefront) trimmed to relevant fields.
        let json = """
        {
          "resultCount": 1,
          "results": [{
            "trackName": "Dropbox：备份、同步和共享",
            "formattedPrice": "免费",
            "price": 0.0,
            "currency": "CNY",
            "version": "486.2",
            "averageUserRating": 4.6547,
            "userRatingCount": 2172,
            "trackViewUrl": "https://apps.apple.com/cn/app/id327630330"
          }]
        }
        """
        let decoded = try decode(ITunesLookupResponse.self, json)
        XCTAssertEqual(decoded.resultCount, 1)
        let app = try XCTUnwrap(decoded.results?.first)
        XCTAssertEqual(app.formattedPrice, "免费")
        XCTAssertEqual(app.currency, "CNY")
        XCTAssertEqual(app.version, "486.2")
        XCTAssertEqual(app.userRatingCount, 2172)
        XCTAssertEqual(app.averageUserRating ?? 0, 4.6547, accuracy: 0.0001)
    }

    func testITunesNotFoundIsEmpty() throws {
        let json = """
        {"resultCount": 0, "results": []}
        """
        let decoded = try decode(ITunesLookupResponse.self, json)
        XCTAssertEqual(decoded.resultCount, 0)
        XCTAssertNil(decoded.results?.first)
    }

    // MARK: - ASC apps / IAP list

    func testParsesASCAppsList() throws {
        let json = """
        {"data": [{"type": "apps", "id": "6794545737",
                   "attributes": {"bundleId": "com.servercat.app", "name": "ServerHub - SSH 工具箱"}}]}
        """
        let decoded = try decode(ASCListResponse<ASCAppAttributes>.self, json)
        let app = try XCTUnwrap(decoded.data?.first)
        XCTAssertEqual(app.id, "6794545737")
        XCTAssertEqual(app.attributes?.bundleId, "com.servercat.app")
    }

    func testParsesIAPListWithMissingAttributes() throws {
        let json = """
        {"data": [
          {"type": "inAppPurchases", "id": "123",
           "attributes": {"name": "Pro", "productId": "com.x.pro",
                          "type": "NON_CONSUMABLE", "state": "APPROVED"}},
          {"type": "inAppPurchases", "id": "456", "attributes": {"state": "READY_FOR_REVIEW"}}
        ]}
        """
        let decoded = try decode(ASCListResponse<ASCIAPAttributes>.self, json)
        XCTAssertEqual(decoded.data?.count, 2)
        let first = decoded.data![0]
        XCTAssertEqual(IAPKind(rawValue: first.attributes?.type ?? "").displayName, "非消耗型")
        // Missing name falls back through productId at the call site; parse
        // itself must not throw.
        XCTAssertNil(decoded.data![1].attributes?.name)
    }

    // MARK: - Subscription prices (compound include)

    func testParsesSubscriptionPricesAndMapsTerritories() throws {
        // Shape captured live: data items link a pricePoint + a territory,
        // both expanded in included. Ids are opaque base64 — real ones here.
        let json = """
        {
          "data": [
            {"type": "subscriptionPrices", "id": "price-cn",
             "relationships": {
               "subscriptionPricePoint": {"data": {"type": "subscriptionPricePoints", "id": "pp-cn"}},
               "territory": {"data": {"type": "territories", "id": "CHN"}}}},
            {"type": "subscriptionPrices", "id": "price-us",
             "relationships": {
               "subscriptionPricePoint": {"data": {"type": "subscriptionPricePoints", "id": "pp-us"}},
               "territory": {"data": {"type": "territories", "id": "USA"}}}}
          ],
          "included": [
            {"type": "subscriptionPricePoints", "id": "pp-cn",
             "attributes": {"customerPrice": "8.00", "proceeds": "5.60"}},
            {"type": "subscriptionPricePoints", "id": "pp-us",
             "attributes": {"customerPrice": "1.29", "proceeds": "0.95"}},
            {"type": "territories", "id": "CHN", "attributes": {"currency": "CNY"}},
            {"type": "territories", "id": "USA", "attributes": {"currency": "USD"}}
          ]
        }
        """
        let decoded = try decode(ASCSubscriptionPricesResponse.self, json)
        let prices = decoded.pricesByTerritory()
        XCTAssertEqual(prices["CHN"]?.amount, "8.00")
        XCTAssertEqual(prices["CHN"]?.currency, "CNY")
        XCTAssertEqual(prices["USA"]?.amount, "1.29")
        XCTAssertEqual(prices["USA"]?.currency, "USD")
    }

    func testFlexiblePriceAcceptsObjectShape() throws {
        // Unverified endpoint variant: customerPrice as an object.
        let json = """
        {"data": [{"id": "1", "attributes": {"customerPrice": {"amount": "3.99", "currency": "USD"}}}]}
        """
        let decoded = try decode(ASCIAPPricePointsResponse.self, json)
        XCTAssertEqual(decoded.data?.first?.attributes?.customerPrice?.amount, "3.99")
        XCTAssertEqual(decoded.data?.first?.attributes?.customerPrice?.currency, "USD")
        // No territory relationship → keyed under "", picked up for display.
        XCTAssertEqual(decoded.pricesByTerritory()[""]?.amount, "3.99")
    }

    // MARK: - Display mapping

    func testTerritoryPriceDisplayLabels() {
        let cnRaw = TerritoryPrice(territory: "CHN", formatted: "8.00", currency: "CNY")
        XCTAssertEqual(cnRaw.displayLabel, "中国区 ¥8.00")
        let cnFormatted = TerritoryPrice(territory: "CHN", formatted: "¥6.00", currency: "CNY")
        XCTAssertEqual(cnFormatted.displayLabel, "中国区 ¥6.00")
        let us = TerritoryPrice(territory: "USA", formatted: "1.29", currency: "USD")
        XCTAssertEqual(us.displayLabel, "美区 $1.29")
        let free = TerritoryPrice(territory: "CHN", formatted: "免费", currency: nil)
        XCTAssertEqual(free.displayLabel, "中国区 免费")
        let unknown = TerritoryPrice(territory: "ZZZ", formatted: "9.99", currency: nil)
        XCTAssertEqual(unknown.displayLabel, "9.99")
    }

    func testIAPStateLabels() {
        XCTAssertEqual(IAPStateInfo.label(for: "APPROVED"), "已上架")
        XCTAssertEqual(IAPStateInfo.label(for: "REJECTED"), "已拒绝")
        XCTAssertEqual(IAPStateInfo.label(for: "SOMETHING_NEW"), "SOMETHING_NEW")
        XCTAssertTrue(IAPStateInfo.isLive("APPROVED"))
        XCTAssertTrue(IAPStateInfo.isProblem("DELETED"))
        XCTAssertFalse(IAPStateInfo.isProblem("IN_REVIEW"))
    }

    func testIAPInfoPriceSummaryAndPeriod() {
        let monthly = IAPInfo(
            id: "1", name: "月度", productId: "com.x.month", kind: .autoRenewable,
            state: "APPROVED", period: "ONE_MONTH",
            prices: [TerritoryPrice(territory: "CHN", formatted: "8.00", currency: "CNY"),
                     TerritoryPrice(territory: "USA", formatted: "1.29", currency: "USD")])
        XCTAssertEqual(monthly.periodLabel, "每月")
        XCTAssertEqual(monthly.priceSummary, "中国区 ¥8.00 · 美区 $1.29")
        XCTAssertEqual(IAPInfo(id: "2", name: "x", productId: "p", kind: .nonConsumable,
                               state: "APPROVED", period: nil, prices: []).priceSummary, "未设价")
    }
}

/// The keychain value has been observed stored hex-encoded; normalization
/// must recover a loadable PEM while passing normal PEM through untouched.
final class TemporaryAPIKeyNormalizationTests: XCTestCase {
    func testHexEncodedPEMIsDecoded() {
        let pem = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG...\n-----END PRIVATE KEY-----\n"
        let hex = pem.data(using: .utf8)!.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(TemporaryAPIKey.normalizedPEM(hex),
                       pem.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
    }

    func testPlainPEMPassesThrough() {
        let pem = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"
        XCTAssertEqual(TemporaryAPIKey.normalizedPEM(pem + "\n\n"),
                       pem + "\n")
    }

    func testGarbagePassesThroughUnchanged() {
        let junk = "not-a-key"
        XCTAssertEqual(TemporaryAPIKey.normalizedPEM(junk), junk)
        // Odd-length hex is not decodable — returned as-is.
        XCTAssertEqual(TemporaryAPIKey.normalizedPEM("2d2d2"), "2d2d2")
    }

    func testHexThatDoesNotDecodeToPEMPassesThrough() {
        let hex = "deadbeef"
        XCTAssertEqual(TemporaryAPIKey.normalizedPEM(hex), hex)
    }
}
