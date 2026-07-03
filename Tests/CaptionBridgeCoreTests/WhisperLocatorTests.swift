import XCTest
@testable import CaptionBridgeCore

final class WhisperLocatorTests: XCTestCase {
    func testLocatorFindsExecutableInSearchRoot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptionBridgeLocatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let helperURL = directory.appendingPathComponent("whisper-cli")
        try "#!/bin/sh\nexit 0\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

        let locator = WhisperExecutableLocator(explicitPath: nil, searchRoots: [directory])

        XCTAssertEqual(locator.locate(), helperURL)
    }

    func testPersistentHelperLocatorFindsExecutableInSearchRoot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptionBridgeHelperLocatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let helperURL = directory.appendingPathComponent("captionbridge-whisper-helper")
        try "#!/bin/sh\nexit 0\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

        let locator = WhisperHelperLocator(explicitPath: nil, searchRoots: [directory])

        XCTAssertEqual(locator.locate(), helperURL)
    }
}
