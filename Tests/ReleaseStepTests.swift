import XCTest

/// The step-skipping math behind "从失败步骤重试": everything that already
/// succeeded stays skipped (including setVersion — the build number must not
/// be bumped twice), and pipeline order is preserved.
final class ReleaseStepTests: XCTestCase {
    func testSkipsCompletedStepsInOrder() {
        let steps: [ReleaseStep] = [.setVersion, .build, .sign, .uploadRelease, .updatePages]
        let remaining = steps.excludingCompleted([.setVersion, .build])
        XCTAssertEqual(remaining, [.sign, .uploadRelease, .updatePages])
    }

    func testNothingCompletedReturnsAllSteps() {
        let steps: [ReleaseStep] = [.setVersion, .uploadBeta, .updatePages]
        XCTAssertEqual(steps.excludingCompleted([]), steps)
    }

    func testFailureAtFirstStepRedoesEverything() {
        let steps: [ReleaseStep] = [.setVersion, .build, .sign, .notarize, .updatePages]
        XCTAssertEqual(steps.excludingCompleted([]), steps)
    }

    func testSetVersionIsSkippedWhenItSucceeded() {
        // The double-bump regression this guards against: a run that failed
        // at notarize must resume at notarize, NOT re-run setVersion.
        let steps: [ReleaseStep] = [.setVersion, .build, .sign, .notarize, .updatePages]
        let remaining = steps.excludingCompleted([.setVersion, .build, .sign])
        XCTAssertEqual(remaining, [.notarize, .updatePages])
        XCTAssertFalse(remaining.contains(.setVersion))
    }
}
