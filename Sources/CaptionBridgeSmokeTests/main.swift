import CaptionBridgeCore
import Foundation

@main
struct CaptionBridgeSmokeTests {
    static func main() throws {
        try testPrivacyDefaults()
        try testAudioProcessing()
        try testRingBuffer()
        try testCaptionStabilizer()
        try testWaveFile()
        print("CaptionBridge smoke tests passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw SmokeTestError.failed(message)
        }
    }

    private static func testPrivacyDefaults() throws {
        let settings = AppSettings()
        try require(settings.privacyMode == .onDeviceOnly, "privacy mode should default to local only")
        try require(settings.transcriptEnabled == false, "transcript should be off by default")
        try require(settings.analyticsEnabled == false, "analytics should be off by default")
        try require(settings.cloudInferenceEnabled == false, "cloud inference should be off by default")
    }

    private static func testAudioProcessing() throws {
        let mono = AudioProcessing.downmixToMono(interleaved: [1, -1, 0.5, 0.25], channelCount: 2)
        try require(mono == [0, 0.375], "stereo downmix should average channels")

        let resampled = AudioProcessing.resampleLinear(samples: Array(repeating: 0.5, count: 48_000), from: 48_000, to: 16_000)
        try require(resampled.count == 16_000, "48 kHz to 16 kHz resampling should reduce sample count")

        let gate = SilenceGate(rmsThreshold: 0.01, minimumSpeechDuration: 0.2)
        try require(gate.isSpeech(PCMAudioChunk(samples: Array(repeating: 0.05, count: 16_000))), "speech-like chunk should pass gate")
        try require(!gate.isSpeech(PCMAudioChunk(samples: Array(repeating: 0.001, count: 16_000))), "quiet chunk should fail gate")
    }

    private static func testRingBuffer() throws {
        let buffer = FloatRingBuffer(capacity: 4)
        buffer.append([1, 2, 3])
        buffer.append([4, 5, 6])

        try require(buffer.suffix(4) == [3, 4, 5, 6], "ring buffer should keep newest samples")
        try require(buffer.drain() == [3, 4, 5, 6], "drain should return current samples")
        try require(buffer.count == 0, "drain should clear the buffer")
    }

    private static func testCaptionStabilizer() throws {
        var stabilizer = CaptionStabilizer()

        let draft = stabilizer.ingest(CaptionCandidate(text: " We need ", isFinal: false))
        let duplicateDraft = stabilizer.ingest(CaptionCandidate(text: "We need", isFinal: false))
        let final = stabilizer.ingest(CaptionCandidate(text: "We need the report.", isFinal: true))

        try require(draft?.kind == .draft, "first partial text should emit draft")
        try require(duplicateDraft == nil, "duplicate draft should be suppressed")
        try require(final?.kind == .final, "final text should emit final event")
        try require(stabilizer.clear().kind == .cleared, "clear should emit cleared event")
    }

    private static func testWaveFile() throws {
        let data = try WaveFile.pcm16Data(from: PCMAudioChunk(samples: [0, 1, -1], sampleRate: 16_000))
        try require(String(data: data[0..<4], encoding: .ascii) == "RIFF", "WAV should start with RIFF")
        try require(String(data: data[8..<12], encoding: .ascii) == "WAVE", "WAV should contain WAVE marker")
        try require(data.count == 50, "WAV data size should match 3 PCM16 samples")
    }
}

enum SmokeTestError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}
