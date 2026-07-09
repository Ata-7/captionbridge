import Accelerate
import Foundation

public enum AudioProcessing {
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else {
            return 0
        }

        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(samples.count))
        return value
    }
}

/// Fixed-capacity circular buffer of audio samples. Appending past capacity
/// drops the oldest samples without shifting memory, so per-chunk cost stays
/// O(chunk) instead of O(capacity).
public final class FloatRingBuffer {
    private let capacity: Int
    private var storage: [Float]
    private var head = 0
    private(set) public var count = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = [Float](repeating: 0, count: self.capacity)
    }

    /// Appends samples, dropping the oldest if capacity is exceeded.
    /// Returns how many stored samples were dropped to make room.
    @discardableResult
    public func append(_ samples: [Float]) -> Int {
        guard !samples.isEmpty else {
            return 0
        }

        // If the incoming block alone exceeds capacity, only its tail survives.
        let incoming = samples.count > capacity ? Array(samples.suffix(capacity)) : samples
        let skipped = samples.count - incoming.count

        let overflow = max(0, count + incoming.count - capacity)
        if overflow > 0 {
            head = (head + overflow) % capacity
            count -= overflow
        }

        var writeIndex = (head + count) % capacity
        incoming.withUnsafeBufferPointer { source in
            var copied = 0
            while copied < incoming.count {
                let run = min(incoming.count - copied, capacity - writeIndex)
                storage.withUnsafeMutableBufferPointer { destination in
                    destination.baseAddress!.advanced(by: writeIndex)
                        .update(from: source.baseAddress!.advanced(by: copied), count: run)
                }
                copied += run
                writeIndex = (writeIndex + run) % capacity
            }
        }
        count += incoming.count

        return overflow + skipped
    }

    public func removeFirst(_ removeCount: Int) {
        guard removeCount > 0 else {
            return
        }

        let removable = min(removeCount, count)
        head = (head + removable) % capacity
        count -= removable
    }

    public func suffix(_ suffixCount: Int) -> [Float] {
        guard suffixCount > 0, count > 0 else {
            return []
        }

        let resultCount = min(suffixCount, count)
        var result = [Float](repeating: 0, count: resultCount)
        let start = (head + count - resultCount) % capacity
        let firstRun = min(resultCount, capacity - start)
        result.withUnsafeMutableBufferPointer { destination in
            storage.withUnsafeBufferPointer { source in
                destination.baseAddress!.update(from: source.baseAddress!.advanced(by: start), count: firstRun)
                if firstRun < resultCount {
                    destination.baseAddress!.advanced(by: firstRun)
                        .update(from: source.baseAddress!, count: resultCount - firstRun)
                }
            }
        }
        return result
    }

    /// RMS over the most recent `suffixCount` samples without copying them out.
    public func suffixRMS(_ suffixCount: Int) -> Float {
        guard suffixCount > 0, count > 0 else {
            return 0
        }

        let sampleCount = min(suffixCount, count)
        let start = (head + count - sampleCount) % capacity
        let firstRun = min(sampleCount, capacity - start)
        var sumOfSquares: Float = 0
        storage.withUnsafeBufferPointer { source in
            var partial: Float = 0
            vDSP_svesq(source.baseAddress!.advanced(by: start), 1, &partial, vDSP_Length(firstRun))
            sumOfSquares += partial
            if firstRun < sampleCount {
                vDSP_svesq(source.baseAddress!, 1, &partial, vDSP_Length(sampleCount - firstRun))
                sumOfSquares += partial
            }
        }
        return sqrt(sumOfSquares / Float(sampleCount))
    }

    public func drain() -> [Float] {
        let all = suffix(count)
        removeAll()
        return all
    }

    public func removeAll() {
        head = 0
        count = 0
    }
}

public struct SilenceGate: Equatable, Sendable {
    public var rmsThreshold: Float
    public var minimumSpeechDuration: TimeInterval

    public init(rmsThreshold: Float = 0.01, minimumSpeechDuration: TimeInterval = 0.25) {
        self.rmsThreshold = rmsThreshold
        self.minimumSpeechDuration = minimumSpeechDuration
    }

    public func isSpeech(_ chunk: PCMAudioChunk) -> Bool {
        chunk.duration >= minimumSpeechDuration && AudioProcessing.rms(chunk.samples) >= rmsThreshold
    }

    public func isSpeech(rms: Float, duration: TimeInterval) -> Bool {
        duration >= minimumSpeechDuration && rms >= rmsThreshold
    }
}
