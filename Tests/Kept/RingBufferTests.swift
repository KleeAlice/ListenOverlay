import Foundation
import AVFoundation

@main struct RingBufferTests {
    static func main() {
        let history = AudioRingBuffer()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for i in 0..<48_000 { buffer.floatChannelData![0][i] = 0.1 }
        for _ in 0..<6 { history.append(buffer) }
        precondition(history.snapshot(seconds: 6)?.frameLength == 288_000, "six seconds can be identified without waiting for twelve")
        for _ in 0..<5 { history.append(buffer) }
        precondition(history.snapshot() == nil, "wait for a full 12 second sample")
        history.append(buffer)
        let snapshot = history.snapshot()!
        precondition(snapshot.frameLength == 576_000, "history is bounded at 12 seconds")
        for i in 0..<48_000 { buffer.floatChannelData![0][i] = 0.2 }
        precondition(snapshot.floatChannelData![0][575_999] == 0.1, "snapshot owns its samples")
        history.append(buffer)
        let latest = history.snapshot()!
        precondition(latest.floatChannelData![0][0] == 0.1 && latest.floatChannelData![0][575_999] == 0.2, "rolling history drops oldest samples")
        let short = history.snapshot(seconds: 6)!
        precondition(short.frameLength == 288_000 && short.floatChannelData![0][0] == 0.1 && short.floatChannelData![0][287_999] == 0.2, "short snapshot selects newest chronological samples")
        precondition(history.snapshot(seconds: .nan) == nil && history.snapshot(seconds: 13) == nil, "invalid snapshot durations are rejected")
        history.reset()
        precondition(history.snapshot() == nil, "stop erases usable history")
        print("PASS: 8 bounded audio history checks")
    }
}
