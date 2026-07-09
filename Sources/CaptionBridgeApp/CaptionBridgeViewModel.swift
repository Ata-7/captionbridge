import AppKit
import CaptionBridgeCore
import Foundation
import SwiftUI
#if canImport(Translation)
@preconcurrency import Translation
#endif

private struct EpochAudioChunk: Sendable {
    let chunk: PCMAudioChunk
    let epoch: Int
}

private final class AudioChunkEpochGate: @unchecked Sendable {
    private let lock = NSLock()
    private var acceptingEpoch: Int?

    func open(epoch: Int) {
        lock.withLock {
            acceptingEpoch = epoch
        }
    }

    func close() {
        lock.withLock {
            acceptingEpoch = nil
        }
    }

    func tag(_ chunk: PCMAudioChunk) -> EpochAudioChunk? {
        lock.withLock {
            acceptingEpoch.map { EpochAudioChunk(chunk: chunk, epoch: $0) }
        }
    }
}

@MainActor
final class CaptionBridgeViewModel: ObservableObject {
    enum SessionState: Equatable {
        case idle
        case preparing
        case running
        case paused
        case failed(String)

        var isRunning: Bool {
            if case .running = self {
                return true
            }
            return false
        }

        var isActive: Bool {
            switch self {
            case .preparing, .running, .paused:
                return true
            case .idle, .failed:
                return false
            }
        }
    }

    private enum CoordinatorSignal {
        case event(CaptionEvent, epoch: Int)
        case status(String, epoch: Int)
    }

    @Published var settings = AppSettings()
    @Published var sessionState: SessionState = .idle
    @Published var modelStatus = "Checking local models..."
    @Published var helperStatus = "Checking local translator..."
    @Published var isSelectedModelInstalled = false
    @Published var isLocalTranslatorReady = false
    @Published var currentSubtitle = ""
    @Published var currentSourceText: String?
    @Published var draftSubtitle = ""
    @Published var draftSourceText: String?
    @Published var subtitleHistory: [SubtitleHistoryItem] = []
    @Published var sessionTranscript: [SubtitleHistoryItem] = []
    @Published var lastError: String?
    @Published var isOverlayVisible = false
    @Published var modelDownloadProgress: Double?
    @Published var liveStatus = "Idle"
    @Published var canOpenPrivacySettings = false
    @Published private(set) var isPauseTransitionPending = false

    let modelDescriptors = ModelDescriptor.builtIn
    weak var overlayController: SubtitleOverlayController?

    private let settingsStore = SettingsStore()
    private let modelManager = ModelManager()
    private let systemCapture = SystemAudioCaptureService()
    private let microphoneCapture = MicrophoneCaptureService()
    private let engine = WhisperLiveTranslationEngine()
    private let coordinator: LiveSubtitleCoordinator
    private var installedModel: InstalledModel?
    private var activeCapture: (any AudioCaptureService)?
    private var modelDownloadTask: Task<Void, Never>?
    private var pipelineResetTask: Task<Void, Never>?
    private var isPaused = false
    private var diagnosticLogURL: URL?
    private var diagnosticHandle: FileHandle?
    private var didConfigureLaunchDiagnostics = false
    private var receivedChunkCount = 0
    private var sessionEpoch = 0
    private var modelDownloadGeneration = 0
    private var didAttemptCaptureRestart = false
    private var lastDiagnosticStatus: String?
    private var lastDiagnosticOverlayText: String?
    private var subtitleHistoryBuffer = SubtitleHistoryBuffer(maximumVisibleFinalCaptions: 3)
    private var sessionTranscriptBuffer = SubtitleHistoryBuffer(maximumVisibleFinalCaptions: 80)

    // Audio chunks and caption events each flow through a single ordered
    // stream: unstructured per-callback Tasks would not preserve order, and
    // out-of-order audio garbles transcription.
    private let audioChunkGate = AudioChunkEpochGate()
    private let chunkStream: AsyncStream<EpochAudioChunk>
    private let chunkContinuation: AsyncStream<EpochAudioChunk>.Continuation
    private let signalStream: AsyncStream<CoordinatorSignal>
    private let signalContinuation: AsyncStream<CoordinatorSignal>.Continuation
    private var pipelineTasks: [Task<Void, Never>] = []

    // French drafts queued for on-device English translation (macOS 15+).
    private var frenchDraftContinuation: AsyncStream<String>.Continuation?
    private var pendingSourceDraft: String?
    private var draftReplacementTask: Task<Void, Never>?
    private var lastDraftPresentationDate = Date.distantPast

    private static let diagnosticTimestampFormatter = ISO8601DateFormatter()
    private static let draftReplacementInterval: TimeInterval = 0.8

    init() {
        coordinator = LiveSubtitleCoordinator(engine: engine)
        (chunkStream, chunkContinuation) = AsyncStream.makeStream(
            of: EpochAudioChunk.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        (signalStream, signalContinuation) = AsyncStream.makeStream(of: CoordinatorSignal.self)

        let chunkContinuation = chunkContinuation
        let audioChunkGate = audioChunkGate
        systemCapture.onChunk = { chunk in
            guard let taggedChunk = audioChunkGate.tag(chunk) else {
                return
            }
            chunkContinuation.yield(taggedChunk)
        }
        microphoneCapture.onChunk = { chunk in
            guard let taggedChunk = audioChunkGate.tag(chunk) else {
                return
            }
            chunkContinuation.yield(taggedChunk)
        }
        systemCapture.onStopped = { [weak self] error in
            Task { @MainActor in
                self?.handleCaptureStopped(error)
            }
        }
        microphoneCapture.onStopped = { [weak self] error in
            Task { @MainActor in
                self?.handleCaptureStopped(error)
            }
        }

        pipelineTasks.append(Task { [weak self] in
            guard let stream = self?.chunkStream else {
                return
            }
            for await taggedChunk in stream {
                guard let self else {
                    return
                }
                await self.processChunk(taggedChunk)
            }
        })

        pipelineTasks.append(Task { [weak self] in
            guard let stream = self?.signalStream else {
                return
            }
            for await signal in stream {
                guard let self else {
                    return
                }
                self.applySignal(signal)
            }
        })

        Task {
            await loadInitialState()
        }
    }

    deinit {
        pipelineTasks.forEach { $0.cancel() }
        draftReplacementTask?.cancel()
        modelDownloadTask?.cancel()
        audioChunkGate.close()
        chunkContinuation.finish()
        signalContinuation.finish()
    }

    func loadInitialState() async {
        settings = await settingsStore.load()
        if !settings.modelQualityMigrationCompleted {
            let selectedModelID = AppSettings.canonicalModelID(settings.selectedModelID)
            if selectedModelID == "ggml-base" || selectedModelID == "ggml-small" {
                let existingModel = try? await modelManager.installedModel(id: selectedModelID)
                if existingModel != nil {
                    settings.selectedModelID = selectedModelID
                } else {
                    settings.selectedModelID = ModelDescriptor.defaultModelID
                }
            } else {
                settings.selectedModelID = ModelDescriptor.defaultModelID
            }
            settings.modelQualityMigrationCompleted = true
            try? await settingsStore.save(settings)
        }
        if !settings.bilingualDefaultMigrationCompleted {
            settings.subtitleDisplayMode = .bilingual
            settings.bilingualDefaultMigrationCompleted = true
            try? await settingsStore.save(settings)
        }
        await refreshModelStatus()
        refreshHelperStatus()
    }

    func configureLaunchDiagnosticsIfNeeded() {
        guard !didConfigureLaunchDiagnostics else {
            return
        }
        didConfigureLaunchDiagnostics = true

        let environment = ProcessInfo.processInfo.environment

        if let logPath = environment["CAPTIONBRIDGE_EVENT_LOG"], !logPath.isEmpty {
            diagnosticLogURL = URL(fileURLWithPath: logPath)
            try? FileManager.default.removeItem(at: diagnosticLogURL!)
            lastDiagnosticStatus = nil
            lastDiagnosticOverlayText = nil
            recordDiagnostic("diagnostics enabled")
        }

        if environment["CAPTIONBRIDGE_SUBTITLE_DISPLAY"] == "bilingual" {
            settings.subtitleDisplayMode = .bilingual
            recordDiagnostic("display: bilingual")
        }

        if environment["CAPTIONBRIDGE_AUTOSTART"] == "1" {
            recordDiagnostic("autostart requested")
            startSubtitles()
        }
    }

    func refreshModelStatus() async {
        let modelID = settings.selectedModelID
        do {
            if let model = try await modelManager.installedModel(id: modelID) {
                guard settings.selectedModelID == modelID else {
                    return
                }
                installedModel = model
                isSelectedModelInstalled = true
                modelStatus = "\(model.descriptor.displayName) is installed"
            } else {
                guard settings.selectedModelID == modelID else {
                    return
                }
                installedModel = nil
                isSelectedModelInstalled = false
                let descriptor = try await modelManager.descriptor(id: modelID)
                guard settings.selectedModelID == modelID else {
                    return
                }
                modelStatus = "\(descriptor.displayName) needs download"
            }
        } catch {
            guard settings.selectedModelID == modelID else {
                return
            }
            installedModel = nil
            isSelectedModelInstalled = false
            modelStatus = error.localizedDescription
        }
    }

    func saveSettings() {
        let snapshot = settings
        Task {
            try? await settingsStore.save(snapshot)
            await refreshModelStatus()
            refreshHelperStatus()
        }
    }

    func refreshOverlayLayout() {
        overlayController?.refreshLayoutForCurrentSettings()
    }

    func refreshHelperStatus() {
        if let helperURL = WhisperHelperLocator.default.locate() {
            isLocalTranslatorReady = true
            helperStatus = "Local translator ready"
            recordDiagnostic("helper: Persistent Whisper helper ready at \(helperURL.lastPathComponent)")
        } else if let helperURL = WhisperExecutableLocator.default.locate() {
            isLocalTranslatorReady = true
            helperStatus = "Backup local translator ready"
            recordDiagnostic("helper: Whisper CLI fallback ready at \(helperURL.lastPathComponent)")
        } else {
            isLocalTranslatorReady = false
            helperStatus = "Local translator missing. Reinstall CaptionBridge from the DMG."
            recordDiagnostic("helper: missing")
        }
    }

    func downloadSelectedModel() {
        guard modelDownloadProgress == nil else {
            return
        }

        modelDownloadGeneration += 1
        let generation = modelDownloadGeneration
        modelDownloadProgress = 0
        modelStatus = "Downloading local translation model..."
        let modelID = settings.selectedModelID

        modelDownloadTask = Task {
            do {
                let model = try await modelManager.ensureInstalled(id: modelID) { [weak self] progress in
                    Task { @MainActor in
                        guard let self,
                              self.modelDownloadGeneration == generation,
                              self.settings.selectedModelID == modelID
                        else {
                            return
                        }
                        self.modelDownloadProgress = progress
                    }
                }
                guard !Task.isCancelled else {
                    throw CancellationError()
                }
                guard modelDownloadGeneration == generation,
                      settings.selectedModelID == modelID
                else {
                    return
                }
                installedModel = model
                isSelectedModelInstalled = true
                modelStatus = "\(model.descriptor.displayName) is installed"
                modelDownloadProgress = nil
            } catch {
                guard modelDownloadGeneration == generation,
                      settings.selectedModelID == modelID
                else {
                    return
                }
                isSelectedModelInstalled = false
                modelDownloadProgress = nil
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    modelStatus = "Model download canceled"
                } else if case ModelManagerError.checksumMismatch = error {
                    modelStatus = "The downloaded model failed its safety check. Please download again."
                    lastError = modelStatus
                } else {
                    modelStatus = error.localizedDescription
                    lastError = error.localizedDescription
                }
            }
            if modelDownloadGeneration == generation {
                modelDownloadTask = nil
            }
        }
    }

    func cancelModelDownload() {
        modelDownloadGeneration += 1
        modelDownloadTask?.cancel()
        modelDownloadTask = nil
        modelDownloadProgress = nil
        modelStatus = "Model download canceled"
    }

    func startSubtitles() {
        guard !sessionState.isActive else {
            return
        }

        audioChunkGate.close()
        sessionEpoch += 1
        let epoch = sessionEpoch
        let precedingReset = pipelineResetTask
        sessionState = .preparing
        Task {
            lastError = nil
            canOpenPrivacySettings = false
            receivedChunkCount = 0
            didAttemptCaptureRestart = false
            updateLiveStatus("Preparing local captioning...")
            isPaused = false
            isPauseTransitionPending = false

            await precedingReset?.value
            guard sessionEpoch == epoch, sessionState == .preparing else {
                return
            }

            await refreshModelStatus()
            refreshHelperStatus()
            guard sessionEpoch == epoch, sessionState == .preparing else {
                return
            }
            guard let model = installedModel else {
                sessionState = .failed("Download a local model before starting subtitles.")
                updateLiveStatus("Model needed")
                return
            }

            guard isLocalTranslatorReady else {
                sessionState = .failed("Reinstall CaptionBridge from the DMG so the local translator is included.")
                updateLiveStatus("Local translator needed")
                return
            }

            // Load the model before audio starts so the first sentence of the
            // meeting doesn't pay the multi-second cold start.
            updateLiveStatus("Loading the translation model into memory...")
            let warmedUp = await engine.warmUp(model: model, languagePair: settings.languagePair)
            guard sessionEpoch == epoch, sessionState == .preparing else {
                return
            }
            if !warmedUp {
                refreshHelperStatus()
                let message = isLocalTranslatorReady
                    ? "The local translator could not load the selected model. Restart CaptionBridge or reinstall the app if the problem continues."
                    : "Reinstall CaptionBridge from the DMG so the local translator is included."
                sessionState = .failed(message)
                lastError = message
                updateLiveStatus("Local translator could not start")
                return
            }

            do {
                let capture: any AudioCaptureService = settings.audioSource == .microphone ? microphoneCapture : systemCapture
                activeCapture = capture
                audioChunkGate.open(epoch: epoch)
                try await capture.start(source: settings.audioSource)
                guard sessionEpoch == epoch, sessionState == .preparing else {
                    audioChunkGate.close()
                    await capture.stop()
                    return
                }
                overlayController?.show()
                isOverlayVisible = true
                sessionState = .running
                updateLiveStatus(listeningStatus)
                scheduleNoAudioCheck(epoch: epoch)
            } catch {
                audioChunkGate.close()
                activeCapture = nil
                guard sessionEpoch == epoch, sessionState == .preparing else {
                    return
                }
                let message = friendlyMessage(for: error)
                sessionState = .failed(message)
                lastError = message
                canOpenPrivacySettings = isPrivacyPermissionError(error)
                recordDiagnostic("start failed: \(message)")
                updateLiveStatus("Needs attention")
            }
        }
    }

    func pauseOrResume() {
        switch sessionState {
        case .running:
            audioChunkGate.close()
            sessionEpoch += 1
            isPaused = true
            sessionState = .paused
            isPauseTransitionPending = false
            clearLiveDraft()
            updateLiveStatus("Paused")

            let resetTask = Task { [coordinator] in
                await coordinator.resetSpeechTracking()
            }
            pipelineResetTask = resetTask
        case .paused:
            guard !isPauseTransitionPending else {
                return
            }

            isPauseTransitionPending = true
            let epoch = sessionEpoch
            let resetTask = pipelineResetTask
            Task {
                await resetTask?.value
                guard sessionEpoch == epoch, sessionState == .paused else {
                    return
                }

                audioChunkGate.open(epoch: epoch)
                isPaused = false
                isPauseTransitionPending = false
                sessionState = .running
                updateLiveStatus(listeningStatus)
            }
        default:
            break
        }
    }

    func stopSubtitles() {
        audioChunkGate.close()
        sessionEpoch += 1
        let capture = activeCapture
        activeCapture = nil
        isPaused = false
        isPauseTransitionPending = false
        sessionState = .idle
        canOpenPrivacySettings = false
        updateLiveStatus("Idle")
        clearLiveDraft()
        recordOverlayDisplayIfChanged()

        let resetTask = Task { [coordinator] in
            await capture?.stop()
            await coordinator.resetSpeechTracking()
        }
        pipelineResetTask = resetTask
    }

    func clearCaptions() {
        let epoch = sessionEpoch
        clearLiveDraft()
        if sessionState.isRunning {
            updateLiveStatus(listeningStatus)
        }
        Task {
            await coordinator.clear { [signalContinuation] event in
                signalContinuation.yield(.event(event, epoch: epoch))
            }
        }
    }

    func openPrivacySettings() {
        let pane = settings.audioSource == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func toggleOverlay() {
        if isOverlayVisible {
            overlayController?.hide()
            isOverlayVisible = false
        } else {
            overlayController?.show()
            isOverlayVisible = true
        }
    }

    private func processChunk(_ taggedChunk: EpochAudioChunk) async {
        guard taggedChunk.epoch == sessionEpoch,
              !isPaused,
              sessionState.isRunning
        else {
            return
        }

        let chunk = taggedChunk.chunk
        guard !chunk.samples.isEmpty else {
            return
        }

        receivedChunkCount += 1
        if diagnosticLogURL != nil, receivedChunkCount == 1 || receivedChunkCount.isMultiple(of: 25) {
            let rms = AudioProcessing.rms(chunk.samples)
            recordDiagnostic("audio chunk \(receivedChunkCount): samples=\(chunk.samples.count) rms=\(rms)")
        }

        await coordinator.handle(
            chunk: chunk,
            model: installedModel,
            languagePair: settings.languagePair
        ) { [signalContinuation] event in
            signalContinuation.yield(.event(event, epoch: taggedChunk.epoch))
        } status: { [signalContinuation] message in
            signalContinuation.yield(.status(message, epoch: taggedChunk.epoch))
        }
    }

    var canStartSubtitles: Bool {
        isSelectedModelInstalled && isLocalTranslatorReady && modelDownloadProgress == nil
    }

    var supportsInstantEnglishDrafts: Bool {
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }

    private func applySignal(_ signal: CoordinatorSignal) {
        switch signal {
        case let .event(event, epoch):
            guard epoch == sessionEpoch else {
                return
            }
            apply(event: event)
        case let .status(message, epoch):
            guard epoch == sessionEpoch else {
                return
            }
            updateLiveStatus(message)
        }
    }

    private func apply(event: CaptionEvent) {
        switch event.kind {
        case .sourceDraft:
            presentSourceDraft(event.text)
        case .final:
            appendFinalCaption(event)
            currentSourceText = event.sourceText
            clearLiveDraft()
            recordDiagnostic("final: \(event.text)")
            updateLiveStatus("Caption updated")
        case .speechStarted:
            currentSourceText = nil
            clearLiveDraft()
            recordDiagnostic("speech started")
            updateLiveStatus("Listening to the next sentence...")
        case .cleared:
            currentSubtitle = ""
            currentSourceText = nil
            clearLiveDraft()
            subtitleHistoryBuffer.clear()
            subtitleHistory = subtitleHistoryBuffer.items
            sessionTranscriptBuffer.clear()
            sessionTranscript = sessionTranscriptBuffer.items
            recordDiagnostic("captions cleared")
        case .error:
            lastError = event.text
            recordDiagnostic("error: \(event.text)")
            updateLiveStatus("Needs attention")
        }
    }

    private func appendFinalCaption(_ event: CaptionEvent) {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }

        currentSubtitle = text
        subtitleHistory = subtitleHistoryBuffer.appendFinal(event)
        sessionTranscript = sessionTranscriptBuffer.appendFinal(event)
    }

    private func presentSourceDraft(_ text: String) {
        let normalized = CaptionText.collapseWhitespace(text)
        guard !normalized.isEmpty else {
            return
        }

        guard draftSourceText != normalized else {
            pendingSourceDraft = nil
            draftReplacementTask?.cancel()
            draftReplacementTask = nil
            return
        }

        guard !(draftSourceText?.isEmpty ?? true) else {
            publishSourceDraft(normalized)
            return
        }

        pendingSourceDraft = normalized
        let elapsed = Date().timeIntervalSince(lastDraftPresentationDate)
        guard elapsed < Self.draftReplacementInterval else {
            pendingSourceDraft = nil
            draftReplacementTask?.cancel()
            draftReplacementTask = nil
            publishSourceDraft(normalized)
            return
        }

        guard draftReplacementTask == nil else {
            return
        }

        let delay = Self.draftReplacementInterval - elapsed
        draftReplacementTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else {
                return
            }

            draftReplacementTask = nil
            guard let pendingSourceDraft else {
                return
            }
            self.pendingSourceDraft = nil
            publishSourceDraft(pendingSourceDraft)
        }
    }

    private func publishSourceDraft(_ normalized: String) {
        // Clear English in the same main-actor turn that French changes. The
        // overlay reserves both rows, so this never shifts the layout.
        draftSubtitle = ""
        draftSourceText = normalized
        lastDraftPresentationDate = Date()
        recordDiagnostic("source draft: \(normalized)")
        updateLiveStatus("French caption ready")

        if supportsInstantEnglishDrafts, settings.instantEnglishDraftsEnabled {
            frenchDraftContinuation?.yield(normalized)
        }
    }

    private func clearLiveDraft() {
        draftReplacementTask?.cancel()
        draftReplacementTask = nil
        pendingSourceDraft = nil
        lastDraftPresentationDate = .distantPast
        draftSubtitle = ""
        draftSourceText = nil
    }

    private func handleCaptureStopped(_ error: Error?) {
        guard sessionState.isRunning || sessionState == .paused else {
            return
        }

        recordDiagnostic("capture stopped: \(error?.localizedDescription ?? "unknown")")

        guard !didAttemptCaptureRestart, let capture = activeCapture else {
            let message = error.map(friendlyMessage(for:)) ?? "Audio capture stopped unexpectedly."
            audioChunkGate.close()
            sessionEpoch += 1
            activeCapture = nil
            isPaused = false
            isPauseTransitionPending = false
            clearLiveDraft()
            sessionState = .failed(message)
            lastError = message
            canOpenPrivacySettings = error.map(isPrivacyPermissionError) ?? false
            updateLiveStatus("Needs attention")
            return
        }

        didAttemptCaptureRestart = true
        updateLiveStatus("Audio capture interrupted. Reconnecting...")
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard sessionState.isRunning || sessionState == .paused else {
                return
            }
            do {
                try await capture.start(source: settings.audioSource)
                didAttemptCaptureRestart = false
                updateLiveStatus(sessionState == .paused ? "Paused" : listeningStatus)
                recordDiagnostic("capture restarted")
            } catch {
                let message = friendlyMessage(for: error)
                audioChunkGate.close()
                sessionEpoch += 1
                activeCapture = nil
                isPaused = false
                isPauseTransitionPending = false
                clearLiveDraft()
                sessionState = .failed(message)
                lastError = message
                canOpenPrivacySettings = isPrivacyPermissionError(error)
                updateLiveStatus("Needs attention")
            }
        }
    }

    private var listeningStatus: String {
        settings.audioSource == .microphone ? "Listening for microphone audio..." : "Listening for system audio..."
    }

    private func scheduleNoAudioCheck(epoch: Int) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            await MainActor.run {
                guard let self,
                      self.sessionEpoch == epoch,
                      self.sessionState.isRunning,
                      self.receivedChunkCount == 0
                else {
                    return
                }

                self.updateLiveStatus("No system audio detected yet")
            }
        }
    }

    private func updateLiveStatus(_ message: String) {
        guard liveStatus != message else {
            return
        }

        liveStatus = message
        if lastDiagnosticStatus != message {
            lastDiagnosticStatus = message
            recordDiagnostic("status: \(message)")
        }

        recordOverlayDisplayIfChanged()
    }

    private func recordOverlayDisplayIfChanged() {
        guard diagnosticLogURL != nil else {
            return
        }

        let text = overlayDisplayText
        guard lastDiagnosticOverlayText != text else {
            return
        }

        lastDiagnosticOverlayText = text
        recordDiagnostic("overlay: \(text)")
    }

    private var overlayDisplayText: String {
        var visibleText = subtitleHistory.map { item in
            if settings.subtitleDisplayMode == .bilingual,
               let sourceText = item.sourceText,
               !sourceText.isEmpty {
                return "\(sourceText) / \(item.text)"
            }

            return item.text
        }

        if !draftSubtitle.isEmpty || !(draftSourceText?.isEmpty ?? true) {
            if settings.subtitleDisplayMode == .bilingual,
               let draftSourceText,
               !draftSourceText.isEmpty {
                visibleText.append(draftSubtitle.isEmpty ? draftSourceText : "\(draftSourceText) / \(draftSubtitle)")
            } else if !draftSubtitle.isEmpty {
                visibleText.append(draftSubtitle)
            } else if let draftSourceText {
                visibleText.append(draftSourceText)
            }
        }

        if !visibleText.isEmpty {
            return visibleText.joined(separator: " | ")
        }

        if liveStatus != "Idle" {
            return liveStatus
        }

        return "Waiting for speech..."
    }

    private func recordDiagnostic(_ message: String) {
        guard let diagnosticLogURL else {
            return
        }

        let timestamp = Self.diagnosticTimestampFormatter.string(from: Date())
        let data = Data("\(timestamp) \(message)\n".utf8)

        if diagnosticHandle == nil {
            if !FileManager.default.fileExists(atPath: diagnosticLogURL.path) {
                FileManager.default.createFile(atPath: diagnosticLogURL.path, contents: nil)
            }
            diagnosticHandle = try? FileHandle(forWritingTo: diagnosticLogURL)
            _ = try? diagnosticHandle?.seekToEnd()
        }

        _ = try? diagnosticHandle?.write(contentsOf: data)
    }

    private func friendlyMessage(for error: Error) -> String {
        if isPrivacyPermissionError(error) {
            if settings.audioSource == .microphone {
                return "CaptionBridge needs macOS Microphone permission before it can listen to microphone audio."
            }
            return "CaptionBridge needs macOS Screen & System Audio Recording permission before it can listen to meeting audio."
        }

        return error.localizedDescription
    }

    private func isPrivacyPermissionError(_ error: Error) -> Bool {
        if let captureError = error as? AudioCaptureError {
            switch captureError {
            case .screenCapturePermissionDenied, .microphonePermissionDenied:
                return true
            case .noDisplayAvailable, .teamsNotRunning, .sampleBufferMissingAudio, .unsupportedFormat, .microphoneUnavailable:
                return false
            }
        }

        // ScreenCaptureKit errors surface TCC denials with these markers.
        let lowercased = error.localizedDescription.lowercased()
        return lowercased.contains("tcc") || lowercased.contains("declined") || lowercased.contains("not permitted")
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
extension CaptionBridgeViewModel {
    /// Long-running loop owned by the overlay's translationTask: receives
    /// French drafts and publishes on-device English translations so the
    /// English line updates while the speaker is still mid-sentence.
    func runInstantDraftTranslation(session: TranslationSession) async {
        frenchDraftContinuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        frenchDraftContinuation = continuation

        var isPrepared = false
        for await french in stream {
            guard settings.instantEnglishDraftsEnabled else {
                continue
            }
            if !isPrepared {
                // Downloads the French->English language pack on first use
                // (one system prompt); afterwards it is a no-op and fully
                // offline. Deliberately not done while the feature is off.
                try? await session.prepareTranslation()
                isPrepared = true
            }
            guard let response = try? await session.translate(french) else {
                continue
            }
            if draftSourceText == french {
                draftSubtitle = response.targetText
            }
        }
    }
}
#endif
