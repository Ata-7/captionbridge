@preconcurrency import AVFAudio
import Foundation

/// Bridges AVAudioConverter's legacy sendable callback without exposing its
/// non-Sendable buffer outside the callback's serialized input contract.
final class AVAudioConverterInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !didProvideInput else {
            status.pointee = .noDataNow
            return nil
        }

        didProvideInput = true
        status.pointee = .haveData
        return buffer
    }
}
