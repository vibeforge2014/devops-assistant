import XCTest

final class OnboardingServiceTests: XCTestCase {
    func testExtractsTeamIDWithParentheses() {
        XCTAssertEqual(OnboardingService.extractTeamID(from: #"team_id("LPW4Z3BN69")"#),
                       "LPW4Z3BN69")
    }

    func testExtractsTeamIDWithoutParentheses() {
        XCTAssertEqual(OnboardingService.extractTeamID(from: #"team_id "ABC1234XYZ""#),
                       "ABC1234XYZ")
    }

    func testRejectsInvalidTeamID() {
        XCTAssertNil(OnboardingService.extractTeamID(from: #"team_id("SHORT")"#))
    }
}
