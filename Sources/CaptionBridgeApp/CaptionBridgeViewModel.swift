import AppKit
import CaptionBridgeCore
import Foundation
import SwiftUI

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

    let modelDescriptors = ModelDescriptor.builtIn
    weak var overlayController: SubtitleOverlayController?

    private let settingsStore = SettingsStore()
    private let modelManager = ModelManager()
    private let systemCapture = SystemAudioCaptureService()
    private let microphoneCapture = MicrophoneCaptureService()
    private let coordinator = LiveSubtitleCoordinator(engine: WhisperLiveTranslationEngine())
    private var installedModel: InstalledModel?
    private var activeCapture: (any AudioCaptureService)?
    private var modelDownloadTask: Task<Void, Never>?
    private var isPaused = false
    private var diagnosticLogURL: URL?
    private var receivedChunkCount = 0
    private var captureSessionID = UUID()
    private var lastDiagnosticStatus: String?
    private var lastDiagnosticOverlayText: String?
    private let sourceDraftPresentationDelay: TimeInterval = 0.12
    private let minimumSourceDraftReplacementInterval: TimeInterval = 0.3
    private let stableDraftPresentationDelay: TimeInterval = 0.5
    private let unsettledDraftPresentationDelay: TimeInterval = 1.3
    private let minimumDraftReplacementInterval: TimeInterval = 1.2
    private var pendingSourceDraftTask: Task<Void, Never>?
    private var pendingSourceDraftText: String?
    private var sourceDraftPresentationGeneration = 0
    private var lastSourceDraftPresentedAt: Date?
    private var pendingDraftTask: Task<Void, Never>?
    private var pendingDraftEvent: CaptionEvent?
    private var draftPresentationGeneration = 0
    private var lastDraftPresentedAt: Date?
    private var previousRawDraftText: String?
    private var subtitleHistoryBuffer = SubtitleHistoryBuffer(maximumVisibleFinalCaptions: 3)
    private var sessionTranscriptBuffer = SubtitleHistoryBuffer(maximumVisibleFinalCaptions: 80)

    init() {
        systemCapture.onChunk = { [weak self] chunk in
            Task { await self?.handle(chunk: chunk) }
        }
        microphoneCapture.onChunk = { [weak self] chunk in
            Task { await self?.handle(chunk: chunk) }
        }

        Task {
            await loadInitialState()
        }
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
        do {
            if let model = try await modelManager.installedModel(id: settings.selectedModelID) {
                installedModel = model
                isSelectedModelInstalled = true
                modelStatus = "\(model.descriptor.displayName) is installed"
            } else {
                installedModel = nil
                isSelectedModelInstalled = false
                let descriptor = try await modelManager.descriptor(id: settings.selectedModelID)
                modelStatus = "\(descriptor.displayName) needs download"
            }
        } catch {
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

        modelDownloadProgress = 0
        modelStatus = "Downloading local translation model..."
        let modelID = settings.selectedModelID

        modelDownloadTask = Task {
            do {
                let model = try await modelManager.ensureInstalled(id: modelID) { [weak self] progress in
                    Task { @MainActor in
                        self?.modelDownloadProgress = progress
                    }
                }
                guard !Task.isCancelled else {
                    throw CancellationError()
                }
                installedModel = model
                isSelectedModelInstalled = true
                modelStatus = "\(model.descriptor.displayName) is installed"
                modelDownloadProgress = nil
            } catch {
                isSelectedModelInstalled = false
                modelDownloadProgress = nil
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    modelStatus = "Model download canceled"
                } else {
                    modelStatus = error.localizedDescription
                    lastError = error.localizedDescription
                }
            }
            modelDownloadTask = nil
        }
    }

    func cancelModelDownload() {
        modelDownloadTask?.cancel()
        modelDownloadTask = nil
        modelDownloadProgress = nil
        modelStatus = "Model download canceled"
    }

    func startSubtitles() {
        guard !sessionState.isRunning else {
            return
        }

        Task {
            sessionState = .preparing
            lastError = nil
            canOpenPrivacySettings = false
            receivedChunkCount = 0
            captureSessionID = UUID()
            let sessionID = captureSessionID
            updateLiveStatus("Preparing local captioning...")
            isPaused = false

            await refreshModelStatus()
            refreshHelperStatus()
            guard installedModel != nil else {
                sessionState = .failed("Download a local model before starting subtitles.")
                updateLiveStatus("Model needed")
                return
            }

            guard isLocalTranslatorReady else {
                sessionState = .failed("Reinstall CaptionBridge from the DMG so the local translator is included.")
                updateLiveStatus("Local translator needed")
                return
            }

            do {
                let capture: any AudioCaptureService = settings.audioSource == .microphone ? microphoneCapture : systemCapture
                activeCapture = capture
                try await capture.start(source: settings.audioSource)
                overlayController?.show()
                isOverlayVisible = true
                sessionState = .running
                updateLiveStatus(listeningStatus)
                scheduleNoAudioCheck(sessionID: sessionID)
            } catch {
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
            isPaused = true
            sessionState = .paused
        case .paused:
            isPaused = false
            sessionState = .running
        default:
            break
        }
    }

    func stopSubtitles() {
        Task {
            await activeCapture?.stop()
            activeCapture = nil
            isPaused = false
            sessionState = .idle
            canOpenPrivacySettings = false
            captureSessionID = UUID()
            updateLiveStatus("Idle")
            resetActiveCaptionsAfterStop()
        }
    }

    func clearCaptions() {
        resetDraftPresentationState()
        currentSubtitle = ""
        currentSourceText = nil
        draftSubtitle = ""
        draftSourceText = nil
        subtitleHistoryBuffer.clear()
        subtitleHistory = subtitleHistoryBuffer.items
        sessionTranscriptBuffer.clear()
        sessionTranscript = sessionTranscriptBuffer.items
        recordOverlayDisplayIfChanged()
        if sessionState.isRunning {
            updateLiveStatus(listeningStatus)
        }
        Task {
            await coordinator.clear { [weak self] event in
                Task { @MainActor in
                    self?.apply(event: event)
                }
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

    private func handle(chunk: PCMAudioChunk) async {
        guard !isPaused, sessionState.isRunning else {
            return
        }

        guard !chunk.samples.isEmpty else {
            updateLiveStatus("No readable system audio yet")
            return
        }

        receivedChunkCount += 1
        if receivedChunkCount == 1 || receivedChunkCount.isMultiple(of: 25) {
            let rms = AudioProcessing.rms(chunk.samples)
            recordDiagnostic("audio chunk \(receivedChunkCount): samples=\(chunk.samples.count) rms=\(rms)")
        }

        await coordinator.handle(
            chunk: chunk,
            model: installedModel,
            languagePair: settings.languagePair
        ) { [weak self] event in
            Task { @MainActor in
                self?.apply(event: event)
            }
        } status: { [weak self] message in
            Task { @MainActor in
                self?.updateLiveStatus(message)
            }
        }
    }

    var canStartSubtitles: Bool {
        isSelectedModelInstalled && isLocalTranslatorReady && modelDownloadProgress == nil
    }

    private func apply(event: CaptionEvent) {
        switch event.kind {
        case .sourceDraft:
            presentSourceDraft(event.text)
        case .draft:
            scheduleDraftPresentation(for: event)
        case .final:
            resetDraftPresentationState()
            appendFinalCaption(event)
            currentSourceText = event.sourceText
            draftSubtitle = ""
            draftSourceText = nil
            recordDiagnostic("final: \(event.text)")
            updateLiveStatus("Caption updated")
        case .speechStarted:
            resetDraftPresentationState()
            currentSourceText = nil
            draftSubtitle = ""
            draftSourceText = nil
            recordDiagnostic("speech started")
            updateLiveStatus("Listening to the next sentence...")
        case .cleared:
            resetDraftPresentationState()
            currentSubtitle = ""
            currentSourceText = nil
            draftSubtitle = ""
            draftSourceText = nil
            subtitleHistoryBuffer.clear()
            subtitleHistory = subtitleHistoryBuffer.items
            sessionTranscriptBuffer.clear()
            sessionTranscript = sessionTranscriptBuffer.items
            recordDiagnostic("captions cleared")
        case .error:
            resetDraftPresentationState()
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

    private func resetActiveCaptionsAfterStop() {
        resetDraftPresentationState()
        draftSubtitle = ""
        draftSourceText = nil
        recordOverlayDisplayIfChanged()
        Task {
            await coordinator.clear { _ in }
        }
    }

    private func scheduleDraftPresentation(for event: CaptionEvent) {
        let draftLooksStable = previousRawDraftText.map {
            isLikelyStableDraft(previous: $0, candidate: event.text)
        } ?? false
        previousRawDraftText = event.text
        pendingDraftEvent = event

        guard pendingDraftTask == nil else {
            return
        }

        draftPresentationGeneration += 1
        let generation = draftPresentationGeneration
        let delay = draftDelayNanoseconds(from: Date(), draftLooksStable: draftLooksStable)

        pendingDraftTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard let self,
                      !Task.isCancelled,
                      self.draftPresentationGeneration == generation
                else {
                    return
                }

                guard let event = self.pendingDraftEvent else {
                    self.pendingDraftTask = nil
                    return
                }

                self.pendingDraftTask = nil
                self.pendingDraftEvent = nil
                self.draftSubtitle = event.text
                self.draftSourceText = event.sourceText
                self.lastDraftPresentedAt = Date()
                self.recordDiagnostic("draft: \(event.text)")
                self.updateLiveStatus("Caption draft ready")
            }
        }
    }

    private func presentSourceDraft(_ text: String) {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !normalized.isEmpty else {
            return
        }

        pendingSourceDraftText = normalized
        guard pendingSourceDraftTask == nil else {
            return
        }

        sourceDraftPresentationGeneration += 1
        let generation = sourceDraftPresentationGeneration
        let replacementDelay = lastSourceDraftPresentedAt.map {
            max(0, minimumSourceDraftReplacementInterval - Date().timeIntervalSince($0))
        } ?? 0
        let delay = UInt64(max(sourceDraftPresentationDelay, replacementDelay) * 1_000_000_000)

        pendingSourceDraftTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard let self,
                      !Task.isCancelled,
                      self.sourceDraftPresentationGeneration == generation
                else {
                    return
                }

                guard let text = self.pendingSourceDraftText else {
                    self.pendingSourceDraftTask = nil
                    return
                }

                self.pendingSourceDraftTask = nil
                self.pendingSourceDraftText = nil
                self.draftSourceText = text
                self.lastSourceDraftPresentedAt = Date()
                self.recordDiagnostic("source draft: \(text)")
                self.updateLiveStatus("French caption ready")
            }
        }
    }

    private func draftDelayNanoseconds(from date: Date, draftLooksStable: Bool) -> UInt64 {
        let baseDelay = draftLooksStable ? stableDraftPresentationDelay : unsettledDraftPresentationDelay
        let replacementDelay = lastDraftPresentedAt.map {
            max(0, minimumDraftReplacementInterval - date.timeIntervalSince($0))
        } ?? 0

        let delay = max(baseDelay, replacementDelay)
        return UInt64(delay * 1_000_000_000)
    }

    private func isLikelyStableDraft(previous: String, candidate: String) -> Bool {
        let previousWords = normalizedWords(in: previous)
        let candidateWords = normalizedWords(in: candidate)

        guard previousWords.count >= 3, candidateWords.count >= 3 else {
            return false
        }

        let shortestCount = min(previousWords.count, candidateWords.count)
        let sharedPrefixCount = zip(previousWords, candidateWords)
            .prefix { pair in pair.0 == pair.1 }
            .count
        let sharedPrefixRatio = Double(sharedPrefixCount) / Double(shortestCount)
        if sharedPrefixRatio >= 0.8 {
            return true
        }

        let previousSet = Set(previousWords)
        let candidateSet = Set(candidateWords)
        let sharedWordCount = previousSet.intersection(candidateSet).count
        let sharedWordRatio = Double(sharedWordCount) / Double(min(previousSet.count, candidateSet.count))

        return sharedWordRatio >= 0.85
    }

    private func normalizedWords(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func resetDraftPresentationState() {
        cancelPendingDraftPresentation()
        cancelPendingSourceDraftPresentation()
        lastDraftPresentedAt = nil
        previousRawDraftText = nil
        lastSourceDraftPresentedAt = nil
    }

    private func cancelPendingDraftPresentation() {
        draftPresentationGeneration += 1
        pendingDraftEvent = nil
        pendingDraftTask?.cancel()
        pendingDraftTask = nil
    }

    private func cancelPendingSourceDraftPresentation() {
        sourceDraftPresentationGeneration += 1
        pendingSourceDraftText = nil
        pendingSourceDraftTask?.cancel()
        pendingSourceDraftTask = nil
    }

    private var listeningStatus: String {
        settings.audioSource == .microphone ? "Listening for microphone audio..." : "Listening for system audio..."
    }

    private func scheduleNoAudioCheck(sessionID: UUID) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            await MainActor.run {
                guard let self,
                      self.captureSessionID == sessionID,
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
            } else {
                visibleText.append(draftSubtitle)
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

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        let data = Data(line.utf8)

        if FileManager.default.fileExists(atPath: diagnosticLogURL.path),
           let handle = try? FileHandle(forWritingTo: diagnosticLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: diagnosticLogURL, options: [.atomic])
        }
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
        let rawMessage = error.localizedDescription
        let lowercased = rawMessage.lowercased()

        if lowercased.contains("tcc")
            || lowercased.contains("declined")
            || lowercased.contains("screen")
            || lowercased.contains("microphone")
            || lowercased.contains("capture") {
            return true
        }

        return false
    }
}
