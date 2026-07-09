import CryptoKit
import XCTest
@testable import CaptionBridgeCore

final class ModelManagerTests: XCTestCase {
    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptionBridgeModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func descriptor(expectedContent: Data, downloadURL: URL? = nil) -> ModelDescriptor {
        ModelDescriptor(
            id: "test-model",
            displayName: "Test model",
            fileName: "test-model.bin",
            downloadURL: downloadURL ?? URL(fileURLWithPath: "/dev/null"),
            expectedSHA256: sha256(expectedContent),
            minimumFileSizeBytes: 4,
            qualityTier: .fastest
        )
    }

    func testCorruptInstalledModelIsRemovedSoItCanBeReplaced() async throws {
        let goodContent = Data("valid model contents".utf8)
        let descriptor = descriptor(expectedContent: goodContent)
        let modelsDirectory = workDirectory.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let installedURL = modelsDirectory.appendingPathComponent(descriptor.fileName)
        try Data("corrupted contents!!".utf8).write(to: installedURL)

        let manager = ModelManager(modelsDirectory: modelsDirectory, descriptors: [descriptor])
        let installed = try await manager.installedModel(id: descriptor.id)

        XCTAssertNil(installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedURL.path))
    }

    func testValidModelIsAcceptedAndValidationIsCached() async throws {
        let content = Data("valid model contents".utf8)
        let descriptor = descriptor(expectedContent: content)
        let modelsDirectory = workDirectory.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try content.write(to: modelsDirectory.appendingPathComponent(descriptor.fileName))

        let manager = ModelManager(modelsDirectory: modelsDirectory, descriptors: [descriptor])
        let first = try await manager.installedModel(id: descriptor.id)
        XCTAssertNotNil(first)

        let cacheURL = modelsDirectory.appendingPathComponent(".validated-models.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        let second = try await manager.installedModel(id: descriptor.id)
        XCTAssertNotNil(second)
    }

    func testEnsureInstalledRejectsBadDownloadWithoutInstallingIt() async throws {
        let goodContent = Data("valid model contents".utf8)
        let badDownload = workDirectory.appendingPathComponent("download.bin")
        try Data("tampered download data".utf8).write(to: badDownload)
        let descriptor = descriptor(expectedContent: goodContent, downloadURL: badDownload)
        let modelsDirectory = workDirectory.appendingPathComponent("models", isDirectory: true)

        let manager = ModelManager(modelsDirectory: modelsDirectory, descriptors: [descriptor])

        do {
            _ = try await manager.ensureInstalled(id: descriptor.id)
            XCTFail("Expected checksum mismatch")
        } catch let error as ModelManagerError {
            guard case .checksumMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let installedURL = modelsDirectory.appendingPathComponent(descriptor.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedURL.path))
    }
}
