import XCTest

final class ReleaseCapabilityTests: XCTestCase {
    func testFastlaneIOSExposesConfiguredUploadTargets() {
        let app = makeApp(platform: .ios,
                          release: ReleaseConfig(engine: .fastlane,
                                                 betaLane: "beta",
                                                 releaseLane: "release",
                                                 signing: .match))
        XCTAssertEqual(ReleaseTarget.available(for: app), [.testFlight, .appStore])
    }

    func testNativeIOSUsesBuiltInTestFlightFallback() {
        let app = makeApp(platform: .ios,
                          release: ReleaseConfig(engine: .native, signing: .manual))
        XCTAssertEqual(ReleaseTarget.available(for: app), [.testFlight])
    }

    func testNotarizedMacOnlyExposesMacDistribution() {
        let app = makeApp(platform: .macos,
                          release: ReleaseConfig(engine: .native,
                                                 signing: .developerID,
                                                 notarize: true))
        XCTAssertEqual(ReleaseTarget.available(for: app), [.macDistribution])
    }

    private func makeApp(platform: AppPlatform, release: ReleaseConfig) -> AppProject {
        AppProject(id: "fixture", name: "Fixture", path: "/tmp/fixture",
                   platform: platform, scheme: "Fixture", bundleId: "test.fixture",
                   versionSource: .projectYml, release: release)
    }
}
