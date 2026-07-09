import Foundation

public enum LiveSubtitleCoordinatorError: LocalizedError {
    case modelUnavailable

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "A local Whisper model is not installed yet."
        }
    }
}

public actor LiveSubtitleCoordinator {
    private enum InferenceKind: Equatable {
        case sourceDraft
        case final(wasForced: Bool)

        var isFinal: Bool {
            if case .final = self {
                return true
            }
            return false
        }
    }

    private let engine: any SpeechTranslationEngine
    private let silenceGate: SilenceGate
    private let sampleRate: Int
    private let draftWindowSampleCount: Int
    private let speechAnalysisSampleCount: Int
    private let forcedBoundaryAnalysisSampleCount: Int
    private let minimumInferenceSampleCount: Int
    private let minimumSourceDraftProcessingInterval: TimeInterval
    private let trailingSilenceDuration: TimeInterval
    private let maximumUtteranceDuration: TimeInterval
    private let hardMaximumUtteranceDuration: TimeInterval
    private let finalWindowSampleCount: Int
    private let ringBuffer: FloatRingBuffer

    private var stabilizer = CaptionStabilizer()
    private var finalCaptionFormatter = FinalCaptionFormatter()
    private var isProcessing = false
    private var inferenceTicket = 0
    private var lastSourceDraftProcessingStartedAt = Date.distantPast
    private var lastDraftInferenceDuration: TimeInterval = 0
    private var lastSourceDraft = ""
    private var lastRawSourceDraft = ""
    private var latestSourceText: String?
    private var latestSourceDraftStartSampleIndex: Int64?
    private var latestSourceDraftEndSampleIndex: Int64?
    private var lastSpeechDetectedAt: Date?
    private var speechStartedAt: Date?
    private var speechStartedSampleIndex: Int64?
    private var lastSpeechSampleIndex: Int64?
    private var hasSpeechInBuffer = false
    private var sampleCursor: Int64 = 0
    private var bufferStartSampleIndex: Int64 = 0
    private var generation = 0
    private var finalizingThroughSampleIndex: Int64?
    private var speechStartedAfterFinalizing = false
    private var expectContinuationDraft = false
    private var consecutiveFinalFailures = 0

    public init(
        engine: any SpeechTranslationEngine,
        silenceGate: SilenceGate = SilenceGate(),
        sampleRate: Int = 16_000,
        windowDuration: TimeInterval = 4.8,
        speechAnalysisDuration: TimeInterval = 0.25,
        forcedBoundaryAnalysisDuration: TimeInterval = 0.1,
        minimumInferenceDuration: TimeInterval = 0.65,
        minimumProcessingInterval: TimeInterval = 0.55,
        speechHoldDuration: TimeInterval = 1.6,
        maxUtteranceDuration: TimeInterval = 10.0,
        trailingSilenceDuration: TimeInterval = 0.45,
        maximumUtteranceDuration: TimeInterval = 5.2,
        hardMaximumUtteranceDuration: TimeInterval? = nil
    ) {
        self.engine = engine
        self.silenceGate = silenceGate
        self.sampleRate = sampleRate
        self.draftWindowSampleCount = max(1, Int(Double(sampleRate) * windowDuration))
        self.speechAnalysisSampleCount = max(1, Int(Double(sampleRate) * speechAnalysisDuration))
        self.forcedBoundaryAnalysisSampleCount = max(1, Int(Double(sampleRate) * forcedBoundaryAnalysisDuration))
        self.minimumInferenceSampleCount = max(1, Int(Double(sampleRate) * minimumInferenceDuration))
        self.minimumSourceDraftProcessingInterval = minimumProcessingInterval
        self.trailingSilenceDuration = min(speechHoldDuration, trailingSilenceDuration)
        self.maximumUtteranceDuration = maximumUtteranceDuration
        let defaultHardLimitGrace = min(1.2, max(0.1, maximumUtteranceDuration * 0.25))
        self.hardMaximumUtteranceDuration = max(
            maximumUtteranceDuration,
            hardMaximumUtteranceDuration ?? maximumUtteranceDuration + defaultHardLimitGrace
        )
        self.finalWindowSampleCount = max(1, Int(Double(sampleRate) * (self.hardMaximumUtteranceDuration + 1)))
        self.ringBuffer = FloatRingBuffer(capacity: max(1, Int(Double(sampleRate) * maxUtteranceDuration)))
    }

    public func handle(
        chunk: PCMAudioChunk,
        model: InstalledModel?,
        languagePair: LanguagePair,
        emit: @Sendable (CaptionEvent) -> Void,
        status: @Sendable (String) -> Void = { _ in }
    ) async {
        let chunkStartSampleIndex = sampleCursor
        let droppedCount = ringBuffer.append(chunk.samples)
        bufferStartSampleIndex += Int64(droppedCount)
        sampleCursor += Int64(chunk.samples.count)

        let audioNow = chunk.startedAt.addingTimeInterval(chunk.duration)
        let analysisCount = min(speechAnalysisSampleCount, ringBuffer.count)
        let analysisDuration = TimeInterval(analysisCount) / TimeInterval(sampleRate)
        let isSpeechNow = silenceGate.isSpeech(
            rms: ringBuffer.suffixRMS(speechAnalysisSampleCount),
            duration: analysisDuration
        )

        if isSpeechNow {
            markSpeechDetected(
                at: audioNow,
                chunkStartSampleIndex: chunkStartSampleIndex,
                chunkEndSampleIndex: sampleCursor,
                emit: emit
            )
        }

        guard hasSpeechInBuffer else {
            status("Listening for French speech...")
            return
        }

        guard let model else {
            emit(.error(LiveSubtitleCoordinatorError.modelUnavailable.localizedDescription))
            return
        }

        let trailingSilence = lastSpeechDetectedAt.map { audioNow.timeIntervalSince($0) } ?? 0
        let utteranceDuration = speechStartedAt.map { audioNow.timeIntervalSince($0) } ?? 0
        let shouldFinalize = !isSpeechNow && trailingSilence >= trailingSilenceDuration
        // The normal cap is a soft boundary: after it, finish at the first
        // brief low-energy gap instead of cutting through a spoken word. The
        // hard cap still bounds latency for genuinely nonstop audio.
        let isAtBriefBoundary = ringBuffer.suffixRMS(forcedBoundaryAnalysisSampleCount) < silenceGate.rmsThreshold
        let shouldForceAtBoundary = utteranceDuration >= maximumUtteranceDuration && isAtBriefBoundary
        let shouldForceAtHardLimit = utteranceDuration >= hardMaximumUtteranceDuration
        let shouldForceFinal = shouldForceAtBoundary || shouldForceAtHardLimit

        if shouldFinalize || shouldForceFinal {
            await process(
                kind: .final(wasForced: shouldForceFinal && !shouldFinalize),
                model: model,
                languagePair: languagePair,
                emit: emit,
                status: status
            )
            return
        }

        guard ringBuffer.count >= minimumInferenceSampleCount else {
            status("Building the first caption...")
            return
        }

        // Pace drafts to what the machine can sustain: never faster than the
        // configured interval, and never faster than recent inference speed.
        let draftInterval = max(minimumSourceDraftProcessingInterval, lastDraftInferenceDuration * 1.2)
        guard Date().timeIntervalSince(lastSourceDraftProcessingStartedAt) >= draftInterval else {
            status("Listening to the next sentence...")
            return
        }

        await process(
            kind: .sourceDraft,
            model: model,
            languagePair: languagePair,
            emit: emit,
            status: status
        )
    }

    public func clear(emit: @Sendable (CaptionEvent) -> Void) {
        generation += 1
        inferenceTicket += 1
        resetAudioAndSpeechState()
        stabilizer = CaptionStabilizer()
        finalCaptionFormatter.clear()
        isProcessing = false
        expectContinuationDraft = false
        consecutiveFinalFailures = 0
        emit(.cleared())
    }

    /// Discards buffered audio and speech tracking without touching captions
    /// already shown. Used when the session pauses/resumes so stale pre-pause
    /// audio is never finalized minutes later.
    public func resetSpeechTracking() {
        generation += 1
        inferenceTicket += 1
        resetAudioAndSpeechState()
        isProcessing = false
        expectContinuationDraft = false
        consecutiveFinalFailures = 0
    }

    private func resetAudioAndSpeechState() {
        ringBuffer.removeAll()
        lastSourceDraftProcessingStartedAt = Date.distantPast
        lastDraftInferenceDuration = 0
        lastSourceDraft = ""
        lastRawSourceDraft = ""
        latestSourceText = nil
        latestSourceDraftStartSampleIndex = nil
        latestSourceDraftEndSampleIndex = nil
        lastSpeechDetectedAt = nil
        speechStartedAt = nil
        speechStartedSampleIndex = nil
        lastSpeechSampleIndex = nil
        hasSpeechInBuffer = false
        sampleCursor = 0
        bufferStartSampleIndex = 0
        finalizingThroughSampleIndex = nil
        speechStartedAfterFinalizing = false
    }

    private func markSpeechDetected(
        at date: Date,
        chunkStartSampleIndex: Int64,
        chunkEndSampleIndex: Int64,
        emit: @Sendable (CaptionEvent) -> Void
    ) {
        let isSpeechAfterFinalizing = finalizingThroughSampleIndex.map { chunkStartSampleIndex >= $0 } ?? false
        if !hasSpeechInBuffer || (isSpeechAfterFinalizing && !speechStartedAfterFinalizing) {
            speechStartedAt = date
            let preRoll = Int64(Double(sampleRate) * 0.3)
            speechStartedSampleIndex = max(bufferStartSampleIndex, chunkStartSampleIndex - preRoll)
            emit(.speechStarted(at: date))
            if isSpeechAfterFinalizing {
                speechStartedAfterFinalizing = true
            }
        }

        hasSpeechInBuffer = true
        lastSpeechDetectedAt = date
        lastSpeechSampleIndex = chunkEndSampleIndex
    }

    private func process(
        kind: InferenceKind,
        model: InstalledModel,
        languagePair: LanguagePair,
        emit: @Sendable (CaptionEvent) -> Void,
        status: @Sendable (String) -> Void
    ) async {
        guard !isProcessing else {
            status("Translating speech locally...")
            return
        }

        let windowLimit = kind == .sourceDraft ? draftWindowSampleCount : finalWindowSampleCount
        let sampleCount = min(windowLimit, ringBuffer.count)
        guard sampleCount >= minimumInferenceSampleCount else {
            status("Building the first caption...")
            return
        }

        let samples = ringBuffer.suffix(sampleCount)
        let snapshotEndSampleIndex = sampleCursor
        let snapshotStartSampleIndex = snapshotEndSampleIndex - Int64(samples.count)
        let snapshotStartedAt = Date().addingTimeInterval(-TimeInterval(samples.count) / TimeInterval(sampleRate))
        let localGeneration = generation
        inferenceTicket += 1
        let ticket = inferenceTicket

        if kind.isFinal {
            finalizingThroughSampleIndex = snapshotEndSampleIndex
            speechStartedAfterFinalizing = false
        } else {
            lastSourceDraftProcessingStartedAt = Date()
        }

        isProcessing = true
        let inferenceStartedAt = Date()
        defer {
            // A stale inference (cleared or superseded) must not clobber the
            // state of a newer one.
            if generation == localGeneration && ticket == inferenceTicket {
                isProcessing = false
                if kind.isFinal {
                    finalizingThroughSampleIndex = nil
                    speechStartedAfterFinalizing = false
                }
            }
        }

        status(kind.isFinal ? "Translating speech locally..." : "Transcribing French locally...")
        let inferenceChunk = PCMAudioChunk(samples: samples, sampleRate: sampleRate, startedAt: snapshotStartedAt)

        do {
            let result: SpeechTranslationResult
            if kind.isFinal {
                // Reuse French only when its inference snapshot covered the
                // complete speech range used by this final. Window duration
                // alone is insufficient: an early partial draft can exist for
                // a short sentence that continued speaking afterwards.
                let relevantSpeechStart = speechStartedSampleIndex ?? snapshotStartSampleIndex
                let relevantSpeechEnd = lastSpeechSampleIndex ?? snapshotEndSampleIndex
                let draftsCoverUtterance = latestSourceDraftStartSampleIndex.map { $0 <= relevantSpeechStart } == true
                    && latestSourceDraftEndSampleIndex.map { $0 >= relevantSpeechEnd } == true
                result = try await engine.translateFinal(
                    audio: inferenceChunk,
                    model: model,
                    languagePair: languagePair,
                    preferDualOutput: latestSourceText == nil || !draftsCoverUtterance
                )
            } else {
                result = try await engine.transcribe(audio: inferenceChunk, model: model, languagePair: languagePair)
            }
            guard generation == localGeneration else {
                return
            }

            if !kind.isFinal {
                lastDraftInferenceDuration = Date().timeIntervalSince(inferenceStartedAt)
                emitSourceDraft(
                    result.text,
                    snapshotStartSampleIndex: snapshotStartSampleIndex,
                    snapshotEndSampleIndex: snapshotEndSampleIndex,
                    emit: emit
                )
                return
            }

            consecutiveFinalFailures = 0
            let finalSourceText = result.sourceText ?? latestSourceText
            guard isCredibleFinalCaption(text: result.text, sourceText: finalSourceText) else {
                finishFinalInference(through: snapshotEndSampleIndex)
                status("Listening for French speech...")
                return
            }

            let candidate = CaptionCandidate(
                text: result.text,
                sourceText: finalSourceText,
                isFinal: true,
                startTime: result.startTime,
                endTime: result.endTime
            )

            if var event = stabilizer.ingest(candidate) {
                if case let .final(wasForced) = kind {
                    event = finalCaptionFormatter.format(event, wasForced: wasForced)
                    expectContinuationDraft = wasForced
                }
                emit(event)
            }

            finishFinalInference(through: snapshotEndSampleIndex)
            status("Listening for French speech...")
        } catch {
            guard generation == localGeneration else {
                return
            }

            if case WhisperEngineError.emptyResult = error {
                if kind.isFinal {
                    consecutiveFinalFailures = 0
                    finishFinalInference(through: snapshotEndSampleIndex)
                }
                status("Listening for French speech...")
                return
            }

            guard kind.isFinal else {
                status("Listening to the next sentence...")
                return
            }

            // Keep the audio for one or two retries, but never loop forever
            // on a sentence the engine cannot translate.
            consecutiveFinalFailures += 1
            if consecutiveFinalFailures >= 3 {
                consecutiveFinalFailures = 0
                finishFinalInference(through: snapshotEndSampleIndex)
                status("Skipped a sentence that could not be translated in time.")
                return
            }

            if case WhisperEngineError.timedOut = error {
                status("Still translating this sentence...")
                return
            }

            emit(.error(error.localizedDescription))
        }
    }

    private func finishFinalInference(through sampleIndex: Int64) {
        removeSamples(through: sampleIndex)
        lastSourceDraft = ""
        lastRawSourceDraft = ""
        latestSourceText = nil
        latestSourceDraftStartSampleIndex = nil
        latestSourceDraftEndSampleIndex = nil

        if speechStartedAfterFinalizing {
            hasSpeechInBuffer = true
            if speechStartedAt == nil {
                speechStartedAt = lastSpeechDetectedAt
            }
            return
        }

        hasSpeechInBuffer = false
        lastSpeechDetectedAt = nil
        speechStartedAt = nil
        speechStartedSampleIndex = nil
        lastSpeechSampleIndex = nil
    }

    private func emitSourceDraft(
        _ text: String,
        snapshotStartSampleIndex: Int64,
        snapshotEndSampleIndex: Int64,
        emit: @Sendable (CaptionEvent) -> Void
    ) {
        let normalized = CaptionText.collapseWhitespace(text)

        guard isCredibleSourceDraft(normalized) else {
            return
        }

        defer {
            lastRawSourceDraft = normalized
        }

        let shouldEmit = shouldEmitSourceDraft(normalized)
        guard shouldEmit || normalized == lastSourceDraft else {
            return
        }

        latestSourceText = normalized
        latestSourceDraftStartSampleIndex = snapshotStartSampleIndex
        latestSourceDraftEndSampleIndex = snapshotEndSampleIndex
        expectContinuationDraft = false

        guard normalized != lastSourceDraft else {
            return
        }

        lastSourceDraft = normalized
        emit(.sourceDraft(normalized))
    }

    private func isCredibleSourceDraft(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        let allWords = CaptionText.words(in: trimmed, minimumLength: 1)
        guard allWords.count <= 48, !hasExcessiveConsecutiveRepetition(allWords) else {
            return false
        }

        let lowercased = trimmed.lowercased()
        if lowercased == "..." || lowercased == ".." || lowercased == "." {
            return false
        }

        if looksLikeNonSpeechCaption(lowercased) {
            return false
        }

        let words = sourceDraftWords(in: trimmed)
        return words.count >= 2
    }

    private func hasExcessiveConsecutiveRepetition(_ words: [String]) -> Bool {
        guard words.count >= 6 else {
            return false
        }

        let maximumPhraseLength = min(6, words.count / 3)
        for phraseLength in 1...maximumPhraseLength {
            let requiredRepeats = phraseLength == 1 ? 5 : 3
            let requiredWordCount = phraseLength * requiredRepeats
            guard words.count >= requiredWordCount else {
                continue
            }

            for start in 0...(words.count - requiredWordCount) {
                let phrase = words[start..<(start + phraseLength)]
                var repeats = 1
                while repeats < requiredRepeats {
                    let comparisonStart = start + repeats * phraseLength
                    let comparison = words[comparisonStart..<(comparisonStart + phraseLength)]
                    guard phrase.elementsEqual(comparison) else {
                        break
                    }
                    repeats += 1
                }

                if repeats == requiredRepeats {
                    return true
                }
            }
        }

        return false
    }

    private func isCredibleFinalCaption(text: String, sourceText: String?) -> Bool {
        let translatedWords = sourceDraftWords(in: text)
        let source = sourceText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if source.isEmpty {
            return translatedWords.count >= 5
        }

        let lowercasedSource = source.lowercased()
        if lowercasedSource == "..." || lowercasedSource == ".." || lowercasedSource == "." {
            return false
        }

        if looksLikeNonSpeechCaption(lowercasedSource) {
            return false
        }

        let sourceWords = sourceDraftWords(in: source)
        return translatedWords.count >= 3 || sourceWords.count >= 3
    }

    private func shouldEmitSourceDraft(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = sourceDraftWords(in: trimmed)

        if lastSourceDraft.isEmpty {
            // After a forced mid-sentence final, whisper legitimately starts
            // the continuation lowercase — don't demand sentence casing.
            guard startsLikeSentence(trimmed) || expectContinuationDraft else {
                return false
            }

            // Show the first credible read of a sentence right away when it
            // has enough substance; only very short first reads wait for a
            // second consistent inference. Count every word here — French is
            // full of one-letter words the overlap tokenizer ignores.
            if CaptionText.words(in: trimmed).count >= 3 {
                return true
            }

            let previousWords = sourceDraftWords(in: lastRawSourceDraft)
            return hasMeaningfulOverlap(words, previousWords)
        }

        let previousWords = sourceDraftWords(in: lastSourceDraft)
        let rawPreviousWords = sourceDraftWords(in: lastRawSourceDraft)
        return hasMeaningfulOverlap(words, previousWords)
            || hasMeaningfulOverlap(words, rawPreviousWords)
            || words.count >= 4
    }

    private func looksLikeNonSpeechCaption(_ lowercased: String) -> Bool {
        let stripped = lowercased.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.hasPrefix("*") && stripped.hasSuffix("*") {
            return true
        }
        if stripped.hasPrefix("[") && stripped.hasSuffix("]") {
            return true
        }
        if stripped.hasPrefix("(") && stripped.hasSuffix(")") {
            return true
        }

        let nonSpeechMarkers = [
            "musique",
            "bruit",
            "klaxon",
            "applaud",
            "silence",
            "tap tap",
            "merci d'avoir regardé",
            "merci de regarder",
            "sous-titres réalisés",
            "abonnez-vous"
        ]
        return nonSpeechMarkers.contains { stripped.contains($0) }
    }

    private func startsLikeSentence(_ text: String) -> Bool {
        guard let firstLetter = text.first(where: { $0.isLetter }) else {
            return false
        }

        return firstLetter.isUppercase
    }

    private func hasMeaningfulOverlap(_ words: [String], _ previousWords: [String]) -> Bool {
        CaptionText.overlapRatio(words, previousWords) >= 0.4
    }

    private func sourceDraftWords(in text: String) -> [String] {
        CaptionText.words(in: text, minimumLength: 2)
    }

    private func removeSamples(through sampleIndex: Int64) {
        let removableCount = max(0, min(sampleIndex - bufferStartSampleIndex, Int64(ringBuffer.count)))
        guard removableCount > 0 else {
            return
        }

        ringBuffer.removeFirst(Int(removableCount))
        bufferStartSampleIndex += removableCount
    }
}
