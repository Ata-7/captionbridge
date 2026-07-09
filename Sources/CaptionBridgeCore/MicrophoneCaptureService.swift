import AVFoundation
import AVFAudio
import Foundation

public final class MicrophoneCaptureService: AudioCaptureService, @unchecked Sendable {
    public var onChunk: AudioChunkHandler?
    public var onStopped: (@Sendable (Error?) -> Void)?

    private let engine = AVAudioEngine()
    private let targetSampleRate = 16_000
    private let stateQueue = DispatchQueue(label: "CaptionBridge.MicrophoneCapture")
    private var converter: AVAudioConverter?
    private var configurationObserver: NSObjectProtocol?

    public init() {}

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    public func start(source: AudioSource) async throws {
        await stop()
        try await requestMicrophonePermissionIfNeeded()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        // A Mac without any input device reports a 0 Hz format; installing a
        // tap with it raises an uncatchable Objective-C exception.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.microphoneUnavailable
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.unsupportedFormat
        }

        stateQueue.sync {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer, outputFormat: outputFormat)
        }

        if configurationObserver == nil {
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                // The input device changed (e.g. AirPods connected). The tap
                // format is stale; restart the engine path.
                self?.restartAfterConfigurationChange()
            }
        }

        engine.prepare()
        try engine.start()
    }

    private func restartAfterConfigurationChange() {
        engine.inputNode.removeTap(onBus: 0)

        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(targetSampleRate),
                  channels: 1,
                  interleaved: false
              )
        else {
            onStopped?(AudioCaptureError.microphoneUnavailable)
            return
        }

        stateQueue.sync {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer, outputFormat: outputFormat)
        }

        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                onStopped?(error)
            }
        }
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
        stateQueue.sync {
            converter = nil
        }
    }

    private func handle(buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        let activeConverter: AVAudioConverter? = stateQueue.sync {
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            }
            return converter
        }

        guard let activeConverter else {
            return
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        var didProvideInput = false
        var conversionError: NSError?
        activeConverter.convert(to: output, error: &conversionError) { _, status in
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
