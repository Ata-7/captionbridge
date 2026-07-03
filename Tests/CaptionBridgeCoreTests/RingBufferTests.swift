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

    func testDrainClearsBuffer() {
        let buffer = FloatRingBuffer(capacity: 4)
        buffer.append([1, 2])

        XCTAssertEqual(buffer.drain(), [1, 2])
        XCTAssertEqual(buffer.count, 0)
    }
}

