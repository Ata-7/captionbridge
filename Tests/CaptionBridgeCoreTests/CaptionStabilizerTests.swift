import XCTest
@testable import CaptionBridgeCore

final class CaptionStabilizerTests: XCTestCase {
    func testFinalIsEmittedAndNormalized() {
        var stabilizer = CaptionStabilizer()

        let final = stabilizer.ingest(CaptionCandidate(text: "  We need   the report. ", isFinal: true))

        XCTAssertEqual(final?.kind, .final)
        XCTAssertEqual(final?.text, "We need the report.")
    }

    func testDuplicateFinalWithinWindowIsSuppressed() {
        var stabilizer = CaptionStabilizer(duplicateSuppressionWindow: 5)
        let now = Date()

        let first = stabilizer.ingest(CaptionCandidate(text: "Merci.", isFinal: true), at: now)
        let duplicate = stabilizer.ingest(CaptionCandidate(text: "Merci.", isFinal: true), at: now.addingTimeInterval(1))

        XCTAssertNotNil(first)
        XCTAssertNil(duplicate)
    }

    func testRepeatedSentenceAfterWindowIsShownAgain() {
        var stabilizer = CaptionStabilizer(duplicateSuppressionWindow: 5)
        let now = Date()

        let first = stabilizer.ingest(CaptionCandidate(text: "Merci.", isFinal: true), at: now)
        let laterRepeat = stabilizer.ingest(CaptionCandidate(text: "Merci.", isFinal: true), at: now.addingTimeInterval(30))

        XCTAssertNotNil(first)
        XCTAssertNotNil(laterRepeat)
        XCTAssertEqual(laterRepeat?.text, "Merci.")
    }

    func testRepeatedSentenceWithDistinctAudioRangeIsShownImmediately() {
        var stabilizer = CaptionStabilizer(duplicateSuppressionWindow: 5)
        let now = Date()

        let first = stabilizer.ingest(
            CaptionCandidate(text: "Merci.", isFinal: true, startTime: 10, endTime: 11),
            at: now
        )
        let separateUtterance = stabilizer.ingest(
            CaptionCandidate(text: "Merci.", isFinal: true, startTime: 12, endTime: 13),
            at: now.addingTimeInterval(1)
        )

        XCTAssertNotNil(first)
        XCTAssertNotNil(separateUtterance)
    }

    func testNonFinalCandidatesAreIgnored() {
        var stabilizer = CaptionStabilizer()

        XCTAssertNil(stabilizer.ingest(CaptionCandidate(text: "We need", isFinal: false)))
    }

    func testClearReturnsClearedEventAndResetsDedup() {
        var stabilizer = CaptionStabilizer()
        let now = Date()

        _ = stabilizer.ingest(CaptionCandidate(text: "Bonjour.", isFinal: true), at: now)
        XCTAssertEqual(stabilizer.clear().kind, .cleared)

        let afterClear = stabilizer.ingest(CaptionCandidate(text: "Bonjour.", isFinal: true), at: now.addingTimeInterval(0.1))
        XCTAssertNotNil(afterClear)
    }
}
