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

public struct CaptionStabilizer {
    private var lastDraft: String = ""
    private var lastFinal: String = ""

    public init() {}

    public mutating func ingest(_ candidate: CaptionCandidate, at date: Date = Date()) -> CaptionEvent? {
        let normalized = candidate.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        guard !normalized.isEmpty else {
            return nil
        }

        if candidate.isFinal {
            let finalText = bestFinalText(for: normalized)
            guard finalText != lastFinal else {
                return nil
            }
            lastFinal = finalText
            lastDraft = ""
            return .final(
                finalText,
                sourceText: candidate.sourceText,
                startTime: candidate.startTime,
                endTime: candidate.endTime,
                at: date
            )
        }

        guard normalized != lastDraft else {
            return nil
        }
        lastDraft = normalized
        return .draft(normalized, sourceText: candidate.sourceText, at: date)
    }

    public mutating func clear(at date: Date = Date()) -> CaptionEvent {
        lastDraft = ""
        lastFinal = ""
        return .cleared(at: date)
    }

    private func bestFinalText(for candidate: String) -> String {
        guard !lastDraft.isEmpty,
              isLikelyRegression(candidate: candidate, previousDraft: lastDraft)
        else {
            return candidate
        }

        return lastDraft
    }

    private func isLikelyRegression(candidate: String, previousDraft: String) -> Bool {
        let candidateWords = words(in: candidate)
        let draftWords = words(in: previousDraft)

        guard draftWords.count >= 4,
              !candidateWords.isEmpty,
              draftWords.count >= candidateWords.count
        else {
            return false
        }

        let candidateLower = candidate.lowercased()
        let draftLower = previousDraft.lowercased()
        if draftLower.contains(candidateLower) {
            return true
        }

        let draftSet = Set(draftWords)
        let sharedCount = candidateWords.filter { draftSet.contains($0) }.count
        let overlap = Double(sharedCount) / Double(candidateWords.count)
        return overlap >= 0.6
    }

    private func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
