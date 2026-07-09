import AVFoundation
import AVFAudio
import Foundation

public final class MicrophoneCaptureService: AudioCaptureService, @unchecked Sendable {
    public var onChunk: AudioChunkHandler? {
        get { stateQueue.sync { chunkHandler } }
        set { stateQueue.sync { chunkHandler = newValue } }
    }
    public var onStopped: (@Sendable (Error?) -> Void)? {
        get { stateQueue.sync { stoppedHandler } }
        set { stateQueue.sync { stoppedHandler = newValue } }
    }

    private let engine = AVAudioEngine()
    private let targetSampleRate = 16_000
    private let stateQueue = DispatchQueue(label: "CaptionBridge.MicrophoneCapture")
    private let callbackQueue = DispatchQueue(label: "CaptionBridge.MicrophoneCapture.Callbacks")
    private var converter: AVAudioConverter?
    private var configurationObserver: NSObjectProtocol?
    private var isCapturing = false
    private var chunkHandler: AudioChunkHandler?
    private var stoppedHandler: (@Sendable (Error?) -> Void)?

    public init() {}

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    public func start(source: AudioSource) async throws {
        await stop()
        try await requestMicrophonePermissionIfNeeded()

        try stateQueue.sync {
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

            self.converter = AVAudioConverter(from: inputFormat, to: outputFormat)
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
            isCapturing = true
        }
    }

    private func restartAfterConfigurationChange() {
        stateQueue.async { [weak self] in
            guard let self, self.isCapturing else {
                return
            }

            self.engine.inputNode.removeTap(onBus: 0)

            let inputFormat = self.engine.inputNode.inputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  let outputFormat = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32,
                      sampleRate: Double(self.targetSampleRate),
                      channels: 1,
                      interleaved: false
                  )
            else {
                self.deliverStopped(AudioCaptureError.microphoneUnavailable)
                return
            }

            self.converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            self.engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.handle(buffer: buffer, outputFormat: outputFormat)
            }

            if !self.engine.isRunning {
                self.engine.prepare()
                do {
                    try self.engine.start()
                } catch {
                    self.deliverStopped(error)
                }
            }
        }
    }

    private func deliverStopped(_ error: Error) {
        let handler = stoppedHandler
        callbackQueue.async {
            handler?(error)
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
        stateQueue.sync {
            isCapturing = false
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
            converter = nil
        }
    }

    private func handle(buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        let conversionState: (AVAudioConverter, AudioChunkHandler?)? = stateQueue.sync {
            guard isCapturing else {
                return nil
            }

            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            }

            guard let converter else {
                return nil
            }
            return (converter, chunkHandler)
        }

        guard let (activeConverter, handler) = conversionState else {
            return
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        let inputProvider = AVAudioConverterInputProvider(buffer: buffer)
        var conversionError: NSError?
        activeConverter.convert(to: output, error: &conversionError) { _, status in
            inputProvider.next(status: status)
        }

        guard conversionError == nil,
              let channelData = output.floatChannelData,
              output.frameLength > 0
        else {
            return
        }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(output.frameLength)))
        handler?(PCMAudioChunk(samples: samples, sampleRate: targetSampleRate))
    }
}
