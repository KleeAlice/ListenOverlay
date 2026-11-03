import AVFoundation
import Foundation

/// Identifies the playing song from the Mac's sound when no player reports it.
/// A new song needs two agreeing samples (or one plus a matching Shazam reference);
/// re-identifying the current song only re-syncs its position.
@MainActor final class ListeningRecognizer {
    var onResult: ((TrackObservation) -> Void)?
    var onStatus: ((String) -> Void)?
    private let fingerprints = NetEaseFingerprintEngine()
    private let matcher = NetEaseMusicMatcher()
    private let reference = MusicMatcher()
    private var task: Task<Void, Never>?
    private var nextAttempt = Date.distantPast
    private var pending: MusicMatch?
    private var acceptedKey: String?
    private var generation = UUID()

    var busy: Bool { task != nil }

    func reset() {
        generation = UUID(); task?.cancel(); task = nil
        pending = nil; acceptedKey = nil; nextAttempt = .distantPast
    }

    /// Sound came back after a pause: a new song may have started.
    func soundResumed(at now: Date) { nextAttempt = now.addingTimeInterval(6.2); pending = nil }

    func tick(ring: AudioRingBuffer, soundy: Bool, identified: Bool, now: Date = Date()) {
        guard task == nil, soundy, now >= nextAttempt, let buffer = ring.snapshot(seconds: 6) else { return }
        nextAttempt = now.addingTimeInterval(identified ? 25 : 8)
        let token = generation
        onStatus?(identified ? "正在核对当前歌曲…" : "正在听歌识曲…")
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.task = nil } }
            do {
                let fingerprint = try await self.fingerprints.fingerprint(buffer: buffer, capturedAt: now)
                let candidate = try await self.matcher.recognize(fingerprint: fingerprint)
                guard self.generation == token, !Task.isCancelled else { return }
                guard let candidate, let position = candidate.position else {
                    self.pending = nil
                    self.onStatus?(identified ? "未能再次确认，继续当前歌曲" : "暂未听出这首歌，稍后再试")
                    return
                }
                let key = candidate.catalogKey ?? "listen:\(candidate.title)\u{0}\(candidate.artist)"
                var accept = key == self.acceptedKey || self.pending?.identity == candidate.identity
                if !accept, let shazam = try? await self.reference.recognize(buffer: buffer) {
                    guard self.generation == token else { return }
                    accept = MusicCorroboration.agrees(candidate: candidate, reference: shazam)
                }
                guard accept else {
                    self.pending = candidate
                    self.nextAttempt = Date().addingTimeInterval(3)
                    self.onStatus?("听到可能是《\(candidate.title)》，正在再确认一次…")
                    return
                }
                self.pending = nil; self.acceptedKey = key
                self.onResult?(TrackObservation(key: key, title: candidate.title, artist: candidate.artist, album: candidate.album,
                                                duration: candidate.duration, position: position, date: candidate.matchedAt,
                                                isPlaying: true, source: .listening, netEaseID: candidate.netEaseSongID))
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                if case MusicMatcherError.rateLimited(let until) = error { self.nextAttempt = until }
                self.onStatus?("听歌识曲暂时不可用：\(error.localizedDescription)")
            }
        }
    }
}
