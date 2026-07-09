import XCTest
@testable import CaptionBridgeCore

final class RingBufferTests: XCTestCase {
    func testRingBufferKeepsMostRecentSamples() {
        let buffer = FloatRingBuffer(capacity: 4)

        buffer.append([1, 2, 3])
        buffer.append([4, 5, 6])

        XCTAssertEqual(buffer.count, 4)
        XCTAssertEqual(buffer.suffix(4), [3, 4, 5, 6])
        XCTAssertEqual(buffer.suffix(2), [5, 6])
    }

    func testAppendReportsDroppedCount() {
        let buffer = FloatRingBuffer(capacity: 4)

        XCTAssertEqual(buffer.append([1, 2, 3]), 0)
        XCTAssertEqual(buffer.append([4, 5]), 1)
        XCTAssertEqual(buffer.append([6, 7, 8, 9, 10, 11]), 6)
        XCTAssertEqual(buffer.suffix(4), [8, 9, 10, 11])
    }

    func testRemoveFirstAdvancesAcrossWrapBoundary() {
        let buffer = FloatRingBuffer(capacity: 4)

        buffer.append([1, 2, 3, 4])
        buffer.removeFirst(2)
        buffer.append([5, 6])

        XCTAssertEqual(buffer.count, 4)
        XCTAssertEqual(buffer.suffix(4), [3, 4, 5, 6])

        buffer.removeFirst(3)
        XCTAssertEqual(buffer.suffix(4), [6])
    }

    func testSuffixRMSMatchesCopyingPath() {
        let buffer = FloatRingBuffer(capacity: 8)
        buffer.append([0.5, -0.5, 0.5, -0.5, 0.1, 0.1])
        buffer.removeFirst(2)
        buffer.append([0.2, 0.2, 0.2, 0.2])

        let copied = buffer.suffix(6)
        XCTAssertEqual(buffer.suffixRMS(6), AudioProcessing.rms(copied), accuracy: 0.0001)
    }

    func testDrainClearsBuffer() {
        let buffer = FloatRingBuffer(capacity: 4)
        buffer.append([1, 2])

        XCTAssertEqual(buffer.drain(), [1, 2])
        XCTAssertEqual(buffer.count, 0)
    }
}
