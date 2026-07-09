import Foundation

public struct CaptionCandidate: Equatable, Sendable {
    public let text: String
    public let sourceText: String?
    public let isFinal: Bool
    public let startTime: TimeInterval?
    public let endTime: TimeInterval?

    public init(
        text: String,
        sourceText: String? = nil,
        isFinal: Bool,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil
    ) {
        self.text = text
        self.sourceText = sourceText
        self.isFinal = isFinal
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// Suppresses back-to-back duplicate final captions. The suppression is
/// time-bounded: whisper re-emitting the same text within a few seconds is a
/// duplicate, but a speaker legitimately repeating a sentence later must
/// still produce a caption.
public struct CaptionStabilizer {
    private var lastFinal = ""
    private var lastFinalAt = Date.distantPast
    private var lastFinalStartTime: TimeInterval?
    private var lastFinalEndTime: TimeInterval?
    private let duplicateSuppressionWindow: TimeInterval

    public init(duplicateSuppressionWindow: TimeInterval = 5) {
        self.duplicateSuppressionWindow = duplicateSuppressionWindow
    }

    public mutating func ingest(_ candidate: CaptionCandidate, at date: Date = Date()) -> CaptionEvent? {
        guard candidate.isFinal else {
            return nil
        }

        let normalized = CaptionText.collapseWhitespace(candidate.text)
        guard !normalized.isEmpty else {
            return nil
        }

        if normalized == lastFinal, date.timeIntervalSince(lastFinalAt) <= duplicateSuppressionWindow {
            let rangesOverlap: Bool
            if let candidateStart = candidate.startTime,
               let candidateEnd = candidate.endTime,
               let lastStart = lastFinalStartTime,
               let lastEnd = lastFinalEndTime {
                rangesOverlap = candidateStart <= lastEnd && lastStart <= candidateEnd
            } else {
                rangesOverlap = true
            }

            if rangesOverlap {
                return nil
            }
        }

        lastFinal = normalized
        lastFinalAt = date
        lastFinalStartTime = candidate.startTime
        lastFinalEndTime = candidate.endTime
        return .final(
            normalized,
            sourceText: candidate.sourceText,
            startTime: candidate.startTime,
            endTime: candidate.endTime,
            at: date
        )
    }

    public mutating func clear(at date: Date = Date()) -> CaptionEvent {
        lastFinal = ""
        lastFinalAt = .distantPast
        lastFinalStartTime = nil
        lastFinalEndTime = nil
        return .cleared(at: date)
    }
}
