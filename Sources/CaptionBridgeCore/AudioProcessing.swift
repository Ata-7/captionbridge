import Foundation

public enum AudioProcessing {
    public static func downmixToMono(interleaved samples: [Float], channelCount: Int) -> [Float] {
        guard channelCount > 1 else {
            return samples
        }
        guard channelCount > 0 else {
            return []
        }

        let frameCount = samples.count / channelCount
        return (0..<frameCount).map { frameIndex in
            let start = frameIndex * channelCount
            let frame = samples[start..<(start + channelCount)]
            return frame.reduce(0, +) / Float(channelCount)
        }
    }

    public static func resampleLinear(samples: [Float], from sourceRate: Int, to targetRate: Int) -> [Float] {
        guard sourceRate > 0, targetRate > 0, !samples.isEmpty else {
            return []
        }

        guard sourceRate != targetRate else {
            return samples
        }

        let duration = Double(samples.count) / Double(sourceRate)
        let outputCount = max(1, Int((duration * Double(targetRate)).rounded()))
        let ratio = Double(sourceRate) / Double(targetRate)

        return (0..<outputCount).map { outputIndex in
            let sourcePosition = Double(outputIndex) * ratio
            let lower = Int(sourcePosition.rounded(.down))
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lower))
            let lowerValue = samples[min(lower, samples.count - 1)]
            let upperValue = samples[upper]
            return lowerValue + (upperValue - lowerValue) * fraction
        }
    }

    public static func normalizeToWhisperRange(_ samples: [Float]) -> [Float] {
        samples.map { sample in
            min(1, max(-1, sample))
        }
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else {
            return 0
        }

        let sumSquares = samples.reduce(Float(0)) { partial, sample in
            partial + sample * sample
        }
        return sqrt(sumSquares / Float(samples.count))
    }
}

public final class FloatRingBuffer {
    private let capacity: Int
    private var storage: [Float] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public var count: Int {
        storage.count
    }

    @discardableResult
    public func append(_ samples: [Float]) -> Int {
        guard !samples.isEmpty else {
            return 0
        }

        storage.append(contentsOf: samples)
        let droppedCount = max(0, storage.count - capacity)
        if droppedCount > 0 {
            storage.removeFirst(droppedCount)
        }

        return droppedCount
    }

    public func removeFirst(_ count: Int) {
        guard count > 0 else {
            return
        }

        storage.removeFirst(min(count, storage.count))
    }

    public func suffix(_ count: Int) -> [Float] {
        guard count > 0 else {
            return []
        }

        return Array(storage.suffix(count))
    }

    public func drain() -> [Float] {
        defer { storage.removeAll(keepingCapacity: true) }
        return storage
    }

    public func removeAll() {
        storage.removeAll(keepingCapacity: true)
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
}
