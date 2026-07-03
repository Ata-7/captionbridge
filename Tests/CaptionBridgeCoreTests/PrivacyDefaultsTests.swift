import XCTest
@testable import CaptionBridgeCore

final class PrivacyDefaultsTests: XCTestCase {
    func testSettingsDefaultToLocalOnlyPrivacy() {
        let settings = AppSettings()

        XCTAssertEqual(settings.privacyMode, .onDeviceOnly)
        XCTAssertFalse(settings.transcriptEnabled)
        XCTAssertFalse(settings.analyticsEnabled)
        XCTAssertFalse(settings.cloudInferenceEnabled)
        XCTAssertEqual(settings.audioSource, .systemAudio)
        XCTAssertEqual(settings.languagePair, .frenchToEnglish)
        XCTAssertEqual(settings.subtitleDisplayMode, .bilingual)
        XCTAssertEqual(settings.subtitleOverlaySize, .compact)
        XCTAssertEqual(settings.selectedModelID, "ggml-medium")
        XCTAssertTrue(settings.bilingualDefaultMigrationCompleted)
        XCTAssertTrue(settings.modelQualityMigrationCompleted)
    }

    func testSettingsDecodeOldFilesWithoutOverlaySizeAndPreserveDisplayMode() throws {
        let data = """
        {
          "audioSource": "systemAudio",
          "languagePair": "frenchToEnglish",
          "privacyMode": "onDeviceOnly",
          "subtitleDisplayMode": "englishOnly",
          "selectedModelID": "small",
          "transcriptEnabled": false,
          "analyticsEnabled": false,
          "cloudInferenceEnabled": false
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.subtitleDisplayMode, .englishOnly)
        XCTAssertEqual(settings.subtitleOverlaySize, .compact)
        XCTAssertEqual(settings.selectedModelID, "ggml-small")
        XCTAssertFalse(settings.bilingualDefaultMigrationCompleted)
        XCTAssertFalse(settings.modelQualityMigrationCompleted)
        XCTAssertFalse(settings.transcriptEnabled)
    }

    func testSettingsDecodeOlderFilesWithoutDisplayModeAsBilingual() throws {
        let data = """
        {
          "audioSource": "systemAudio",
          "languagePair": "frenchToEnglish",
          "privacyMode": "onDeviceOnly",
          "selectedModelID": "small",
          "transcriptEnabled": false,
          "analyticsEnabled": false,
          "cloudInferenceEnabled": false
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.subtitleDisplayMode, .bilingual)
        XCTAssertEqual(settings.subtitleOverlaySize, .compact)
        XCTAssertEqual(settings.selectedModelID, "ggml-small")
        XCTAssertFalse(settings.bilingualDefaultMigrationCompleted)
        XCTAssertFalse(settings.modelQualityMigrationCompleted)
        XCTAssertFalse(settings.transcriptEnabled)
    }

    func testSettingsCanonicalizeLegacyModelIDs() throws {
        let data = """
        {
          "selectedModelID": "medium"
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.selectedModelID, "ggml-medium")
    }
}
