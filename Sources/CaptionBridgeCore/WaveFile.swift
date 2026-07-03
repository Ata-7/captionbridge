import Foundation

public enum WaveFileError: Error, Equatable {
    case unsupportedSampleRate
}

public enum WaveFile {
    public static func pcm16Data(from chunk: PCMAudioChunk) throws -> Data {
        guard chunk.sampleRate > 0 else {
            throw WaveFileError.unsupportedSampleRate
        }

        let bytesPerSample = 2
        let channelCount = 1
        let byteRate = chunk.sampleRate * channelCount * bytesPerSample
        let blockAlign = channelCount * bytesPerSample
        let payloadSize = chunk.samples.count * bytesPerSample
        let riffSize = 36 + payloadSize

        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(riffSize))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(channelCount))
        data.appendLittleEndian(UInt32(chunk.sampleRate))
        data.appendLittleEndian(UInt32(byteRate))
        data.appendLittleEndian(UInt16(blockAlign))
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(UInt32(payloadSize))

        for sample in chunk.samples {
            let clamped = min(1, max(-1, sample))
            let intValue = Int16((clamped * Float(Int16.max)).rounded())
            data.appendLittleEndian(UInt16(bitPattern: intValue))
        }

        return data
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
