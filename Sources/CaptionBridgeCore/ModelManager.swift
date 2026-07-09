import CryptoKit
import Foundation

public struct ModelDescriptor: Codable, Equatable, Sendable, Identifiable {
    public enum QualityTier: String, Codable, Sendable {
        case fastest
        case balanced
        case highest
    }

    public static let defaultModelID = "ggml-medium"

    public let id: String
    public let displayName: String
    public let fileName: String
    public let downloadURL: URL
    public let expectedSHA256: String?
    public let minimumFileSizeBytes: Int64
    public let qualityTier: QualityTier

    public init(
        id: String,
        displayName: String,
        fileName: String,
        downloadURL: URL,
        expectedSHA256: String? = nil,
        minimumFileSizeBytes: Int64,
        qualityTier: QualityTier
    ) {
        self.id = id
        self.displayName = displayName
        self.fileName = fileName
        self.downloadURL = downloadURL
        self.expectedSHA256 = expectedSHA256
        self.minimumFileSizeBytes = minimumFileSizeBytes
        self.qualityTier = qualityTier
    }

    public static let builtIn: [ModelDescriptor] = [
        ModelDescriptor(
            id: "ggml-base",
            displayName: "Base — fastest, lower accuracy (142 MB)",
            fileName: "ggml-base.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!,
            expectedSHA256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
            minimumFileSizeBytes: 100_000_000,
            qualityTier: .fastest
        ),
        ModelDescriptor(
            id: "ggml-small",
            displayName: "Small — fast, good quality (466 MB)",
            fileName: "ggml-small.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!,
            expectedSHA256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
            minimumFileSizeBytes: 400_000_000,
            qualityTier: .balanced
        ),
        ModelDescriptor(
            id: "ggml-medium-q5",
            displayName: "Medium compact — near-best quality, low memory (514 MB)",
            fileName: "ggml-medium-q5_0.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin")!,
            expectedSHA256: "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f",
            minimumFileSizeBytes: 500_000_000,
            qualityTier: .balanced
        ),
        ModelDescriptor(
            id: "ggml-medium",
            displayName: "Medium — best quality, recommended (1.5 GB)",
            fileName: "ggml-medium.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!,
            expectedSHA256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
            minimumFileSizeBytes: 1_200_000_000,
            qualityTier: .highest
        )
    ]
}

public struct InstalledModel: Equatable, Sendable {
    public let descriptor: ModelDescriptor
    public let localURL: URL

    public init(descriptor: ModelDescriptor, localURL: URL) {
        self.descriptor = descriptor
        self.localURL = localURL
    }
}

public enum ModelManagerError: LocalizedError, Equatable {
    case unknownModel(String)
    case fileTooSmall
    case checksumMismatch(expected: String, actual: String)
    case downloadDidNotFinish
    case badHTTPStatus(Int)

    public var errorDescription: String? {
        switch self {
        case let .unknownModel(id):
            return "Unknown model: \(id)"
        case .fileTooSmall:
            return "The downloaded model file looks incomplete."
        case let .checksumMismatch(expected, actual):
            return "Model checksum mismatch. Expected \(expected), got \(actual)."
        case .downloadDidNotFinish:
            return "The model download did not finish. Please try again."
        case let .badHTTPStatus(status):
            return "The model server returned HTTP \(status). Please try again."
        }
    }
}

private struct ModelValidationFingerprint: Equatable {
    let size: Int64
    let modifiedAt: TimeInterval
    let createdAt: TimeInterval
    let deviceIdentifier: UInt64
    let fileIdentifier: UInt64
    let expectedSHA256: String?
    let minimumFileSizeBytes: Int64
}

private enum ModelValidationStateError: Error {
    case fileChangedDuringValidation
}

/// A successful checksum is trusted only for this process. The lock also
/// prevents separate ModelManager instances from hashing the same file at the
/// same time during startup.
private final class ProcessModelValidationCache: @unchecked Sendable {
    static let shared = ProcessModelValidationCache()

    private let lock = NSLock()
    private var records: [String: ModelValidationFingerprint] = [:]

    func validateIfNeeded(
        key: String,
        fingerprint: ModelValidationFingerprint,
        validation: () throws -> Void,
        currentFingerprint: () throws -> ModelValidationFingerprint
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        guard records[key] != fingerprint else {
            return
        }

        try validation()
        guard try currentFingerprint() == fingerprint else {
            records[key] = nil
            throw ModelValidationStateError.fileChangedDuringValidation
        }
        records[key] = fingerprint
    }

    func record(key: String, fingerprint: ModelValidationFingerprint) {
        lock.lock()
        records[key] = fingerprint
        lock.unlock()
    }

    func forget(key: String) {
        lock.lock()
        records[key] = nil
        lock.unlock()
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: (@Sendable (Double) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var temporaryURL: URL?
    private var didResume = false
    private var isCancelled = false

    init(progress: (@Sendable (Double) -> Void)?) {
        self.progress = progress
    }

    func setContinuation(_ continuation: CheckedContinuation<URL, Error>) -> Bool {
        lock.lock()
        guard !isCancelled else {
            didResume = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let continuation = didResume ? nil : continuation
        if continuation != nil {
            didResume = true
            self.continuation = nil
        }
        let url = temporaryURL
        temporaryURL = nil
        lock.unlock()

        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        continuation?.resume(throwing: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            return
        }

        let fraction = min(0.98, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        progress?(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("CaptionBridgeModel-\(UUID().uuidString).bin")
            try FileManager.default.copyItem(at: location, to: destination)
            lock.lock()
            if isCancelled {
                lock.unlock()
                try? FileManager.default.removeItem(at: destination)
                return
            }
            temporaryURL = destination
            lock.unlock()
        } catch {
            resume(with: .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            removeTemporaryDownload()
            resume(with: .failure(error))
            return
        }

        if let response = task.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            removeTemporaryDownload()
            resume(with: .failure(ModelManagerError.badHTTPStatus(response.statusCode)))
            return
        }

        lock.lock()
        let url = temporaryURL
        lock.unlock()

        if let url {
            progress?(0.99)
            resume(with: .success(url))
        } else {
            resume(with: .failure(ModelManagerError.downloadDidNotFinish))
        }
    }

    private func removeTemporaryDownload() {
        lock.lock()
        let url = temporaryURL
        temporaryURL = nil
        lock.unlock()

        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func resume(with result: Result<URL, Error>) {
        lock.lock()
        guard !didResume, let continuation else {
            lock.unlock()
            return
        }
        didResume = true
        self.continuation = nil
        lock.unlock()

        switch result {
        case let .success(url):
            continuation.resume(returning: url)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

public actor ModelManager {
    private let modelsDirectory: URL
    private let descriptors: [ModelDescriptor]
    private let downloadSessionConfiguration: URLSessionConfiguration
    private var activeDownloads: [String: Task<InstalledModel, Error>] = [:]
    private var didRetireLegacyValidationCache = false

    public init(
        modelsDirectory: URL = CaptionBridgePaths.modelsURL,
        descriptors: [ModelDescriptor] = ModelDescriptor.builtIn
    ) {
        self.modelsDirectory = modelsDirectory
        self.descriptors = descriptors
        downloadSessionConfiguration = .ephemeral
    }

    init(
        modelsDirectory: URL,
        descriptors: [ModelDescriptor],
        downloadSessionConfiguration: URLSessionConfiguration
    ) {
        self.modelsDirectory = modelsDirectory
        self.descriptors = descriptors
        self.downloadSessionConfiguration = downloadSessionConfiguration
    }

    public nonisolated var availableDescriptors: [ModelDescriptor] {
        ModelDescriptor.builtIn
    }

    public func descriptor(id: String) throws -> ModelDescriptor {
        let canonicalID = AppSettings.canonicalModelID(id)
        guard let descriptor = descriptors.first(where: { $0.id == canonicalID }) else {
            throw ModelManagerError.unknownModel(id)
        }

        return descriptor
    }

    public func localURL(for descriptor: ModelDescriptor) -> URL {
        modelsDirectory.appendingPathComponent(descriptor.fileName)
    }

    /// Returns the installed model, verifying integrity once per app process.
    /// Later checks use an in-memory fingerprint; no user-writable persistent
    /// cache can bypass the first SHA-256 verification after launch. A file
    /// that fails verification is deleted so the next download can heal the
    /// install.
    public func installedModel(id: String) throws -> InstalledModel? {
        let descriptor = try descriptor(id: id)
        let url = localURL(for: descriptor)
        retireLegacyValidationCacheIfNeeded()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let fingerprint = try validationFingerprint(for: url, descriptor: descriptor)
            try ProcessModelValidationCache.shared.validateIfNeeded(
                key: validationCacheKey(for: url),
                fingerprint: fingerprint,
                validation: { try validateModel(at: url, descriptor: descriptor) },
                currentFingerprint: { try validationFingerprint(for: url, descriptor: descriptor) }
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            forgetValidation(for: descriptor)
            return nil
        }

        return InstalledModel(descriptor: descriptor, localURL: url)
    }

    public func ensureInstalled(id: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> InstalledModel {
        let descriptor = try descriptor(id: id)
        if let installed = try? installedModel(id: id) {
            return installed
        }

        if let existing = activeDownloads[descriptor.id] {
            return try await withTaskCancellationHandler {
                try await existing.value
            } onCancel: {
                existing.cancel()
            }
        }

        let task = Task<InstalledModel, Error> {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

            let destination = localURL(for: descriptor)
            let temporaryURL = try await downloadModel(descriptor, progress: progress)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }

            // Validate the download BEFORE it replaces anything, so a bad
            // transfer can never leave a corrupt model installed.
            try validateModel(at: temporaryURL, descriptor: descriptor)

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            recordValidation(for: destination, descriptor: descriptor)
            progress?(1)

            return InstalledModel(descriptor: descriptor, localURL: destination)
        }

        activeDownloads[descriptor.id] = task
        defer { activeDownloads[descriptor.id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func validateModel(at url: URL, descriptor: ModelDescriptor) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= descriptor.minimumFileSizeBytes else {
            throw ModelManagerError.fileTooSmall
        }

        guard let expected = descriptor.expectedSHA256 else {
            return
        }

        let digest = try sha256Digest(for: url)
        guard digest.caseInsensitiveCompare(expected) == .orderedSame else {
            throw ModelManagerError.checksumMismatch(expected: expected, actual: digest)
        }
    }

    private var legacyValidationCacheURL: URL {
        modelsDirectory.appendingPathComponent(".validated-models.json")
    }

    private func validationFingerprint(
        for url: URL,
        descriptor: ModelDescriptor
    ) throws -> ModelValidationFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let deviceIdentifier = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let fileIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return ModelValidationFingerprint(
            size: size,
            modifiedAt: modified,
            createdAt: created,
            deviceIdentifier: deviceIdentifier,
            fileIdentifier: fileIdentifier,
            expectedSHA256: descriptor.expectedSHA256?.lowercased(),
            minimumFileSizeBytes: descriptor.minimumFileSizeBytes
        )
    }

    private func recordValidation(for url: URL, descriptor: ModelDescriptor) {
        guard let fingerprint = try? validationFingerprint(for: url, descriptor: descriptor) else {
            return
        }
        ProcessModelValidationCache.shared.record(
            key: validationCacheKey(for: url),
            fingerprint: fingerprint
        )
    }

    private func forgetValidation(for descriptor: ModelDescriptor) {
        ProcessModelValidationCache.shared.forget(
            key: validationCacheKey(for: localURL(for: descriptor))
        )
    }

    private func validationCacheKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func retireLegacyValidationCacheIfNeeded() {
        guard !didRetireLegacyValidationCache else {
            return
        }
        didRetireLegacyValidationCache = true

        let url = legacyValidationCacheURL
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true || values.isSymbolicLink == true
        else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func sha256Digest(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func downloadModel(
        _ descriptor: ModelDescriptor,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let delegate = ModelDownloadDelegate(progress: progress)
        let session = URLSession(
            configuration: downloadSessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if delegate.setContinuation(continuation) {
                    session.downloadTask(with: descriptor.downloadURL).resume()
                }
            }
        } onCancel: {
            delegate.cancel()
            session.invalidateAndCancel()
        }
    }
}
