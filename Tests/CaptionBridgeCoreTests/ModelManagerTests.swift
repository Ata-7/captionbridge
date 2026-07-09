import CryptoKit
import XCTest
@testable import CaptionBridgeCore

private final class BlockingDownloadURLProtocol: URLProtocol {
    private final class CallbackStore: @unchecked Sendable {
        private let lock = NSLock()
        private var didStart: (() -> Void)?
        private var didStop: (() -> Void)?

        func configure(didStart: @escaping () -> Void, didStop: @escaping () -> Void) {
            lock.lock()
            self.didStart = didStart
            self.didStop = didStop
            lock.unlock()
        }

        func takeStart() -> (() -> Void)? {
            lock.lock()
            defer { lock.unlock() }
            let callback = didStart
            didStart = nil
            return callback
        }

        func takeStop() -> (() -> Void)? {
            lock.lock()
            defer { lock.unlock() }
            let callback = didStop
            didStop = nil
            return callback
        }

        func reset() {
            lock.lock()
            didStart = nil
            didStop = nil
            lock.unlock()
        }
    }

    private static let callbacks = CallbackStore()

    static func configure(didStart: @escaping () -> Void, didStop: @escaping () -> Void) {
        callbacks.configure(didStart: didStart, didStop: didStop)
    }

    static func reset() {
        callbacks.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.callbacks.takeStart()?()
    }

    override func stopLoading() {
        Self.callbacks.takeStop()?()
    }
}

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

    func testValidModelIsAcceptedAndValidationIsProcessCachedWithoutWritingMetadata() async throws {
        let content = Data("valid model contents".utf8)
        let descriptor = descriptor(expectedContent: content)
        let modelsDirectory = workDirectory.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let installedURL = modelsDirectory.appendingPathComponent(descriptor.fileName)
        try content.write(to: installedURL)

        let manager = ModelManager(modelsDirectory: modelsDirectory, descriptors: [descriptor])
        let first = try await manager.installedModel(id: descriptor.id)
        XCTAssertNotNil(first)

        let cacheURL = modelsDirectory.appendingPathComponent(".validated-models.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: installedURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: installedURL.path)
        }

        let secondManager = ModelManager(modelsDirectory: modelsDirectory, descriptors: [descriptor])
        let second = try await secondManager.installedModel(id: descriptor.id)
        XCTAssertNotNil(second)
    }

    func testLegacyPersistentCacheIsRetiredAndCannotBypassChecksum() async throws {
        let goodContent = Data("valid model contents".utf8)
        let badContent = Data(repeating: 0x58, count: goodContent.count)
        let descriptor = descriptor(expectedContent: goodContent)
        let modelsDirectory = workDirectory.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let installedURL = modelsDirectory.appendingPathComponent(descriptor.fileName)
        try badContent.write(to: installedURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: installedURL.path)
        let modifiedAt = (attributes[.modificationDate] as! Date).timeIntervalSinceReferenceDate
        let legacyRecord: [String: Any] = [
            descriptor.fileName: [
                "size": badContent.count,
                "modifiedAt": modifiedAt,
                "expectedSHA256": descriptor.expectedSHA256!
            ]
        ]
        let cacheURL = modelsDirectory.appendingPathComponent(".validated-models.json")
        try JSONSerialization.data(withJSONObject: legacyRecord).write(to: cacheURL)

        let manager = ModelManager(modelsDirectory: modelsDirectory, descriptors: [descriptor])
        let installed = try await manager.installedModel(id: descriptor.id)

        XCTAssertNil(installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
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

    func testCancellingEnsureInstalledStopsUnderlyingDownload() async throws {
        let started = expectation(description: "download started")
        let stopped = expectation(description: "download stopped")
        BlockingDownloadURLProtocol.configure(
            didStart: { started.fulfill() },
            didStop: { stopped.fulfill() }
        )
        defer { BlockingDownloadURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlockingDownloadURLProtocol.self]
        let content = Data("valid model contents".utf8)
        let descriptor = descriptor(
            expectedContent: content,
            downloadURL: URL(string: "https://captionbridge.invalid/test-model.bin")!
        )
        let modelsDirectory = workDirectory.appendingPathComponent("models", isDirectory: true)
        let manager = ModelManager(
            modelsDirectory: modelsDirectory,
            descriptors: [descriptor],
            downloadSessionConfiguration: configuration
        )

        let task = Task {
            try await manager.ensureInstalled(id: descriptor.id)
        }
        await fulfillment(of: [started], timeout: 2)

        task.cancel()
        await fulfillment(of: [stopped], timeout: 2)

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let installedURL = modelsDirectory.appendingPathComponent(descriptor.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedURL.path))
    }
}
