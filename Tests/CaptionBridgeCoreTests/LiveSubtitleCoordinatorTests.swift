import Foundation
import XCTest
@testable import CaptionBridgeCore

final class LiveSubtitleCoordinatorTests: XCTestCase {
    private let sampleRate = 1_000
    private let shortChunkSampleCount = 50

    func testRepeatedShortSpeechChunksEventuallyEmitFinalCaption() async {
        let engine = StubSpeechTranslationEngine(
            result: SpeechTranslationResult(
                text: "The report is ready.",
                sourceText: "Le rapport est pret.",
                startTime: 1,
                endTime: 2,
                isFinal: true
            )
        )
        let coordinator = makeCoordinator(engine: engine)
        let events = CaptionEventRecorder()
        let model = testModel()

        for index in 0..<6 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0.05, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) }
            )
        }

        for index in 6..<18 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) }
            )
        }

        XCTAssertEqual(events.values.map(\.kind), [.speechStarted, .sourceDraft, .final])
        XCTAssertEqual(events.values.dropFirst().first?.text, "Le rapport est pret.")
        XCTAssertEqual(events.values.last?.text, "The report is ready.")
        XCTAssertEqual(events.values.last?.sourceText, "Le rapport est pret.")

        let translatedChunks = await engine.chunks()
        XCTAssertGreaterThanOrEqual(translatedChunks.count, 2)
        XCTAssertEqual(translatedChunks.first?.samples.count, 300)
        XCTAssertGreaterThanOrEqual(translatedChunks.first?.duration ?? 0, 0.3)
    }

    func testQuietShortChunksDoNotTranslateOrEmitCaptions() async {
        let engine = StubSpeechTranslationEngine(
            result: SpeechTranslationResult(text: "Should not be used.", isFinal: true)
        )
        let coordinator = makeCoordinator(engine: engine)
        let events = CaptionEventRecorder()
        let model = testModel()

        for index in 0..<10 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0.001, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) }
            )
        }

        XCTAssertTrue(events.values.isEmpty)

        let translatedChunks = await engine.chunks()
        XCTAssertTrue(translatedChunks.isEmpty)
    }

    func testRecentSpeechHoldAllowsFinalCaptionAfterInitialEmptyResult() async {
        let engine = SequencedSpeechTranslationEngine(
            outcomes: [
                .emptyResult,
                .result(
                    SpeechTranslationResult(
                        text: "We must finalize the report before Friday.",
                        isFinal: true
                    )
                )
            ]
        )
        let coordinator = LiveSubtitleCoordinator(
            engine: engine,
            silenceGate: SilenceGate(rmsThreshold: 0.01, minimumSpeechDuration: 0.2),
            sampleRate: sampleRate,
            windowDuration: 0.8,
            speechAnalysisDuration: 0.2,
            minimumInferenceDuration: 0.3,
            minimumProcessingInterval: 0.05,
            speechHoldDuration: 2,
            trailingSilenceDuration: 0.25
        )
        let events = CaptionEventRecorder()
        let model = testModel()

        for index in 0..<6 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0.05, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) }
            )
        }

        XCTAssertEqual(events.values.map(\.kind), [.speechStarted])

        for index in 6..<18 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) }
            )
        }

        try? await Task.sleep(nanoseconds: 70_000_000)
        await coordinator.handle(
            chunk: chunk(amplitude: 0, index: 18),
            model: model,
            languagePair: .frenchToEnglish,
            emit: { events.append($0) }
        )

        XCTAssertEqual(events.values.map(\.kind), [.speechStarted, .final])
        XCTAssertEqual(events.values.last?.text, "We must finalize the report before Friday.")

        let translatedChunks = await engine.chunks()
        XCTAssertEqual(translatedChunks.count, 2)
    }

    func testPostSpeechFinalStopsRetranslatingSameBufferIntoFragments() async {
        let engine = SequencedSpeechTranslationEngine(
            outcomes: [
                .result(SpeechTranslationResult(text: "We must finish the report before Friday.", isFinal: true)),
                .result(SpeechTranslationResult(text: "We must finish the report before Friday.", isFinal: true)),
                .result(SpeechTranslationResult(text: "before Friday.", isFinal: true))
            ]
        )
        let coordinator = LiveSubtitleCoordinator(
            engine: engine,
            silenceGate: SilenceGate(rmsThreshold: 0.01, minimumSpeechDuration: 0.2),
            sampleRate: sampleRate,
            windowDuration: 0.8,
            speechAnalysisDuration: 0.2,
            minimumInferenceDuration: 0.3,
            minimumProcessingInterval: 0.05,
            speechHoldDuration: 2,
            trailingSilenceDuration: 0.25
        )
        let events = CaptionEventRecorder()
        let model = testModel()

        for index in 0..<6 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0.05, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) }
            )
        }

        for index in 6..<18 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) }
            )
        }

        try? await Task.sleep(nanoseconds: 70_000_000)
        await coordinator.handle(
            chunk: chunk(amplitude: 0, index: 18),
            model: model,
            languagePair: .frenchToEnglish,
            emit: { events.append($0) }
        )

        try? await Task.sleep(nanoseconds: 70_000_000)
        await coordinator.handle(
            chunk: chunk(amplitude: 0, index: 19),
            model: model,
            languagePair: .frenchToEnglish,
            emit: { events.append($0) }
        )

        XCTAssertEqual(events.values.map(\.kind), [.speechStarted, .sourceDraft, .final])
        XCTAssertEqual(events.values.last?.text, "We must finish the report before Friday.")

        let translatedChunks = await engine.chunks()
        XCTAssertEqual(translatedChunks.count, 2)
    }

    func testFinalTimeoutKeepsAudioForRetry() async {
        let engine = FinalTimeoutSpeechTranslationEngine()
        let coordinator = LiveSubtitleCoordinator(
            engine: engine,
            silenceGate: SilenceGate(rmsThreshold: 0.01, minimumSpeechDuration: 0.01),
            sampleRate: sampleRate,
            windowDuration: 0.5,
            speechAnalysisDuration: 0.05,
            minimumInferenceDuration: 0.3,
            minimumProcessingInterval: 10,
            trailingSilenceDuration: 0.1
        )
        let events = CaptionEventRecorder()
        let statuses = CaptionStatusRecorder()
        let model = testModel()

        for index in 0..<6 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0.05, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) },
                status: { statuses.append($0) }
            )
        }

        for index in 6..<8 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) },
                status: { statuses.append($0) }
            )
        }

        XCTAssertFalse(events.values.contains { $0.kind == .final })
        XCTAssertTrue(statuses.values.contains("Still translating this sentence..."))

        await coordinator.handle(
            chunk: chunk(amplitude: 0, index: 8),
            model: model,
            languagePair: .frenchToEnglish,
            emit: { events.append($0) },
            status: { statuses.append($0) }
        )

        XCTAssertEqual(events.values.map(\.kind), [.speechStarted, .sourceDraft, .final])
        XCTAssertEqual(events.values.last?.text, "We must finalize the report.")

        let translatedChunks = await engine.chunks()
        XCTAssertEqual(translatedChunks.count, 2)
        if translatedChunks.count == 2 {
            XCTAssertGreaterThanOrEqual(translatedChunks[1].samples.count, translatedChunks[0].samples.count)
        }
    }

    func testFinalWithEllipsisSourceIsSuppressedAsHallucination() async {
        let engine = StubSpeechTranslationEngine(
            result: SpeechTranslationResult(
                text: "Little tech here.",
                sourceText: "...",
                isFinal: true
            )
        )
        let coordinator = makeCoordinator(engine: engine)
        let events = CaptionEventRecorder()
        let model = testModel()

        for index in 0..<6 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0.05, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) }
            )
        }

        for index in 6..<18 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) }
            )
        }

        XCTAssertFalse(events.values.contains { $0.kind == .final })
    }

    func testForcedContinuousFinalsShowContinuation() async {
        let engine = SequencedSpeechTranslationEngine(
            outcomes: [
                .result(SpeechTranslationResult(text: "The team can finish the preparation", isFinal: false)),
                .result(SpeechTranslationResult(text: "The team can finish the preparation", isFinal: true)),
                .result(SpeechTranslationResult(text: "today if technical questions arrive.", isFinal: true))
            ]
        )
        let coordinator = LiveSubtitleCoordinator(
            engine: engine,
            silenceGate: SilenceGate(rmsThreshold: 0.01, minimumSpeechDuration: 0.1),
            sampleRate: sampleRate,
            windowDuration: 0.5,
            speechAnalysisDuration: 0.1,
            minimumInferenceDuration: 0.25,
            minimumProcessingInterval: 10,
            maxUtteranceDuration: 0.5,
            trailingSilenceDuration: 0.2,
            maximumUtteranceDuration: 0.2
        )
        let events = CaptionEventRecorder()
        let model = testModel()

        for index in 0..<6 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0.05, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) }
            )
        }

        for index in 6..<12 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0.05, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) }
            )
        }

        for index in 12..<18 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) }
            )
        }

        let finalTexts = events.values
            .filter { $0.kind == .final }
            .map(\.text)

        XCTAssertEqual(finalTexts, [
            "The team can finish the preparation...",
            "... today if technical questions arrive."
        ])
    }

    func testSourceDraftsSuppressNonSpeechHallucinations() async {
        let engine = SequencedSpeechTranslationEngine(
            outcomes: [
                .result(SpeechTranslationResult(text: "*musique*", isFinal: false)),
                .result(SpeechTranslationResult(text: "Bonjour à tous", isFinal: false)),
                .result(SpeechTranslationResult(text: "Bonjour à tous merci", isFinal: false)),
                .result(
                    SpeechTranslationResult(
                        text: "Hello everyone.",
                        sourceText: "Bonjour à tous",
                        isFinal: true
                    )
                )
            ]
        )
        let coordinator = makeCoordinator(engine: engine)
        let events = CaptionEventRecorder()
        let model = testModel()

        for index in 0..<8 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0.05, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) }
            )
        }

        for index in 8..<18 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) }
            )
        }

        let sourceDrafts = events.values.filter { $0.kind == .sourceDraft }.map(\.text)
        XCTAssertTrue(sourceDrafts.contains("Bonjour à tous merci"))
        XCTAssertFalse(events.values.contains { $0.text == "*musique*" })
    }

    func testFirstCredibleDraftIsEmittedImmediately() async {
        let engine = SequencedSpeechTranslationEngine(
            outcomes: [
                .result(SpeechTranslationResult(text: "Bonjour à tous", isFinal: false))
            ]
        )
        let coordinator = makeCoordinator(engine: engine)
        let events = CaptionEventRecorder()
        let model = testModel()

        for index in 0..<7 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0.05, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) }
            )
        }

        XCTAssertEqual(Array(events.values.map(\.kind).prefix(2)), [.speechStarted, .sourceDraft])
        XCTAssertEqual(events.values.first { $0.kind == .sourceDraft }?.text, "Bonjour à tous")
    }

    func testLowercaseContinuationDraftEmitsAfterForcedFinal() async {
        let engine = SequencedSpeechTranslationEngine(
            outcomes: [
                .result(SpeechTranslationResult(text: "The team can finish the preparation", isFinal: true)),
                .result(SpeechTranslationResult(text: "que nous devons terminer la préparation", isFinal: false))
            ]
        )
        let coordinator = LiveSubtitleCoordinator(
            engine: engine,
            silenceGate: SilenceGate(rmsThreshold: 0.01, minimumSpeechDuration: 0.1),
            sampleRate: sampleRate,
            windowDuration: 0.5,
            speechAnalysisDuration: 0.1,
            minimumInferenceDuration: 0.25,
            minimumProcessingInterval: 0,
            maxUtteranceDuration: 0.5,
            trailingSilenceDuration: 0.2,
            maximumUtteranceDuration: 0.2
        )
        let events = CaptionEventRecorder()
        let model = testModel()

        for index in 0..<14 {
            await coordinator.handle(
                chunk: chunk(amplitude: 0.05, index: index),
                model: model,
                languagePair: .frenchToEnglish,
                emit: { events.append($0) }
            )
        }

        let sourceDrafts = events.values.filter { $0.kind == .sourceDraft }.map(\.text)
        XCTAssertTrue(sourceDrafts.contains("que nous devons terminer la préparation"))
    }

    private func makeCoordinator(engine: any SpeechTranslationEngine) -> LiveSubtitleCoordinator {
        LiveSubtitleCoordinator(
            engine: engine,
            silenceGate: SilenceGate(rmsThreshold: 0.01, minimumSpeechDuration: 0.2),
            sampleRate: sampleRate,
            windowDuration: 0.5,
            speechAnalysisDuration: 0.25,
            minimumInferenceDuration: 0.3,
            minimumProcessingInterval: 0,
            trailingSilenceDuration: 0.25
        )
    }

    private func chunk(amplitude: Float, index: Int) -> PCMAudioChunk {
        PCMAudioChunk(
            samples: Array(repeating: amplitude, count: shortChunkSampleCount),
            sampleRate: sampleRate,
            startedAt: Date(timeIntervalSinceReferenceDate: Double(index) * 0.05)
        )
    }

    private func testModel() -> InstalledModel {
        InstalledModel(
            descriptor: ModelDescriptor.builtIn[0],
            localURL: URL(fileURLWithPath: "/tmp/captionbridge-test-model.bin")
        )
    }
}

private actor StubSpeechTranslationEngine: SpeechTranslationEngine {
    private let result: SpeechTranslationResult
    private var translatedChunks: [PCMAudioChunk] = []

    init(result: SpeechTranslationResult) {
        self.result = result
    }

    func translate(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair
    ) async throws -> SpeechTranslationResult {
        translatedChunks.append(chunk)
        return result
    }

    func chunks() -> [PCMAudioChunk] {
        translatedChunks
    }
}

private actor SequencedSpeechTranslationEngine: SpeechTranslationEngine {
    enum Outcome {
        case result(SpeechTranslationResult)
        case emptyResult
        case timedOut
    }

    private var outcomes: [Outcome]
    private var translatedChunks: [PCMAudioChunk] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func translate(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair
    ) async throws -> SpeechTranslationResult {
        translatedChunks.append(chunk)

        guard !outcomes.isEmpty else {
            throw WhisperEngineError.emptyResult
        }

        switch outcomes.removeFirst() {
        case let .result(result):
            return result
        case .emptyResult:
            throw WhisperEngineError.emptyResult
        case .timedOut:
            throw WhisperEngineError.timedOut(seconds: 6)
        }
    }

    func chunks() -> [PCMAudioChunk] {
        translatedChunks
    }
}

private actor FinalTimeoutSpeechTranslationEngine: SpeechTranslationEngine {
    private var didTimeout = false
    private var translatedChunks: [PCMAudioChunk] = []

    func transcribe(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair
    ) async throws -> SpeechTranslationResult {
        SpeechTranslationResult(text: "Nous devons finaliser le rapport", sourceText: "Nous devons finaliser le rapport", isFinal: false)
    }

    func translate(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair
    ) async throws -> SpeechTranslationResult {
        translatedChunks.append(chunk)
        if !didTimeout {
            didTimeout = true
            throw WhisperEngineError.timedOut(seconds: 6)
        }

        return SpeechTranslationResult(text: "We must finalize the report.", isFinal: true)
    }

    func chunks() -> [PCMAudioChunk] {
        translatedChunks
    }
}

private final class CaptionStatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ value: String) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }
}

private final class CaptionEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [CaptionEvent] = []

    var values: [CaptionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ value: CaptionEvent) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }
}
