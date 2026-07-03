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
            "bin/whisper-cli"
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
        } catch let error as WhisperEngineError {
            switch error {
            case .executableNotFound, .failed:
                return try await fallbackEngine.transcribe(audio: chunk, model: model, languagePair: languagePair)
            case .emptyResult, .timedOut:
                throw error
            }
        } catch {
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
        } catch let error as WhisperEngineError {
            switch error {
            case .executableNotFound, .failed:
                return try await fallbackEngine.translate(audio: chunk, model: model, languagePair: languagePair)
            case .emptyResult, .timedOut:
                throw error
            }
        } catch {
            return try await fallbackEngine.translate(audio: chunk, model: model, languagePair: languagePair)
        }
    }
}

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

        var hasRunningProcess: Bool {
            lock.lock()
            let isRunning = process?.isRunning == true
            lock.unlock()
            return isRunning
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

    private final class ResumeBox<T>: @unchecked Sendable {
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
    private let helperURL: URL?
    private let warmTimeoutSeconds: TimeInterval
    private let coldStartTimeoutSeconds: TimeInterval
    private let requestQueue = DispatchQueue(label: "CaptionBridge.PersistentWhisperTranslationEngine")
    private let processState = ProcessState()
    private var requestCounter = 0

    public init(
        locator: WhisperHelperLocator = .default,
        timeoutSeconds: TimeInterval = 6,
        coldStartTimeoutSeconds: TimeInterval = 16
    ) {
        self.locator = locator
        self.helperURL = locator.locate()
        self.warmTimeoutSeconds = timeoutSeconds
        self.coldStartTimeoutSeconds = coldStartTimeoutSeconds
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

    private func request(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair,
        mode: HelperRequestMode
    ) async throws -> SpeechTranslationResult {
        try await withCheckedThrowingContinuation { continuation in
            let resumeBox = ResumeBox<SpeechTranslationResult>()
            let requestTimeoutSeconds = processState.hasRunningProcess ? warmTimeoutSeconds : coldStartTimeoutSeconds
            requestQueue.async {
                let result = Result {
                    try self.performRequest(audio: chunk, model: model, languagePair: languagePair, mode: mode)
                }
                resumeBox.resume(continuation, with: result)
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + requestTimeoutSeconds) {
                if resumeBox.resume(continuation, with: .failure(WhisperEngineError.timedOut(seconds: requestTimeoutSeconds))) {
                    self.processState.terminate()
                    self.processState.clear()
                }
            }
        }
    }

    private func performRequest(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair,
        mode: HelperRequestMode
    ) throws -> SpeechTranslationResult {
        guard let helperURL = helperURL ?? locator.locate() else {
            throw WhisperEngineError.executableNotFound
        }

        let handles = try ensureHelperProcess(helperURL: helperURL)
        requestCounter += 1
        let requestID = "\(requestCounter)"
        let modelPathData = Data(model.localURL.path.utf8)
        let audioData = chunk.samples.withUnsafeBufferPointer { buffer -> Data in
            guard let baseAddress = buffer.baseAddress else {
                return Data()
            }
            return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Float>.size)
        }

        let header = "REQ \(requestID) \(modelPathData.count) \(languagePair.spokenLanguageCode) \(chunk.sampleRate) \(chunk.samples.count) 768 1 \(mode.rawValue)\n"
        try handles.input.write(contentsOf: Data(header.utf8))
        try handles.input.write(contentsOf: modelPathData)
        try handles.input.write(contentsOf: audioData)

        let response = try readResponse(from: handles.output, requestID: requestID)
        let text = sanitizeWhisperOutput(response.text)
        let sourceText = response.sourceText.map(sanitizeWhisperOutput(_:))
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

        do {
            try process.run()
        } catch {
            throw error
        }

        processState.lock.lock()
        processState.process = process
        processState.input = inputPipe.fileHandleForWriting
        processState.output = outputPipe.fileHandleForReading
        let input = inputPipe.fileHandleForWriting
        let output = outputPipe.fileHandleForReading
        processState.lock.unlock()

        return (input, output)
    }

    private func readResponse(from output: FileHandle, requestID: String) throws -> (text: String, sourceText: String?, elapsedMs: Int) {
        let line = try readLine(from: output)
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count == 4 || parts.count == 5 else {
            restartHelper()
            throw WhisperEngineError.failed(exitCode: -1, output: "Invalid persistent Whisper response.")
        }

        let status = parts[0]
        let responseID = parts[1]
        let elapsedMs = Int(parts[2]) ?? 0
        let byteCount = Int(parts[3]) ?? 0
        let sourceByteCount = parts.count == 5 ? (Int(parts[4]) ?? 0) : 0
        guard responseID == requestID, byteCount >= 0, sourceByteCount >= 0 else {
            restartHelper()
            throw WhisperEngineError.failed(exitCode: -1, output: "Mismatched persistent Whisper response.")
        }

        let payload = try readData(from: output, byteCount: byteCount)
        let sourcePayload = try readData(from: output, byteCount: sourceByteCount)
        _ = try? readData(from: output, byteCount: 1)
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

    private func readLine(from handle: FileHandle) throws -> String {
        var data = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty {
                restartHelper()
                throw WhisperEngineError.failed(exitCode: -1, output: "Persistent Whisper helper closed unexpectedly.")
            }

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
            data.append(chunk)
        }
        return data
    }

    private func restartHelper() {
        processState.terminate()
        processState.clear()
    }

    private func sanitizeWhisperOutput(_ output: String) -> String {
        output
            .components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public final class WhisperCLITranslationEngine: SpeechTranslationEngine {
    private let locator: WhisperExecutableLocator
    private let cachedExecutableURL: URL?
    private let timeoutSeconds: TimeInterval

    public init(locator: WhisperExecutableLocator = .default, timeoutSeconds: TimeInterval = 5) {
        self.locator = locator
        self.cachedExecutableURL = locator.locate()
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

    private func run(
        audio chunk: PCMAudioChunk,
        model: InstalledModel,
        languagePair: LanguagePair,
        shouldTranslate: Bool
    ) async throws -> SpeechTranslationResult {
        guard let executableURL = cachedExecutableURL ?? locator.locate() else {
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

        let output: String
        do {
            output = try await runWhisper(
                executableURL: executableURL,
                modelURL: model.localURL,
                audioURL: audioURL,
                outputPrefix: outputPrefix,
                languagePair: languagePair,
                shouldTranslate: shouldTranslate,
                disableGPU: false
            )
        } catch let error as WhisperEngineError {
            guard case .failed = error else {
                throw error
            }

            output = try await runWhisper(
                executableURL: executableURL,
                modelURL: model.localURL,
                audioURL: audioURL,
                outputPrefix: outputPrefix,
                languagePair: languagePair,
                shouldTranslate: shouldTranslate,
                disableGPU: true
            )
        }

        let textFromFile = (try? String(contentsOf: outputTextURL, encoding: .utf8)) ?? ""
        let text = sanitizeWhisperOutput(textFromFile.isEmpty ? output : textFromFile)
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
        shouldTranslate: Bool,
        disableGPU: Bool
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
                    shouldTranslate: shouldTranslate,
                    disableGPU: disableGPU
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
        shouldTranslate: Bool,
        disableGPU: Bool
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
                if disableGPU {
                    arguments.append("-ng")
                }
                process.arguments = arguments

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                process.terminationHandler = { process in
                    let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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

    private func sanitizeWhisperOutput(_ output: String) -> String {
        output
            .components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
