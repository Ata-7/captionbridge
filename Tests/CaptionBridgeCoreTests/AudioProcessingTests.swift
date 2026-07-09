import XCTest
@testable import CaptionBridgeCore

final class AudioProcessingTests: XCTestCase {
    func testRMSMatchesHandComputedValue() {
        let samples: [Float] = [0.5, -0.5, 0.5, -0.5]

        XCTAssertEqual(AudioProcessing.rms(samples), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AudioProcessing.rms([]), 0)
    }

    func testSilenceGateRejectsQuietChunks() {
        let gate = SilenceGate(rmsThreshold: 0.01, minimumSpeechDuration: 0.2)
        let chunk = PCMAudioChunk(samples: Array(repeating: 0.001, count: 16_000), sampleRate: 16_000)

        XCTAssertFalse(gate.isSpeech(chunk))
    }

    func testSilenceGateAcceptsSpeechLikeChunks() {
        let gate = SilenceGate(rmsThreshold: 0.01, minimumSpeechDuration: 0.2)
        let chunk = PCMAudioChunk(samples: Array(repeating: 0.05, count: 16_000), sampleRate: 16_000)

        XCTAssertTrue(gate.isSpeech(chunk))
    }

    func testSilenceGateRMSOverloadMatchesChunkPath() {
        let gate = SilenceGate(rmsThreshold: 0.01, minimumSpeechDuration: 0.2)

        XCTAssertTrue(gate.isSpeech(rms: 0.05, duration: 1))
        XCTAssertFalse(gate.isSpeech(rms: 0.001, duration: 1))
        XCTAssertFalse(gate.isSpeech(rms: 0.05, duration: 0.1))
    }
}
