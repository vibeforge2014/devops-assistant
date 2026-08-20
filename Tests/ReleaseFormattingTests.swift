import XCTest

/// The wizard's "将发布" preview and duration labels are derived state — these
/// tests pin the exact semantics the release pipeline applies on disk, so the
/// preview can never promise a different version than setVersion would write.
final class ReleaseFormattingTests: XCTestCase {

    // MARK: - duration

    func testDurationUnderAMinuteShowsTenths() {
        XCTAssertEqual(ReleaseFormatting.duration(0), "0.0s")
        XCTAssertEqual(ReleaseFormatting.duration(12.34), "12.3s")
        XCTAssertEqual(ReleaseFormatting.duration(59.94), "59.9s")
    }

    func testDurationNegativeClampsToZero() {
        XCTAssertEqual(ReleaseFormatting.duration(-5), "0.0s")
    }

    func testDurationMinutesAndHours() {
        XCTAssertEqual(ReleaseFormatting.duration(60), "1m 00s")
        XCTAssertEqual(ReleaseFormatting.duration(125), "2m 05s")
        XCTAssertEqual(ReleaseFormatting.duration(3599), "59m 59s")
        XCTAssertEqual(ReleaseFormatting.duration(3725), "1h 02m")
        XCTAssertEqual(ReleaseFormatting.duration(86_400), "24h 00m")
    }

    // MARK: - bumped

    func testBumpedIncrementsIntegerBuild() {
        let v = VersionPair(marketing: "1.2.3", build: "41")
        let next = ReleaseFormatting.bumped(v)
        XCTAssertEqual(next.marketing, "1.2.3")
        XCTAssertEqual(next.build, "42")
    }

    func testBumpedKeepsNonIntegerBuildAsIs() {
        // bumpBuild refuses non-integer builds and fails the step — the
        // preview must not pretend a bump happened.
        let v = VersionPair(marketing: "1.0.0", build: "beta")
        XCTAssertEqual(ReleaseFormatting.bumped(v), v)
    }

    // MARK: - resolvedVersion (what the run writes)

    func testBothFieldsEmptyMeansNoExplicitVersion() {
        XCTAssertNil(ReleaseFormatting.resolvedVersion(
            current: VersionPair(marketing: "1.2.3", build: "41"),
            marketing: "", build: ""))
        XCTAssertNil(ReleaseFormatting.resolvedVersion(
            current: nil, marketing: "", build: ""))
    }

    func testWhitespaceOnlyFieldsAreEmpty() {
        XCTAssertNil(ReleaseFormatting.resolvedVersion(
            current: VersionPair(marketing: "1.2.3", build: "41"),
            marketing: "  ", build: "\t"))
    }

    func testMarketingOnlyKeepsCurrentBuild() {
        // New marketing + same build is a valid ASC upload (e.g. 1.3.0 (42)
        // after 1.2.9 (42)); the pipeline deliberately does NOT bump here.
        let resolved = ReleaseFormatting.resolvedVersion(
            current: VersionPair(marketing: "1.2.9", build: "42"),
            marketing: "1.3.0", build: "")
        XCTAssertEqual(resolved, VersionPair(marketing: "1.3.0", build: "42"))
    }

    func testBuildOnlyKeepsCurrentMarketing() {
        let resolved = ReleaseFormatting.resolvedVersion(
            current: VersionPair(marketing: "1.2.9", build: "42"),
            marketing: "", build: "100")
        XCTAssertEqual(resolved, VersionPair(marketing: "1.2.9", build: "100"))
    }

    func testBothFieldsUsedVerbatim() {
        let resolved = ReleaseFormatting.resolvedVersion(
            current: VersionPair(marketing: "0.9.0", build: "7"),
            marketing: " 1.0.0 ", build: " 8 ")
        XCTAssertEqual(resolved, VersionPair(marketing: "1.0.0", build: "8"))
    }

    func testNoCurrentVersionFallsBackLikeThePipeline() {
        // Pipeline falls back to "" for marketing and "1" for build when the
        // project can't be read but explicit fields were given.
        XCTAssertEqual(
            ReleaseFormatting.resolvedVersion(current: nil, marketing: "2.0", build: ""),
            VersionPair(marketing: "2.0", build: "1"))
        XCTAssertEqual(
            ReleaseFormatting.resolvedVersion(current: nil, marketing: "", build: "9"),
            VersionPair(marketing: "", build: "9"))
    }

    // MARK: - previewVersion (what the wizard shows)

    func testPreviewDefaultsToBumpedBuild() {
        let preview = ReleaseFormatting.previewVersion(
            current: VersionPair(marketing: "1.2.3", build: "41"),
            marketing: "", build: "")
        XCTAssertEqual(preview, VersionPair(marketing: "1.2.3", build: "42"))
    }

    func testPreviewWithNoCurrentVersionAndNoFieldsIsHidden() {
        XCTAssertNil(ReleaseFormatting.previewVersion(
            current: nil, marketing: "", build: ""))
    }

    func testPreviewMirrorsResolvedVersionWhenFieldsGiven() {
        let preview = ReleaseFormatting.previewVersion(
            current: VersionPair(marketing: "1.2.9", build: "42"),
            marketing: "1.3.0", build: "")
        XCTAssertEqual(preview, VersionPair(marketing: "1.3.0", build: "42"))
    }
}
