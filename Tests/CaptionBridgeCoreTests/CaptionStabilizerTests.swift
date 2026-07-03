import XCTest
@testable import CaptionBridgeCore

final class CaptionStabilizerTests: XCTestCase {
    func testDraftsOnlyEmitWhenTextChanges() {
        var stabilizer = CaptionStabilizer()

        let first = stabilizer.ingest(CaptionCandidate(text: " We need ", isFinal: false))
        let duplicate = stabilizer.ingest(CaptionCandidate(text: "We need", isFinal: false))
        let changed = stabilizer.ingest(CaptionCandidate(text: "We need the report", isFinal: false))

        XCTAssertEqual(first?.kind, .draft)
        XCTAssertNil(duplicate)
        XCTAssertEqual(changed?.text, "We need the report")
    }

    func testFinalClearsDraftAndSuppressesDuplicateFinal() {
        var stabilizer = CaptionStabilizer()

        _ = stabilizer.ingest(CaptionCandidate(text: "We need", isFinal: false))
        let final = stabilizer.ingest(CaptionCandidate(text: "We need the report.", isFinal: true))
        let duplicateFinal = stabilizer.ingest(CaptionCandidate(text: "We need the report.", isFinal: true))
        let newDraft = stabilizer.ingest(CaptionCandidate(text: "Before Friday", isFinal: false))

        XCTAssertEqual(final?.kind, .final)
        XCTAssertNil(duplicateFinal)
        XCTAssertEqual(newDraft?.kind, .draft)
    }

    func testFinalPrefersRecentDraftOverShortOverlappingFragment() {
        var stabilizer = CaptionStabilizer()

        _ = stabilizer.ingest(CaptionCandidate(text: "We must finish the report before Friday.", isFinal: false))
        let final = stabilizer.ingest(CaptionCandidate(text: "and finalize the report before Friday.", isFinal: true))

        XCTAssertEqual(final?.kind, .final)
        XCTAssertEqual(final?.text, "We must finish the report before Friday.")
    }

    func testClearReturnsClearedEvent() {
        var stabilizer = CaptionStabilizer()
        _ = stabilizer.ingest(CaptionCandidate(text: "Bonjour", isFinal: false))

        XCTAssertEqual(stabilizer.clear().kind, .cleared)
    }
}
