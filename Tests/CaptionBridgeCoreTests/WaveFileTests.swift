import XCTest
@testable import CaptionBridgeCore

final class WaveFileTests: XCTestCase {
    func testWritesPCM16WaveHeader() throws {
        let chunk = PCMAudioChunk(samples: [0, 1, -1], sampleRate: 16_000)
        let data = try WaveFile.pcm16Data(from: chunk)

        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(data.count, 44 + 6)
    }
}

