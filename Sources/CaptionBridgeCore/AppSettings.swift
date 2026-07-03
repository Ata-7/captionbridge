import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var audioSource: AudioSource
    public var languagePair: LanguagePair
    public var privacyMode: PrivacyMode
    public var subtitleDisplayMode: SubtitleDisplayMode
    public var subtitleOverlaySize: SubtitleOverlaySize
    public var selectedModelID: String
    public var transcriptEnabled: Bool
    public var analyticsEnabled: Bool
    public var cloudInferenceEnabled: Bool
    public var bilingualDefaultMigrationCompleted: Bool
    public var modelQualityMigrationCompleted: Bool

    public init(
        audioSource: AudioSource = .systemAudio,
        languagePair: LanguagePair = .frenchToEnglish,
        privacyMode: PrivacyMode = .onDeviceOnly,
        subtitleDisplayMode: SubtitleDisplayMode = .bilingual,
        subtitleOverlaySize: SubtitleOverlaySize = .compact,
        selectedModelID: String = ModelDescriptor.defaultModelID,
        transcriptEnabled: Bool = false,
        analyticsEnabled: Bool = false,
        cloudInferenceEnabled: Bool = false,
        bilingualDefaultMigrationCompleted: Bool = true,
        modelQualityMigrationCompleted: Bool = true
    ) {
        self.audioSource = audioSource
        self.languagePair = languagePair
        self.privacyMode = privacyMode
        self.subtitleDisplayMode = subtitleDisplayMode
        self.subtitleOverlaySize = subtitleOverlaySize
        self.selectedModelID = selectedModelID
        self.transcriptEnabled = transcriptEnabled
        self.analyticsEnabled = analyticsEnabled
        self.cloudInferenceEnabled = cloudInferenceEnabled
        self.bilingualDefaultMigrationCompleted = bilingualDefaultMigrationCompleted
        self.modelQualityMigrationCompleted = modelQualityMigrationCompleted
    }

    private enum CodingKeys: String, CodingKey {
        case audioSource
        case languagePair
        case privacyMode
        case subtitleDisplayMode
        case subtitleOverlaySize
        case selectedModelID
        case transcriptEnabled
        case analyticsEnabled
        case cloudInferenceEnabled
        case bilingualDefaultMigrationCompleted
        case modelQualityMigrationCompleted
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.audioSource = try values.decodeIfPresent(AudioSource.self, forKey: .audioSource) ?? .systemAudio
        self.languagePair = try values.decodeIfPresent(LanguagePair.self, forKey: .languagePair) ?? .frenchToEnglish
        self.privacyMode = try values.decodeIfPresent(PrivacyMode.self, forKey: .privacyMode) ?? .onDeviceOnly
        self.subtitleDisplayMode = try values.decodeIfPresent(SubtitleDisplayMode.self, forKey: .subtitleDisplayMode) ?? .bilingual
        self.subtitleOverlaySize = try values.decodeIfPresent(SubtitleOverlaySize.self, forKey: .subtitleOverlaySize) ?? .compact
        self.selectedModelID = Self.canonicalModelID(try values.decodeIfPresent(String.self, forKey: .selectedModelID) ?? ModelDescriptor.defaultModelID)
        self.transcriptEnabled = try values.decodeIfPresent(Bool.self, forKey: .transcriptEnabled) ?? false
        self.analyticsEnabled = try values.decodeIfPresent(Bool.self, forKey: .analyticsEnabled) ?? false
        self.cloudInferenceEnabled = try values.decodeIfPresent(Bool.self, forKey: .cloudInferenceEnabled) ?? false
        self.bilingualDefaultMigrationCompleted = try values.decodeIfPresent(Bool.self, forKey: .bilingualDefaultMigrationCompleted) ?? false
        self.modelQualityMigrationCompleted = try values.decodeIfPresent(Bool.self, forKey: .modelQualityMigrationCompleted) ?? false
    }

    public static func canonicalModelID(_ id: String) -> String {
        switch id {
        case "base":
            return "ggml-base"
        case "small":
            return "ggml-small"
        case "medium":
            return "ggml-medium"
        default:
            return id
        }
    }
}

public actor SettingsStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL = CaptionBridgePaths.settingsURL) {
        self.fileURL = fileURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() async -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL) else {
            return AppSettings()
        }

        return (try? decoder.decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    public func save(_ settings: AppSettings) async throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: [.atomic])
    }
}

public enum CaptionBridgePaths {
    public static let applicationSupportURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (base ?? FileManager.default.temporaryDirectory).appendingPathComponent("CaptionBridge", isDirectory: true)
    }()

    public static let modelsURL: URL = applicationSupportURL.appendingPathComponent("Models", isDirectory: true)
    public static let settingsURL: URL = applicationSupportURL.appendingPathComponent("settings.json")
    public static let toolsURL: URL = applicationSupportURL.appendingPathComponent("Tools", isDirectory: true)
}
