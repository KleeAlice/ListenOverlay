import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures only system playback. No microphone or video output is registered.
/// The owned PCM-copy pattern is informed by Audicap (MIT),
/// https://github.com/ShinoKana/audicap/blob/main/AudicapApp.swift.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let stateLock = NSLock()
    private let audioQueue = DispatchQueue(label: "app.listenoverlay.system-audio", qos: .userInitiated)
    private var stream: SCStream?
    private var generation = 0
    // Accessed exclusively by audioQueue.
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var lastLevelTime = 0.0
    private var reportedConversionFailure = false
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                             channels: 1, interleaved: false)!

    enum CaptureError: LocalizedError {
        case permission, noDisplay, invalidAudio
        var errorDescription: String? {
            switch self {
            case .permission:
                return "请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许「听见」，然后退出并重新打开应用。"
            case .noDisplay: return "未找到可采集声音的显示器。请连接或唤醒显示器后重试。"
            case .invalidAudio: return "系统声音格式暂时不可用，请停止后重新开始。"
            }
        }
    }

    static func isTemporary(_ error: Error) -> Bool {
        if let own = error as? CaptureError, case .noDisplay = own { return true }
        let value = error as NSError
        return value.domain == SCStreamErrorDomain && [SCStreamError.Code.noCaptureSource.rawValue,
            SCStreamError.Code.noDisplayList.rawValue, SCStreamError.Code.failedApplicationConnectionInterrupted.rawValue,
            SCStreamError.Code.systemStoppedStream.rawValue].contains(value.code)
    }
    static func needsPermission(_ error: Error) -> Bool {
        if let own = error as? CaptureError, case .permission = own { return true }
        let value = error as NSError
        return value.domain == SCStreamErrorDomain && value.code == SCStreamError.Code.userDeclined.rawValue
    }

    func start() async throws {
        await stop()
        let token = stateLock.withLock { generation += 1; return generation }
        do {
            // The system presents its recording permission prompt on first use.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            try checkCurrent(token)
            guard let display = content.displays.first else { throw CaptureError.noDisplay }
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 1
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
            configuration.showsCursor = false
            let capture = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                   configuration: configuration, delegate: self)
            try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await capture.startCapture()
            let installed = stateLock.withLock { () -> Bool in
                guard generation == token, !Task.isCancelled else { return false }
                stream = capture
                return true
            }
            guard installed else {
                try? await capture.stopCapture()
                throw CancellationError()
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userDeclined.rawValue {
                throw CaptureError.permission
            }
            throw error
        }
    }

    func stop() async {
        let previous = stateLock.withLock { () -> SCStream? in
            generation += 1
            let value = stream
            stream = nil
            return value
        }
        if let previous { try? await previous.stopCapture() }
        await withCheckedContinuation { continuation in
            audioQueue.async {
                self.converter = nil
                self.sourceFormat = nil
                self.lastLevelTime = 0
                self.reportedConversionFailure = false
                continuation.resume()
            }
        }
    }

    private func checkCurrent(_ token: Int) throws {
        guard stateLock.withLock({ generation == token }) && !Task.isCancelled else { throw CancellationError() }
    }

    func stream(_ capture: SCStream, didStopWithError error: Error) {
        let token: Int? = stateLock.withLock {
            guard stream === capture else { return nil }
            stream = nil
            return generation
        }
        guard let token else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stateLock.withLock({ self.generation == token }) else { return }
            self.onFailure?(error)
        }
    }

    func stream(_ capture: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sample) else { return }
        let token: Int? = stateLock.withLock { stream === capture ? generation : nil }
        guard let token else { return }
        do {
            let owned = try Self.copyPCM(from: sample)
            let buffer = try normalized(owned)
            guard buffer.frameLength > 0, stateLock.withLock({ generation == token }) else { return }
            onBuffer?(buffer)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastLevelTime >= 0.1 {
                lastLevelTime = now
                let level = Self.rms(buffer)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.stateLock.withLock({ self.generation == token }) else { return }
                    self.onLevel?(level)
                }
            }
        } catch {
            guard !reportedConversionFailure else { return }
            reportedConversionFailure = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.stateLock.withLock({ self.generation == token }) else { return }
                self.onFailure?(CaptureError.invalidAudio)
            }
        }
    }

    /// Copies the sample before ScreenCaptureKit reuses its underlying memory.
    static func copyPCM(from sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: streamDescription), format.sampleRate > 0 else {
            throw CaptureError.invalidAudio
        }
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw CaptureError.invalidAudio
        }
        buffer.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count),
                                                         into: buffer.mutableAudioBufferList) == noErr else {
            throw CaptureError.invalidAudio
        }
        return buffer
    }

    private func normalized(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if input.format == outputFormat { return input }
        if sourceFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: outputFormat)
            sourceFormat = input.format
        }
        guard let converter else { throw CaptureError.invalidAudio }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw CaptureError.invalidAudio }
        var supplied = false
        var failure: NSError?
        let result = converter.convert(to: output, error: &failure) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard result != .error, failure == nil else { throw CaptureError.invalidAudio }
        return output
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        return sqrt(sum / Float(buffer.frameLength))
    }
}
