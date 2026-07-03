import AVFoundation
import AVFAudio
import Foundation

public final class MicrophoneCaptureService: AudioCaptureService, @unchecked Sendable {
    public var onChunk: AudioChunkHandler?

    private let engine = AVAudioEngine()
    private let targetSampleRate = 16_000
    private var converter: AVAudioConverter?

    public init() {}

    public func start(source: AudioSource) async throws {
        await stop()
        try await requestMicrophonePermissionIfNeeded()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.unsupportedFormat
        }

        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer, outputFormat: outputFormat)
        }

        engine.prepare()
        try engine.start()
    }

    private func requestMicrophonePermissionIfNeeded() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard isGranted else {
                throw AudioCaptureError.microphonePermissionDenied
            }
        case .denied, .restricted:
            throw AudioCaptureError.microphonePermissionDenied
        @unknown default:
            throw AudioCaptureError.microphonePermissionDenied
        }
    }

    public func stop() async {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        converter = nil
    }

    private func handle(buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        guard let converter else {
            return
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        var didProvideInput = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if didProvideInput {
                status.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            status.pointee = .haveData
            return buffer
        }

        guard conversionError == nil,
              let channelData = output.floatChannelData,
              output.frameLength > 0
        else {
            return
        }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(output.frameLength)))
        onChunk?(PCMAudioChunk(samples: samples, sampleRate: targetSampleRate))
    }
}
