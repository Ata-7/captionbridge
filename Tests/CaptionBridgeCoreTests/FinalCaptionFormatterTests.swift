import XCTest
@testable import CaptionBridgeCore

final class FinalCaptionFormatterTests: XCTestCase {
    func testForcedCaptionWithoutSentenceEndingGetsContinuationMarks() {
        var formatter = FinalCaptionFormatter()

        let first = formatter.format(.final("The team can finish the preparation"), wasForced: true)
        let second = formatter.format(.final("today if the technical questions arrive."), wasForced: false)

        XCTAssertEqual(first.text, "The team can finish the preparation...")
        XCTAssertEqual(second.text, "... today if the technical questions arrive.")
    }

    func testNaturalFinalCaptionDoesNotGetContinuationMarks() {
        var formatter = FinalCaptionFormatter()

        let event = formatter.format(.final("The meeting starts now."), wasForced: false)

        XCTAssertEqual(event.text, "The meeting starts now.")
    }

    func testClearStopsCarryingContinuationForward() {
        var formatter = FinalCaptionFormatter()

        _ = formatter.format(.final("The client asks for a clear answer"), wasForced: true)
        formatter.clear()
        let event = formatter.format(.final("The meeting continues."), wasForced: false)

        XCTAssertEqual(event.text, "The meeting continues.")
    }
}
