import Foundation
import XCTest
@testable import CaptionBridgeCore

final class PersistentWhisperTranslationEngineTests: XCTestCase {
    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptionBridgeHelperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    func testQueuedRequestGetsItsOwnDeadlineAfterSlowRequest() async throws {
        let helperURL = workDirectory.appendingPathComponent("captionbridge-whisper-helper")
        let script = """
        #!/usr/bin/python3
        import sys
        import time

        request_count = 0
        while True:
            line = sys.stdin.buffer.readline()
            if not line:
                break
            parts = line.decode("utf-8").strip().split()
            request_id = parts[1]
            model_length = int(parts[2])
            sample_count = int(parts[5])
            sys.stdin.buffer.read(model_length + sample_count * 4)

            request_count += 1
            if request_count == 1:
                time.sleep(1.0)

            payload = b"Bonjour tout le monde"
            sys.stdout.buffer.write(
                f"OK {request_id} 1 {len(payload)}\\n".encode("utf-8") + payload + b"\\n"
            )
            sys.stdout.buffer.flush()
        """
        try Data(script.utf8).write(to: helperURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

        let descriptor = ModelDescriptor(
            id: "test",
            displayName: "Test",
            fileName: "test.bin",
            downloadURL: URL(fileURLWithPath: "/dev/null"),
            minimumFileSizeBytes: 1,
            qualityTier: .fastest
        )
        let model = InstalledModel(
            descriptor: descriptor,
            localURL: workDirectory.appendingPathComponent("test.bin")
        )
        let locator = WhisperHelperLocator(explicitPath: helperURL.path)
        let engine = PersistentWhisperTranslationEngine(
            locator: locator,
            draftTimeoutSeconds: 0.3,
            finalTimeoutSeconds: 1,
            coldStartExtraSeconds: 0,
            stallKillInterval: 2,
            stallCheckInterval: 0.05
        )
        let chunk = PCMAudioChunk(
            samples: Array(repeating: 0.1, count: 1_600),
            sampleRate: 16_000
        )

        do {
            _ = try await engine.transcribe(
                audio: chunk,
                model: model,
                languagePair: .frenchToEnglish
            )
            XCTFail("Expected the intentionally slow first request to time out")
        } catch let error as WhisperEngineError {
            guard case .timedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let recovered = try await engine.transcribe(
            audio: chunk,
            model: model,
            languagePair: .frenchToEnglish
        )
        XCTAssertEqual(recovered.text, "Bonjour tout le monde")
    }

    func testWatchdogTerminatesHelperThatStopsMakingProgress() async throws {
        let helperURL = workDirectory.appendingPathComponent("captionbridge-whisper-helper")
        let terminatedURL = workDirectory.appendingPathComponent("terminated")
        let script = """
        #!/usr/bin/python3
        import signal
        import sys
        import time

        terminated = \(String(reflecting: terminatedURL.path))
        def handle_term(signum, frame):
            open(terminated, "w").close()
            sys.exit(0)
        signal.signal(signal.SIGTERM, handle_term)

        line = sys.stdin.buffer.readline()
        if line:
            parts = line.decode("utf-8").strip().split()
            model_length = int(parts[2])
            sample_count = int(parts[5])
            sys.stdin.buffer.read(model_length + sample_count * 4)
            while True:
                time.sleep(60)
        """
        try Data(script.utf8).write(to: helperURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

        let descriptor = ModelDescriptor(
            id: "test",
            displayName: "Test",
            fileName: "test.bin",
            downloadURL: URL(fileURLWithPath: "/dev/null"),
            minimumFileSizeBytes: 1,
            qualityTier: .fastest
        )
        let model = InstalledModel(
            descriptor: descriptor,
            localURL: workDirectory.appendingPathComponent("test.bin")
        )
        let engine = PersistentWhisperTranslationEngine(
            locator: WhisperHelperLocator(explicitPath: helperURL.path),
            draftTimeoutSeconds: 1,
            finalTimeoutSeconds: 1,
            coldStartExtraSeconds: 0,
            stallKillInterval: 1.2,
            stallCheckInterval: 0.05
        )
        let chunk = PCMAudioChunk(
            samples: Array(repeating: 0.1, count: 1_600),
            sampleRate: 16_000
        )

        do {
            _ = try await engine.transcribe(
                audio: chunk,
                model: model,
                languagePair: .frenchToEnglish
            )
            XCTFail("Expected the intentionally hung request to time out")
        } catch let error as WhisperEngineError {
            guard case .timedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: terminatedURL.path))
    }
}
