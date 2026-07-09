import Darwin
import Foundation

public struct SpeechTranslationResult: Equatable, Sendable {
    public let text: String
    public let sourceText: String?
    public let startTime: TimeInterval?
    public let endTime: TimeInterval?
    public let isFinal: Bool

    public init(
        text: String,
        sourceText: String? = nil,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        isFinal: Bool = true
    ) {
        self.text = text
        self.sourceText = sourceText
        self.startTime = startTime
        self.endTime = endTime
        self.isFinal = isFinal
    }
}

public protocol SpeechTranslationEngine: Sendable {
    func transcribe(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair
    ) async throws -> SpeechTranslationResult

    func translate(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair
    ) async throws -> SpeechTranslationResult

    /// Produces the final caption for an utterance. When `preferDualOutput`
    /// is true the engine should also return the source-language transcript
    /// (costlier); when false a translation-only pass is enough because the
    /// caller already has source text from live drafts.
    func translateFinal(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair,
        preferDualOutput: Bool
    ) async throws -> SpeechTranslationResult

    /// Loads the model ahead of the first real request so the first caption
    /// of a session does not pay the cold-start cost. Best effort.
    func warmUp(model: InstalledModel, languagePair: LanguagePair) async -> Bool
}

public extension SpeechTranslationEngine {
    func transcribe(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair
    ) async throws -> SpeechTranslationResult {
        let translated = try await translate(audio: chunk, model: model, languagePair: languagePair)
        let sourceText = translated.sourceText ?? translated.text
        return SpeechTranslationResult(
            text: sourceText,
            sourceText: sourceText,
            startTime: translated.startTime,
            endTime: translated.endTime,
            isFinal: translated.isFinal
        )
    }

    func translateFinal(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair,
        preferDualOutput: Bool
    ) async throws -> SpeechTranslationResult {
        try await translate(audio: chunk, model: model, languagePair: languagePair)
    }

    func warmUp(model: InstalledModel, languagePair: LanguagePair) async -> Bool {
        true
    }
}

public enum WhisperEngineError: LocalizedError, Equatable {
    case executableNotFound
    case emptyResult
    case timedOut(seconds: TimeInterval)
    case failed(exitCode: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "The local Whisper helper was not found. Run Scripts/bootstrap-whisper.cpp.sh and Scripts/package-app.sh."
        case .emptyResult:
            return "Whisper produced no subtitle text."
        case let .timedOut(seconds):
            return "Local translation timed out after \(Int(seconds)) seconds."
        case let .failed(exitCode, output):
            return "whisper-cli failed with exit code \(exitCode): \(output)"
        }
    }
}

public struct WhisperHelperLocator: Sendable {
    public var explicitPath: String?
    public var searchRoots: [URL]

    public init(explicitPath: String? = ProcessInfo.processInfo.environment["CAPTIONBRIDGE_WHISPER_HELPER"], searchRoots: [URL] = []) {
        self.explicitPath = explicitPath
        self.searchRoots = searchRoots
    }

    public static var `default`: WhisperHelperLocator {
        var roots: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            roots.append(resourceURL.appendingPathComponent("Tools", isDirectory: true))
        }

        roots.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true))
        roots.append(CaptionBridgePaths.toolsURL)
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tools", isDirectory: true))

        return WhisperHelperLocator(searchRoots: roots)
    }

    public func locate() -> URL? {
        if let explicitPath, !explicitPath.isEmpty {
            let url = URL(fileURLWithPath: explicitPath)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        for root in searchRoots {
            let url = root.appendingPathComponent("captionbridge-whisper-helper")
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        return nil
    }
}

public struct WhisperExecutableLocator: Sendable {
    public var explicitPath: String?
    public var searchRoots: [URL]

    public init(explicitPath: String? = ProcessInfo.processInfo.environment["CAPTIONBRIDGE_WHISPER_CLI"], searchRoots: [URL] = []) {
        self.explicitPath = explicitPath
        self.searchRoots = searchRoots
    }

    public static var `default`: WhisperExecutableLocator {
        var roots: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            roots.append(resourceURL.appendingPathComponent("Tools", isDirectory: true))
        }

        roots.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true))
        roots.append(CaptionBridgePaths.toolsURL)
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/whisper.cpp"))

        return WhisperExecutableLocator(searchRoots: roots)
    }

    public func locate() -> URL? {
        if let explicitPath, !explicitPath.isEmpty {
            let url = URL(fileURLWithPath: explicitPath)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        let candidateRelativePaths = [
            "whisper-cli",
            "main",
            "build/bin/whisper-cli",
            "build/bin/main",
            "bin/whisper-cli",
            "source/build/bin/whisper-cli",
            "source/build/bin/main"
        ]

        for root in searchRoots {
            for relativePath in candidateRelativePaths {
                let url = root.appendingPathComponent(relativePath)
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }

        return nil
    }
}

/// Routes requests to the persistent helper and falls back to the one-shot
/// CLI engine only when the helper binary is missing entirely (development
/// runs). Transient helper failures are NOT routed to the CLI: spawning
/// whisper-cli reloads the model from disk per request, which is strictly
/// worse than letting the persistent helper restart itself.
public final class WhisperLiveTranslationEngine: SpeechTranslationEngine {
    private let persistentEngine: PersistentWhisperTranslationEngine
    private let fallbackEngine: WhisperCLITranslationEngine

    public init(
        persistentEngine: PersistentWhisperTranslationEngine = PersistentWhisperTranslationEngine(),
        fallbackEngine: WhisperCLITranslationEngine = WhisperCLITranslationEngine()
    ) {
        self.persistentEngine = persistentEngine
        self.fallbackEngine = fallbackEngine
    }

    public func transcribe(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair
    ) async throws -> SpeechTranslationResult {
        do {
            return try await persistentEngine.transcribe(audio: chunk, model: model, languagePair: languagePair)
        } catch WhisperEngineError.executableNotFound {
            return try await fallbackEngine.transcribe(audio: chunk, model: model, languagePair: languagePair)
        }
    }

    public func translate(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair
    ) async throws -> SpeechTranslationResult {
        do {
            return try await persistentEngine.translate(audio: chunk, model: model, languagePair: languagePair)
        } catch WhisperEngineError.executableNotFound {
            return try await fallbackEngine.translate(audio: chunk, model: model, languagePair: languagePair)
        }
    }

    public func translateFinal(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair,
        preferDualOutput: Bool
    ) async throws -> SpeechTranslationResult {
        do {
            return try await persistentEngine.translateFinal(
                audio: chunk,
                model: model,
                languagePair: languagePair,
                preferDualOutput: preferDualOutput
            )
        } catch WhisperEngineError.executableNotFound {
            return try await fallbackEngine.translateFinal(
                audio: chunk,
                model: model,
                languagePair: languagePair,
                preferDualOutput: preferDualOutput
            )
        }
    }

    public func warmUp(model: InstalledModel, languagePair: LanguagePair) async -> Bool {
        await persistentEngine.warmUp(model: model, languagePair: languagePair)
    }
}

/// Talks to the bundled persistent whisper.cpp helper over pipes.
///
/// Timeout design: a slow inference must never destroy the loaded model.
/// Timers only resume the waiting caller with `.timedOut`; the helper process
/// is left alive to finish, and the response it eventually writes is drained
/// by the next request (responses carry request IDs). The process is killed
/// only when it has made no observable progress for `stallKillInterval`,
/// which indicates a genuine hang rather than a slow request.
public final class PersistentWhisperTranslationEngine: SpeechTranslationEngine, @unchecked Sendable {
    private enum HelperRequestMode: String {
        case source
        case translate
        case dual
    }

    private final class ProcessState: @unchecked Sendable {
        let lock = NSLock()
        var process: Process?
        var input: FileHandle?
        var output: FileHandle?
        var lastActivityAt = Date()
        var isWorkerBusy = false
        var isStallWatchdogArmed = false

        var hasRunningProcess: Bool {
            lock.lock()
            let isRunning = process?.isRunning == true
            lock.unlock()
            return isRunning
        }

        func noteActivity() {
            lock.lock()
            lastActivityAt = Date()
            lock.unlock()
        }

        func setWorkerBusy(_ busy: Bool) {
            lock.lock()
            isWorkerBusy = busy
            if busy {
                lastActivityAt = Date()
            }
            lock.unlock()
        }

        /// Arms the watchdog if it isn't already running. Returns true when
        /// the caller should start the recheck loop.
        func armStallWatchdog() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard isWorkerBusy, !isStallWatchdogArmed else {
                return false
            }
            isStallWatchdogArmed = true
            return true
        }

        func disarmStallWatchdog() {
            lock.lock()
            isStallWatchdogArmed = false
            lock.unlock()
        }

        var isBusy: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isWorkerBusy
        }

        /// True when the worker has been waiting on the helper with zero
        /// output for longer than `interval` — a hang, not a slow request.
        func isStalled(beyond interval: TimeInterval) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return isWorkerBusy && Date().timeIntervalSince(lastActivityAt) > interval
        }

        func clear() {
            lock.lock()
            process = nil
            input = nil
            output = nil
            lock.unlock()
        }

        func terminate() {
            lock.lock()
            let runningProcess = process
            lock.unlock()

            if runningProcess?.isRunning == true {
                runningProcess?.terminate()
            }
        }
    }

    private final class ResumeBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false

        @discardableResult
        func resume(_ continuation: CheckedContinuation<T, Error>, with result: Result<T, Error>) -> Bool {
            lock.lock()
            guard !didResume else {
                lock.unlock()
                return false
            }
            didResume = true
            lock.unlock()

            switch result {
            case let .success(value):
                continuation.resume(returning: value)
            case let .failure(error):
                continuation.resume(throwing: error)
            }
            return true
        }
    }

    private let locator: WhisperHelperLocator
    private let draftTimeoutSeconds: TimeInterval
    private let finalTimeoutSeconds: TimeInterval
    private let coldStartExtraSeconds: TimeInterval
    private let stallKillInterval: TimeInterval
    private let stallCheckInterval: TimeInterval
    private let requestQueue = DispatchQueue(label: "CaptionBridge.PersistentWhisperTranslationEngine")
    private let processState = ProcessState()
    private var requestCounter = 0

    public init(
        locator: WhisperHelperLocator = .default,
        draftTimeoutSeconds: TimeInterval = 8,
        finalTimeoutSeconds: TimeInterval = 45,
        coldStartExtraSeconds: TimeInterval = 30,
        stallKillInterval: TimeInterval = 25,
        stallCheckInterval: TimeInterval = 5
    ) {
        self.locator = locator
        self.draftTimeoutSeconds = draftTimeoutSeconds
        self.finalTimeoutSeconds = finalTimeoutSeconds
        self.coldStartExtraSeconds = coldStartExtraSeconds
        self.stallKillInterval = stallKillInterval
        self.stallCheckInterval = stallCheckInterval
    }

    deinit {
        processState.terminate()
    }

    public func transcribe(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair
    ) async throws -> SpeechTranslationResult {
        try await request(audio: chunk, model: model, languagePair: languagePair, mode: .source)
    }

    public func translate(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair
    ) async throws -> SpeechTranslationResult {
        try await request(audio: chunk, model: model, languagePair: languagePair, mode: .dual)
    }

    public func translateFinal(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair,
        preferDualOutput: Bool
    ) async throws -> SpeechTranslationResult {
        try await request(
            audio: chunk,
            model: model,
            languagePair: languagePair,
            mode: preferDualOutput ? .dual : .translate
        )
    }

    /// Loads the model by transcribing a short block of silence. Expected to
    /// return no text; only `.executableNotFound` or process launch failures
    /// count as a failed warm-up.
    public func warmUp(model: InstalledModel, languagePair: LanguagePair) async -> Bool {
        let silence = PCMAudioChunk(samples: [Float](repeating: 0, count: 8_000), sampleRate: 16_000)
        do {
            _ = try await request(audio: silence, model: model, languagePair: languagePair, mode: .source)
            return true
        } catch WhisperEngineError.emptyResult {
            return true
        } catch WhisperEngineError.timedOut {
            return true
        } catch {
            return false
        }
    }

    private func request(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair,
        mode: HelperRequestMode
    ) async throws -> SpeechTranslationResult {
        let baseBudget = mode == .source ? draftTimeoutSeconds : finalTimeoutSeconds
        return try await withCheckedThrowingContinuation { continuation in
            let resumeBox = ResumeBox<SpeechTranslationResult>()
            requestQueue.async {
                // Start this request's deadline when it actually reaches the
                // serial worker. A previous slow request must not make queued
                // work expire before it has even begun.
                let requestBudget = self.processState.hasRunningProcess
                    ? baseBudget
                    : baseBudget + self.coldStartExtraSeconds
                self.processState.setWorkerBusy(true)

                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + requestBudget) {
                    let didTimeout = resumeBox.resume(
                        continuation,
                        with: .failure(WhisperEngineError.timedOut(seconds: requestBudget))
                    )
                    guard didTimeout else {
                        return
                    }

                    // Keep a merely slow helper alive, but repeatedly check it
                    // until progress resumes or the stall threshold is crossed.
                    if self.processState.isStalled(beyond: self.stallKillInterval) {
                        self.processState.terminate()
                        self.processState.clear()
                    } else {
                        self.startStallWatchdogIfNeeded()
                    }
                }

                let result = Result {
                    try self.performRequest(audio: chunk, model: model, languagePair: languagePair, mode: mode)
                }
                self.processState.setWorkerBusy(false)
                resumeBox.resume(continuation, with: result)
            }
        }
    }

    private func performRequest(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair,
        mode: HelperRequestMode
    ) throws -> SpeechTranslationResult {
        guard let helperURL = locator.locate() else {
            throw WhisperEngineError.executableNotFound
        }

        let handles = try ensureHelperProcess(helperURL: helperURL)
        requestCounter += 1
        let requestID = requestCounter
        let modelPathData = Data(model.localURL.path.utf8)
        let audioData = chunk.samples.withUnsafeBufferPointer { buffer -> Data in
            guard let baseAddress = buffer.baseAddress else {
                return Data()
            }
            return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Float>.size)
        }

        let header = "REQ \(requestID) \(modelPathData.count) \(languagePair.spokenLanguageCode) \(chunk.sampleRate) \(chunk.samples.count) 768 1 \(mode.rawValue)\n"
        do {
            try handles.input.write(contentsOf: Data(header.utf8))
            try handles.input.write(contentsOf: modelPathData)
            try handles.input.write(contentsOf: audioData)
        } catch {
            restartHelper()
            throw WhisperEngineError.failed(exitCode: -1, output: "Could not reach the local translator; restarting it.")
        }

        let response = try readResponse(from: handles.output, requestID: requestID)
        let text = CaptionText.sanitizeWhisperOutput(response.text)
        let sourceText = response.sourceText.map(CaptionText.sanitizeWhisperOutput(_:))
        guard !text.isEmpty else {
            throw WhisperEngineError.emptyResult
        }

        if mode == .source {
            return SpeechTranslationResult(
                text: text,
                sourceText: text,
                startTime: chunk.startedAt.timeIntervalSinceReferenceDate,
                endTime: chunk.startedAt.addingTimeInterval(chunk.duration).timeIntervalSinceReferenceDate,
                isFinal: false
            )
        }

        return SpeechTranslationResult(
            text: text,
            sourceText: sourceText?.isEmpty == true ? nil : sourceText,
            startTime: chunk.startedAt.timeIntervalSinceReferenceDate,
            endTime: chunk.startedAt.addingTimeInterval(chunk.duration).timeIntervalSinceReferenceDate,
            isFinal: true
        )
    }

    private func ensureHelperProcess(helperURL: URL) throws -> (input: FileHandle, output: FileHandle) {
        processState.lock.lock()
        if let process = processState.process,
           process.isRunning,
           let input = processState.input,
           let output = processState.output {
            processState.lock.unlock()
            return (input, output)
        }
        processState.lock.unlock()

        let process = Process()
        process.executableURL = helperURL

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        // A helper that dies mid-write must surface as a thrown error, not a
        // SIGPIPE that terminates the whole app.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(outputPipe.fileHandleForReading.fileDescriptor, F_SETNOSIGPIPE, 1)

        try process.run()

        processState.lock.lock()
        processState.process = process
        processState.input = inputPipe.fileHandleForWriting
        processState.output = outputPipe.fileHandleForReading
        processState.lastActivityAt = Date()
        let input = inputPipe.fileHandleForWriting
        let output = outputPipe.fileHandleForReading
        processState.lock.unlock()

        return (input, output)
    }

    private func readResponse(from output: FileHandle, requestID: Int) throws -> (text: String, sourceText: String?, elapsedMs: Int) {
        // Responses from abandoned (timed-out) requests are identified by
        // their lower IDs and drained so the stream stays aligned.
        while true {
            let line = try readLine(from: output)
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count == 4 || parts.count == 5,
                  let responseID = Int(parts[1]),
                  let byteCount = Int(parts[3]),
                  byteCount >= 0
            else {
                restartHelper()
                throw WhisperEngineError.failed(exitCode: -1, output: "Invalid persistent Whisper response.")
            }

            let sourceByteCount = parts.count == 5 ? (Int(parts[4]) ?? 0) : 0
            guard sourceByteCount >= 0 else {
                restartHelper()
                throw WhisperEngineError.failed(exitCode: -1, output: "Invalid persistent Whisper response.")
            }

            let payload = try readData(from: output, byteCount: byteCount)
            let sourcePayload = try readData(from: output, byteCount: sourceByteCount)
            _ = try? readData(from: output, byteCount: 1)

            if responseID < requestID {
                continue
            }

            guard responseID == requestID else {
                restartHelper()
                throw WhisperEngineError.failed(exitCode: -1, output: "Mismatched persistent Whisper response.")
            }

            let status = parts[0]
            let elapsedMs = Int(parts[2]) ?? 0
            let text = String(data: payload, encoding: .utf8) ?? ""
            let sourceText = sourceByteCount > 0 ? String(data: sourcePayload, encoding: .utf8) : nil

            if status == "OK" || status == "OK2" {
                return (text, sourceText, elapsedMs)
            }

            if status == "ERR", text.localizedCaseInsensitiveContains("no subtitle") {
                throw WhisperEngineError.emptyResult
            }

            restartHelper()
            throw WhisperEngineError.failed(exitCode: -1, output: text)
        }
    }

    private func readLine(from handle: FileHandle) throws -> String {
        var data = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty {
                restartHelper()
                throw WhisperEngineError.failed(exitCode: -1, output: "Persistent Whisper helper closed unexpectedly.")
            }

            processState.noteActivity()
            if byte.first == UInt8(ascii: "\n") {
                break
            }
            data.append(byte)
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    private func readData(from handle: FileHandle, byteCount: Int) throws -> Data {
        var data = Data()
        while data.count < byteCount {
            let chunk = handle.readData(ofLength: byteCount - data.count)
            if chunk.isEmpty {
                restartHelper()
                throw WhisperEngineError.failed(exitCode: -1, output: "Persistent Whisper helper closed during response.")
            }
            processState.noteActivity()
            data.append(chunk)
        }
        return data
    }

    private func startStallWatchdogIfNeeded() {
        guard processState.armStallWatchdog() else {
            return
        }
        scheduleStallRecheck()
    }

    private func scheduleStallRecheck() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + stallCheckInterval) { [weak self] in
            guard let self else {
                return
            }
            guard self.processState.isBusy else {
                self.processState.disarmStallWatchdog()
                return
            }
            if self.processState.isStalled(beyond: self.stallKillInterval) {
                self.processState.disarmStallWatchdog()
                self.processState.terminate()
                self.processState.clear()
            } else {
                self.scheduleStallRecheck()
            }
        }
    }

    private func restartHelper() {
        processState.terminate()
        processState.clear()
    }
}

/// One-shot whisper-cli engine, used only when the persistent helper binary
/// is missing (development runs without packaging). Reloads the model on
/// every request, so the timeout must cover a full model load.
public final class WhisperCLITranslationEngine: SpeechTranslationEngine {
    private let locator: WhisperExecutableLocator
    private let timeoutSeconds: TimeInterval

    public init(locator: WhisperExecutableLocator = .default, timeoutSeconds: TimeInterval = 30) {
        self.locator = locator
        self.timeoutSeconds = timeoutSeconds
    }

    public func transcribe(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair
    ) async throws -> SpeechTranslationResult {
        let result = try await run(audio: chunk, model: model, languagePair: languagePair, shouldTranslate: false)
        return SpeechTranslationResult(
            text: result.text,
            sourceText: result.text,
            startTime: result.startTime,
            endTime: result.endTime,
            isFinal: false
        )
    }

    public func translate(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair
    ) async throws -> SpeechTranslationResult {
        try await run(audio: chunk, model: model, languagePair: languagePair, shouldTranslate: true)
    }

    public func translateFinal(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair,
        preferDualOutput: Bool
    ) async throws -> SpeechTranslationResult {
        guard preferDualOutput else {
            return try await translate(audio: chunk, model: model, languagePair: languagePair)
        }

        let source = try await transcribe(audio: chunk, model: model, languagePair: languagePair)
        let translated = try await translate(audio: chunk, model: model, languagePair: languagePair)
        return SpeechTranslationResult(
            text: translated.text,
            sourceText: source.text,
            startTime: translated.startTime,
            endTime: translated.endTime,
            isFinal: true
        )
    }

    private func run(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair,
        shouldTranslate: Bool
    ) async throws -> SpeechTranslationResult {
        guard let executableURL = locator.locate() else {
            throw WhisperEngineError.executableNotFound
        }

        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("CaptionBridge-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let audioURL = tempDirectory.appendingPathComponent("chunk.wav")
        let outputPrefix = tempDirectory.appendingPathComponent("caption")
        let outputTextURL = tempDirectory.appendingPathComponent("caption.txt")
        try WaveFile.pcm16Data(from: chunk).write(to: audioURL, options: [.atomic])

        let output = try await runWhisper(
            executableURL: executableURL,
            modelURL: model.localURL,
            audioURL: audioURL,
            outputPrefix: outputPrefix,
            languagePair: languagePair,
            shouldTranslate: shouldTranslate
        )

        let textFromFile = (try? String(contentsOf: outputTextURL, encoding: .utf8)) ?? ""
        let text = CaptionText.sanitizeWhisperOutput(textFromFile.isEmpty ? output : textFromFile)
        guard !text.isEmpty else {
            throw WhisperEngineError.emptyResult
        }

        return SpeechTranslationResult(
            text: text,
            startTime: chunk.startedAt.timeIntervalSinceReferenceDate,
            endTime: chunk.startedAt.addingTimeInterval(chunk.duration).timeIntervalSinceReferenceDate,
            isFinal: shouldTranslate
        )
    }

    private func runWhisper(
        executableURL: URL,
        modelURL: URL,
        audioURL: URL,
        outputPrefix: URL,
        languagePair: LanguagePair,
        shouldTranslate: Bool
    ) async throws -> String {
        let timeoutSeconds = self.timeoutSeconds
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await Self.runWhisperProcess(
                    executableURL: executableURL,
                    modelURL: modelURL,
                    audioURL: audioURL,
                    outputPrefix: outputPrefix,
                    languagePair: languagePair,
                    shouldTranslate: shouldTranslate
                )
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw WhisperEngineError.timedOut(seconds: timeoutSeconds)
            }

            guard let output = try await group.next() else {
                throw WhisperEngineError.emptyResult
            }
            group.cancelAll()
            return output
        }
    }

    private static func runWhisperProcess(
        executableURL: URL,
        modelURL: URL,
        audioURL: URL,
        outputPrefix: URL,
        languagePair: LanguagePair,
        shouldTranslate: Bool
    ) async throws -> String {
        let processBox = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                processBox.set(process)
                process.executableURL = executableURL
                var arguments = [
                    "-m", modelURL.path,
                    "-f", audioURL.path,
                    "-l", languagePair.spokenLanguageCode,
                    "-nt",
                    "-np",
                    "-bo", shouldTranslate ? "3" : "1",
                    "-bs", shouldTranslate ? "3" : "1",
                    "-nf",
                    "-ac", "768",
                    "-otxt",
                    "-of", outputPrefix.path
                ]
                if shouldTranslate {
                    arguments.append("-tr")
                }
                process.arguments = arguments

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                // Drain both pipes while the process runs; whisper-cli can
                // emit more than a pipe buffer of logs, and an undrained pipe
                // would block it forever.
                let stdoutBuffer = PipeDrainBuffer(handle: outputPipe.fileHandleForReading)
                let stderrBuffer = PipeDrainBuffer(handle: errorPipe.fileHandleForReading)

                process.terminationHandler = { process in
                    let stdout = stdoutBuffer.finish()
                    let stderr = stderrBuffer.finish()
                    let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: combined)
                    } else {
                        continuation.resume(throwing: WhisperEngineError.failed(exitCode: process.terminationStatus, output: combined))
                    }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            processBox.terminate()
        }
    }
}

private final class PipeDrainBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let available = handle.availableData
            guard let self, !available.isEmpty else {
                return
            }
            self.lock.lock()
            self.data.append(available)
            self.lock.unlock()
        }
    }

    func finish() -> String {
        handle.readabilityHandler = nil
        let remainder = (try? handle.readToEnd()) ?? Data()
        lock.lock()
        if !remainder.isEmpty {
            data.append(remainder)
        }
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let process = process
        lock.unlock()

        if process?.isRunning == true {
            process?.terminate()
        }
    }
}
