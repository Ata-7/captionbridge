import Foundation

/// Shared text helpers used across the caption pipeline so that every layer
/// tokenizes and normalizes captions the same way.
public enum CaptionText {
    /// Collapses interior whitespace runs and trims the ends.
    public static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cleans raw whisper output: strips bracketed non-speech markers,
    /// joins lines, and collapses whitespace.
    public static func sanitizeWhisperOutput(_ output: String) -> String {
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

    /// Lowercased word tokens. `minimumLength` filters out single letters that
    /// whisper often emits while a word is still being spoken.
    public static func words(in text: String, minimumLength: Int = 1) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= minimumLength }
    }

    /// Fraction of `words` also present in `previousWords`, measured against
    /// the shorter of the two lists. Returns 0 when either list is empty.
    public static func overlapRatio(_ words: [String], _ previousWords: [String]) -> Double {
        guard !words.isEmpty, !previousWords.isEmpty else {
            return 0
        }

        let previousSet = Set(previousWords)
        let sharedCount = words.filter { previousSet.contains($0) }.count
        return Double(sharedCount) / Double(min(words.count, previousWords.count))
    }
}
