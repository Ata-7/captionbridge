import XCTest
@testable import CaptionBridgeCore

final class AudioProcessingTests: XCTestCase {
    func testDownmixStereoToMonoAveragesFrames() {
        let stereo: [Float] = [
            1, -1,
            0.5, 0.25,
            -0.25, -0.75
        ]

        XCTAssertEqual(
            AudioProcessing.downmixToMono(interleaved: stereo, channelCount: 2),
            [0, 0.375, -0.5]
        )
    }

    func testResampleLinearReducesSampleCount() {
        let samples = Array(repeating: Float(0.5), count: 48_000)
        let resampled = AudioProcessing.resampleLinear(samples: samples, from: 48_000, to: 16_000)

        XCTAssertEqual(resampled.count, 16_000)
        XCTAssertEqual(resampled.first, 0.5)
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
}

