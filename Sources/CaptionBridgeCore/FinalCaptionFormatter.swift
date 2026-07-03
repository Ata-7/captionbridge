import Foundation

public struct FinalCaptionFormatter: Equatable, Sendable {
    private var previousCaptionContinues = false

    public init() {}

    public mutating func format(_ event: CaptionEvent, wasForced: Bool) -> CaptionEvent {
        var text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if previousCaptionContinues, !text.hasPrefix("...") {
            text = "... " + text
        }

        let continues = wasForced && !Self.hasTerminalPunctuation(text)
        if continues, !text.hasSuffix("...") {
            text += "..."
        }

        previousCaptionContinues = continues

        return .final(
            text,
            sourceText: event.sourceText,
            startTime: event.startTime,
            endTime: event.endTime,
            at: event.createdAt
        )
    }

    public mutating func clear() {
        previousCaptionContinues = false
    }

    private static func hasTerminalPunctuation(_ text: String) -> Bool {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last,
              "\"')]}".contains(last) {
            trimmed.removeLast()
        }

        guard let last = trimmed.last else {
            return false
        }

        return ".!?".contains(last)
    }
}
