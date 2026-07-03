import Foundation

public enum AudioSource: String, CaseIterable, Codable, Sendable, Identifiable {
    case microsoftTeams
    case systemAudio
    case microphone

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .microsoftTeams:
            return "Microsoft Teams"
        case .systemAudio:
            return "System Audio"
        case .microphone:
            return "Microphone"
        }
    }
}

public enum LanguagePair: String, CaseIterable, Codable, Sendable, Identifiable {
    case frenchToEnglish

    public var id: String { rawValue }
    public var spokenLanguageCode: String { "fr" }
    public var subtitleLanguageCode: String { "en" }
    public var displayName: String { "French -> English" }
}

public enum PrivacyMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case onDeviceOnly

    public var id: String { rawValue }
    public var displayName: String { "On-device only" }
}

public enum SubtitleDisplayMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case bilingual
    case englishOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .englishOnly:
            return "English"
        case .bilingual:
            return "French + English"
        }
    }
}

public enum SubtitleOverlaySize: String, CaseIterable, Codable, Sendable, Identifiable {
    case compact
    case comfortable
    case large

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .compact:
            return "Compact"
        case .comfortable:
            return "Comfortable"
        case .large:
            return "Large"
        }
    }
}

public struct CaptionEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case draft
        case sourceDraft
        case final
        case speechStarted
        case cleared
        case error
    }

    public let kind: Kind
    public let text: String
    public let sourceText: String?
    public let startTime: TimeInterval?
    public let endTime: TimeInterval?
    public let createdAt: Date

    public init(
        kind: Kind,
        text: String = "",
        sourceText: String? = nil,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        createdAt: Date = Date()
    ) {
        self.kind = kind
        self.text = text
        self.sourceText = sourceText
        self.startTime = startTime
        self.endTime = endTime
        self.createdAt = createdAt
    }

    public static func draft(_ text: String, sourceText: String? = nil, at date: Date = Date()) -> CaptionEvent {
        CaptionEvent(kind: .draft, text: text, sourceText: sourceText, createdAt: date)
    }

    public static func sourceDraft(_ text: String, at date: Date = Date()) -> CaptionEvent {
        CaptionEvent(kind: .sourceDraft, text: text, sourceText: text, createdAt: date)
    }

    public static func final(
        _ text: String,
        sourceText: String? = nil,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        at date: Date = Date()
    ) -> CaptionEvent {
        CaptionEvent(
            kind: .final,
            text: text,
            sourceText: sourceText,
            startTime: startTime,
            endTime: endTime,
            createdAt: date
        )
    }

    public static func cleared(at date: Date = Date()) -> CaptionEvent {
        CaptionEvent(kind: .cleared, createdAt: date)
    }

    public static func speechStarted(at date: Date = Date()) -> CaptionEvent {
        CaptionEvent(kind: .speechStarted, createdAt: date)
    }

    public static func error(_ message: String, at date: Date = Date()) -> CaptionEvent {
        CaptionEvent(kind: .error, text: message, createdAt: date)
    }
}

public struct PCMAudioChunk: Equatable, Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public let startedAt: Date

    public init(samples: [Float], sampleRate: Int = 16_000, startedAt: Date = Date()) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.startedAt = startedAt
    }

    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(samples.count) / TimeInterval(sampleRate)
    }
}

public typealias AudioChunkHandler = @Sendable (PCMAudioChunk) -> Void

public protocol AudioCaptureService: AnyObject {
    var onChunk: AudioChunkHandler? { get set }
    func start(source: AudioSource) async throws
    func stop() async
}
