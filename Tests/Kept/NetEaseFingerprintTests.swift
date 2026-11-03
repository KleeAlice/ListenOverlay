import Foundation
import CryptoKit
@preconcurrency import AVFoundation

@main struct NetEaseFingerprintTests {
    static var checks = 0
    static var failures = 0
    static func expect(_ value: Bool, _ message: String) {
        checks += 1
        if !value { failures += 1; print("FAIL: \(message)") }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); expect(false, message) } catch { expect(true, message) }
    }
    static func pcm(seconds: Double, sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        let count = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(count, 1))!
        buffer.frameLength = count
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(count) { buffer.floatChannelData![channel][frame] = sin(Float(frame) * 0.05) * 0.2 }
        }
        return buffer
    }
    static func main() async throws {
        let known = Data("abc".utf8)
        let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        do { try NetEaseRuntimeArchive.verify(known, sha256: digest); expect(true, "known SHA256 vector is accepted") }
        catch { expect(false, "known SHA256 vector is accepted") }
        rejects("tampered runtime is rejected before extraction") { try NetEaseRuntimeArchive.verify(Data("abd".utf8), sha256: digest) }
        let zip = Data([0x50, 0x4b, 3, 4] + Array(repeating: 0, count: 32))
        let header = Data([0x43, 0x72, 0x32, 0x34, 3, 0, 0, 0, 2, 0, 0, 0, 9, 9])
        expect((try? NetEaseRuntimeArchive.zipPayload(from: header + zip)) == zip, "CRX3 variable header is removed without changing ZIP bytes")
        rejects("truncated CRX header is rejected") { _ = try NetEaseRuntimeArchive.zipPayload(from: Data([0x43, 0x72])) }
        rejects("oversized CRX header cannot read past archive") { _ = try NetEaseRuntimeArchive.zipPayload(from: Data([0x43, 0x72, 0x32, 0x34, 3, 0, 0, 0, 255, 255, 255, 255]) + zip) }
        rejects("non-CRX and non-ZIP payloads are rejected") { _ = try NetEaseRuntimeArchive.zipPayload(from: Data(repeating: 0, count: 64)) }
        rejects("legacy CRX format is rejected") {
            var legacy = header + zip; legacy[4] = 2
            _ = try NetEaseRuntimeArchive.zipPayload(from: legacy)
        }
        let normalized = try NetEaseFingerprintEngine.samples(from: pcm(seconds: 6, channels: 2))
        expect(normalized.count == 48_000, "six-second stereo input becomes exactly 48000 mono samples")
        expect(normalized.allSatisfy(\.isFinite), "resampling produces finite PCM")
        expect(normalized.contains { abs($0) > 0.01 }, "resampling preserves the audible signal")
        rejects("short audio is never padded into an apparently valid query") { _ = try NetEaseFingerprintEngine.samples(from: pcm(seconds: 5.5)) }
        rejects("oversized audio cannot silently shift capturedAt") { _ = try NetEaseFingerprintEngine.samples(from: pcm(seconds: 7)) }
        rejects("empty audio is rejected") { _ = try NetEaseFingerprintEngine.samples(from: pcm(seconds: 0)) }
        let invalid = pcm(seconds: 6, sampleRate: 8000); invalid.floatChannelData![0][10] = .nan
        rejects("non-finite audio is rejected") { _ = try NetEaseFingerprintEngine.samples(from: invalid) }
        let missingCache = FileManager.default.temporaryDirectory.appendingPathComponent("listen-fp-offline-\(UUID().uuidString)")
        let engine = NetEaseFingerprintEngine(runtimeDirectory: missingCache)
        do {
            _ = try await engine.fingerprint(buffer: pcm(seconds: 5), capturedAt: Date())
            expect(false, "invalid input fails before downloading runtime")
        } catch NetEaseFingerprintError.invalidAudio { expect(true, "invalid input fails before downloading runtime") }
        catch { expect(false, "invalid input fails before downloading runtime") }
        do {
            _ = try await engine.fingerprint(buffer: pcm(seconds: 6), capturedAt: Date(timeIntervalSinceReferenceDate: .infinity))
            expect(false, "invalid capture timestamp fails before preparing runtime")
        } catch NetEaseFingerprintError.invalidCaptureTime { expect(true, "invalid capture timestamp fails before preparing runtime") }
        catch { expect(false, "invalid capture timestamp fails before preparing runtime") }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.fingerprint(buffer: pcm(seconds: 6), capturedAt: Date())
        }
        do { _ = try await cancelled.value; expect(false, "already cancelled fingerprint does not prepare runtime") }
        catch is CancellationError { expect(true, "already cancelled fingerprint does not prepare runtime") }
        catch { expect(false, "already cancelled fingerprint does not prepare runtime") }
        let cancelledPreparation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await engine.prepare()
        }
        do { try await cancelledPreparation.value; expect(false, "already cancelled prepare stops immediately") }
        catch is CancellationError { expect(true, "already cancelled prepare stops immediately") }
        catch { expect(false, "already cancelled prepare stops immediately") }
        expect(!FileManager.default.fileExists(atPath: missingCache.path), "rejected and cancelled calls create no runtime cache")
        if failures > 0 { print("\(failures) of \(checks) fingerprint checks failed"); exit(1) }
        print("All \(checks) fingerprint checks passed")
    }
}
