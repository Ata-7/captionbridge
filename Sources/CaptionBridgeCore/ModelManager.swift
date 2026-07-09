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

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: (@Sendable (Double) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var temporaryURL: URL?
    private var didResume = false

    init(progress: (@Sendable (Double) -> Void)?) {
        self.progress = progress
    }

    func setContinuation(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
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
    private struct ValidationRecord: Codable {
        var size: Int64
        var modifiedAt: TimeInterval
        var expectedSHA256: String?
    }

    private let modelsDirectory: URL
    private let descriptors: [ModelDescriptor]
    private var activeDownloads: [String: Task<InstalledModel, Error>] = [:]
    private var validationCache: [String: ValidationRecord]?

    public init(
        modelsDirectory: URL = CaptionBridgePaths.modelsURL,
        descriptors: [ModelDescriptor] = ModelDescriptor.builtIn
    ) {
        self.modelsDirectory = modelsDirectory
        self.descriptors = descriptors
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

    /// Returns the installed model, verifying integrity. The expensive
    /// SHA-256 runs only the first time a given file is seen; afterwards an
    /// unchanged size + modification date is proof enough, so app launches
    /// and session starts don't re-hash gigabytes. A file that fails
    /// verification is deleted so the next download can heal the install.
    public func installedModel(id: String) throws -> InstalledModel? {
        let descriptor = try descriptor(id: id)
        let url = localURL(for: descriptor)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        if isValidatedAndUnchanged(url: url, descriptor: descriptor) {
            return InstalledModel(descriptor: descriptor, localURL: url)
        }

        do {
            try validateModel(at: url, descriptor: descriptor)
        } catch {
            try? FileManager.default.removeItem(at: url)
            forgetValidation(for: descriptor)
            return nil
        }

        recordValidation(for: url, descriptor: descriptor)
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

    private var validationCacheURL: URL {
        modelsDirectory.appendingPathComponent(".validated-models.json")
    }

    private func loadValidationCache() -> [String: ValidationRecord] {
        if let validationCache {
            return validationCache
        }

        let loaded = (try? Data(contentsOf: validationCacheURL))
            .flatMap { try? JSONDecoder().decode([String: ValidationRecord].self, from: $0) } ?? [:]
        validationCache = loaded
        return loaded
    }

    private func fileStats(at url: URL, descriptor: ModelDescriptor) -> ValidationRecord? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }

        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return ValidationRecord(size: size, modifiedAt: modified, expectedSHA256: descriptor.expectedSHA256)
    }

    private func isValidatedAndUnchanged(url: URL, descriptor: ModelDescriptor) -> Bool {
        guard let record = loadValidationCache()[descriptor.fileName],
              let stats = fileStats(at: url, descriptor: descriptor)
        else {
            return false
        }

        // The cache entry is only valid for the checksum it was verified
        // against; a catalog update re-triggers full verification.
        return stats.size == record.size
            && stats.modifiedAt == record.modifiedAt
            && record.expectedSHA256 == descriptor.expectedSHA256
    }

    private func recordValidation(for url: URL, descriptor: ModelDescriptor) {
        guard let stats = fileStats(at: url, descriptor: descriptor) else {
            return
        }

        var cache = loadValidationCache()
        cache[descriptor.fileName] = stats
        validationCache = cache
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: validationCacheURL, options: [.atomic])
        }
    }

    private func forgetValidation(for descriptor: ModelDescriptor) {
        var cache = loadValidationCache()
        cache[descriptor.fileName] = nil
        validationCache = cache
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: validationCacheURL, options: [.atomic])
        }
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
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.setContinuation(continuation)
                session.downloadTask(with: descriptor.downloadURL).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }
}
