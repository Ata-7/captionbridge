import AVFAudio
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

public enum AudioCaptureError: LocalizedError, Equatable {
    case noDisplayAvailable
    case teamsNotRunning
    case screenCapturePermissionDenied
    case microphonePermissionDenied
    case microphoneUnavailable
    case sampleBufferMissingAudio
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "No display is available for system audio capture."
        case .teamsNotRunning:
            return "Microsoft Teams is not running. Use System Audio or open Teams first."
        case .screenCapturePermissionDenied:
            return "CaptionBridge needs macOS Screen & System Audio Recording permission before it can listen to meeting audio."
        case .microphonePermissionDenied:
            return "CaptionBridge needs macOS Microphone permission before it can listen to microphone audio."
        case .microphoneUnavailable:
            return "No microphone is available. Connect an input device or choose System Audio."
        case .sampleBufferMissingAudio:
            return "ScreenCaptureKit delivered a buffer without readable audio."
        case .unsupportedFormat:
            return "The captured audio format is not supported yet."
        }
    }
}

public final class SystemAudioCaptureService: NSObject, AudioCaptureService, @unchecked Sendable {
    public var onChunk: AudioChunkHandler?
    public var onStopped: (@Sendable (Error?) -> Void)?

    private let outputQueue = DispatchQueue(label: "CaptionBridge.ScreenCaptureKit.Audio")
    private let targetSampleRate = 16_000
    private var stream: SCStream?
    private var converter: AVAudioConverter?

    public override init() {}

    public func start(source: AudioSource) async throws {
        await stop()
        try requestScreenCapturePermissionIfNeeded()

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayAvailable
        }

        let filter = try contentFilter(for: source, display: display, content: content)
        let configuration = SCStreamConfiguration()
        configuration.streamName = "CaptionBridge audio capture"
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        configuration.queueDepth = 3
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    private func requestScreenCapturePermissionIfNeeded() throws {
        guard !CGPreflightScreenCaptureAccess() else {
            return
        }

        guard CGRequestScreenCaptureAccess() else {
            throw AudioCaptureError.screenCapturePermissionDenied
        }
    }

    public func stop() async {
        guard let stream else {
            return
        }

        self.stream = nil
        outputQueue.async { [weak self] in
            self?.converter = nil
        }
        try? await stream.stopCapture()
    }

    private func contentFilter(for source: AudioSource, display: SCDisplay, content: SCShareableContent) throws -> SCContentFilter {
        switch source {
        case .microsoftTeams:
            let teamsApplications = content.applications.filter { application in
                let bundleIdentifier = application.bundleIdentifier.lowercased()
                let applicationName = application.applicationName.lowercased()
                return bundleIdentifier.contains("teams") || applicationName.contains("teams")
            }

            guard !teamsApplications.isEmpty else {
                throw AudioCaptureError.teamsNotRunning
            }

            return SCContentFilter(display: display, including: teamsApplications, exceptingWindows: [])
        case .systemAudio, .microphone:
            return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }
    }

    private func handle(sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid else {
            return
        }

        do {
            let sourceBuffer = try makePCMBuffer(from: sampleBuffer)
            let converted = try convertToWhisperPCM(sourceBuffer)
            let samples = extractMonoSamples(from: converted)
            guard !samples.isEmpty else {
                return
            }

            onChunk?(PCMAudioChunk(samples: samples, sampleRate: targetSampleRate))
        } catch {
            // One unreadable buffer is not a stream failure; skip it.
        }
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let formatDescription = sampleBuffer.formatDescription,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            throw AudioCaptureError.sampleBufferMissingAudio
        }

        let format = AVAudioFormat(streamDescription: streamDescription)
        guard let format else {
            throw AudioCaptureError.unsupportedFormat
        }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioCaptureError.unsupportedFormat
        }

        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw AudioCaptureError.sampleBufferMissingAudio
        }

        return buffer
    }

    private func convertToWhisperPCM(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.unsupportedFormat
        }

        if input.format == outputFormat {
            return input
        }

        if converter == nil || converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: outputFormat)
        }

        guard let converter else {
            throw AudioCaptureError.unsupportedFormat
        }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(Double(input.frameLength) * ratio) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AudioCaptureError.unsupportedFormat
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
            return input
        }

        if let conversionError {
            throw conversionError
        }

        return output
    }

    private func extractMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else {
            return []
        }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            return []
        }

        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }
}

extension SystemAudioCaptureService: SCStreamOutput, SCStreamDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else {
            return
        }

        handle(sampleBuffer: sampleBuffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStopped?(error)
    }
}
