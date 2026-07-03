import Foundation

public struct SubtitleHistoryItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let sourceText: String?
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, sourceText: String?, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.sourceText = sourceText
        self.createdAt = createdAt
    }
}

public struct SubtitleHistoryBuffer: Equatable, Sendable {
    public private(set) var items: [SubtitleHistoryItem]
    public let maximumVisibleFinalCaptions: Int
    public let duplicateSuppressionInterval: TimeInterval

    public init(
        maximumVisibleFinalCaptions: Int = 3,
        duplicateSuppressionInterval: TimeInterval = 0.75,
        items: [SubtitleHistoryItem] = []
    ) {
        self.maximumVisibleFinalCaptions = max(1, maximumVisibleFinalCaptions)
        self.duplicateSuppressionInterval = duplicateSuppressionInterval
        self.items = Array(items.suffix(max(1, maximumVisibleFinalCaptions)))
    }

    @discardableResult
    public mutating func appendFinal(_ event: CaptionEvent) -> [SubtitleHistoryItem] {
        let text = event.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !text.isEmpty else {
            return items
        }

        if let last = items.last,
           last.text == text,
           abs(event.createdAt.timeIntervalSince(last.createdAt)) <= duplicateSuppressionInterval {
            return items
        }

        items.append(
            SubtitleHistoryItem(
                text: text,
                sourceText: event.sourceText,
                createdAt: event.createdAt
            )
        )

        if items.count > maximumVisibleFinalCaptions {
            items.removeFirst(items.count - maximumVisibleFinalCaptions)
        }

        return items
    }

    public mutating func clear() {
        items.removeAll()
    }
}
