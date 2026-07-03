import XCTest
@testable import CaptionBridgeCore

final class SubtitleHistoryBufferTests: XCTestCase {
    func testKeepsThreeMostRecentFinalCaptions() {
        var buffer = SubtitleHistoryBuffer(maximumVisibleFinalCaptions: 3)
        let now = Date()

        buffer.appendFinal(.final("First sentence.", at: now))
        buffer.appendFinal(.final("Second sentence.", at: now.addingTimeInterval(1)))
        buffer.appendFinal(.final("Third sentence.", at: now.addingTimeInterval(2)))
        buffer.appendFinal(.final("Fourth sentence.", at: now.addingTimeInterval(3)))

        XCTAssertEqual(buffer.items.map(\.text), [
            "Second sentence.",
            "Third sentence.",
            "Fourth sentence."
        ])
    }

    func testClearRemovesVisibleFinalCaptions() {
        var buffer = SubtitleHistoryBuffer(maximumVisibleFinalCaptions: 3)
        buffer.appendFinal(.final("A caption."))

        buffer.clear()

        XCTAssertTrue(buffer.items.isEmpty)
    }

    func testSuppressesImmediateDuplicateButAllowsLaterRepeat() {
        var buffer = SubtitleHistoryBuffer(maximumVisibleFinalCaptions: 3)
        let now = Date()

        buffer.appendFinal(.final("Yes.", at: now))
        buffer.appendFinal(.final("Yes.", at: now.addingTimeInterval(0.2)))
        buffer.appendFinal(.final("Yes.", at: now.addingTimeInterval(2.0)))

        XCTAssertEqual(buffer.items.map(\.text), ["Yes.", "Yes."])
    }
}
