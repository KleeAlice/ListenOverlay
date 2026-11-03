import Foundation
import AVFoundation

/// Owns a bounded mono PCM history. Written on the capture queue, read by matching tasks.
final class AudioRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = [Float](repeating: 0, count: 576_000)
    private var cursor = 0
    private var count = 0
    private var rate = 48_000.0
    private var lastSound = Date.distantPast

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, !buffer.format.isInterleaved else { return }
        lock.lock(); defer { lock.unlock() }
        if rate != buffer.format.sampleRate {
            rate = buffer.format.sampleRate
            samples = .init(repeating: 0, count: Int(rate * 12))
            cursor = 0; count = 0
        }
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0, !samples.isEmpty else { return }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            var value: Float = 0
            for channel in 0..<channelCount { value += channels[channel][index] }
            value /= Float(channelCount)
            samples[cursor] = value
            cursor = (cursor + 1) % samples.count
            count = min(count + 1, samples.count)
            sum += value * value
        }
        if buffer.frameLength > 0, sqrt(sum / Float(buffer.frameLength)) > 0.002 {
            lastSound = Date()
        }
    }

    func snapshot(seconds: Double = 12) -> AVAudioPCMBuffer? {
        guard seconds.isFinite, (3...12).contains(seconds) else { return nil }
        lock.lock(); defer { lock.unlock() }
        let frameCount = Int(rate * seconds)
        guard frameCount > 0, count >= frameCount, Date().timeIntervalSince(lastSound) < 2,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let target = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let start = (cursor - frameCount + samples.count) % samples.count
        for index in 0..<frameCount { target[index] = samples[(start + index) % samples.count] }
        return buffer
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        count = 0; cursor = 0; lastSound = .distantPast
    }
}
