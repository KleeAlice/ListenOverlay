import AppKit
import AVFoundation
import Combine
import SwiftUI

enum LyricsStatus: Equatable {
    case idle, searching, found, instrumental, notFound, failed(String)
}

enum CaptureState: Equatable {
    case off, starting, running, needsPermission, failed(String)
}

@MainActor final class AppModel: ObservableObject {
    // MARK: Settings
    @Published var style = LyricStyle.load() {
        didSet { style.save(); overlayChanged?() }
    }
    @Published var overlay = SettingsStore.load(OverlaySettings.self, key: "overlay.v2", fallback: OverlaySettings()) {
        didSet { SettingsStore.save(overlay, key: "overlay.v2"); overlayChanged?() }
    }
    @Published var sources = SettingsStore.load(SourceSettings.self, key: "sources.v2", fallback: SourceSettings()) {
        didSet { SettingsStore.save(sources, key: "sources.v2"); applySources(previous: oldValue) }
    }

    // MARK: Now playing
    @Published private(set) var track: TrackObservation?
    @Published private(set) var playhead = Playhead.stopped
    @Published private(set) var stage = StageTrack.empty
    @Published private(set) var lyrics: Lyrics?
    @Published private(set) var candidates: [LyricsCandidate] = []
    @Published private(set) var lyricsStatus = LyricsStatus.idle
    @Published private(set) var lyricsFromCache = false
    @Published private(set) var lyricsUserChosen = false
    @Published var lyricOffset = 0.0 {
        didSet {
            guard lyricOffset != oldValue, let query = currentQuery else { return }
            let value = lyricOffset, service = lyricsService
            Task { await service.setOffset(value, for: query) }
        }
    }
    @Published private(set) var players = PlayerTracker.Players()
    @Published private(set) var listeningStatus = ""
    @Published private(set) var pausedSince: Date?
    let artwork = AlbumArtworkStore()

    // MARK: Captions and sound
    @Published private(set) var captureState = CaptureState.off
    @Published private(set) var caption = ""
    @Published private(set) var level: Float = 0

    // MARK: Manual search
    @Published var searchText = ""
    @Published private(set) var searchResults: [LyricsCandidate] = []
    @Published private(set) var searching = false
    @Published private(set) var searchMessage = "输入歌名或歌手，同时搜索网易云、QQ 音乐、酷狗和 LRCLIB"

    var overlayChanged: (() -> Void)?

    let lyricsService: LyricsService
    private let tracker = PlayerTracker()
    private let recognizer = ListeningRecognizer()
    private let capture = SystemAudioCapture()
    private let speech = SpeechEngine()
    private let ring = AudioRingBuffer()
    private var currentQuery: SongQuery?
    private var lookupTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var timer: Timer?
    private var lastSoundAt = Date.distantPast
    private var lastPlayerAt = Date.distantPast
    private var captionAnchor = Date()
    private var observers = Set<AnyCancellable>()

    init(lyricsService: LyricsService = LyricsService()) {
        self.lyricsService = lyricsService
        let engine = speech, history = ring
        capture.onBuffer = { buffer in engine.feed(buffer); history.append(buffer) }
        capture.onLevel = { [weak self] value in Task { @MainActor in self?.receiveLevel(value) } }
        capture.onFailure = { [weak self] error in Task { @MainActor in self?.captureFailed(error) } }
        tracker.onObservation = { [weak self] observation in self?.receivePlayer(observation) }
        tracker.onPlayers = { [weak self] players in self?.players = players }
        tracker.followNetEase = sources.followNetEase
        recognizer.onResult = { [weak self] observation in self?.receiveListening(observation) }
        recognizer.onStatus = { [weak self] message in self?.listeningStatus = message }
        artwork.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tracker.start()
        updateCapture()
    }

    // MARK: What the overlay shows

    var showingCaptions: Bool {
        sources.mode == .captions || (sources.mode == .auto && track == nil && captureState == .running)
    }

    var overlayTrack: StageTrack {
        if showingCaptions {
            let text = caption.isEmpty ? (captureState == .running ? "正在聆听…" : captureMessage) : display(caption)
            return StageTrack(id: "caption", title: "", artist: "", lines: [StageLine(start: 0, end: 0.01, text: text)], timing: .none)
        }
        if track != nil { return stage }
        return .message(idleMessage, id: "idle")
    }

    var overlayPlayhead: Playhead {
        showingCaptions ? Playhead(position: 0, date: captionAnchor, rate: 1) : playhead
    }

    var idleMessage: String {
        if players.netEase { return "等待网易云开始播放…" }
        if players.qqMusic { return sources.listenToIdentify ? "正在听 QQ 音乐的声音识别歌曲…" : "QQ 音乐：在「来源」中打开听歌识曲" }
        return "播放音乐后，歌词会出现在这里"
    }

    var captureMessage: String {
        switch captureState {
        case .off: return "字幕未开启"
        case .starting: return "正在准备本机语音识别…"
        case .running: return "正在聆听…"
        case .needsPermission: return "请允许「听见」录制系统声音"
        case .failed(let message): return message
        }
    }

    func display(_ text: String) -> String { ChineseDisplay.text(text, simplified: sources.simplifiedChinese) }

    // MARK: Player and listening input

    private func receivePlayer(_ observation: TrackObservation?) {
        guard let observation else {
            // A missing reading is not a pause: keep the clock running while NetEase is open.
            if track?.source == .netEase, !players.netEase || !sources.followNetEase { clearTrack() }
            return
        }
        lastPlayerAt = Date()
        if track?.key == observation.key { sync(observation) } else { switchTo(observation) }
    }

    /// A reading from another feed (debug simulation, future bridges); treated like a player.
    func receiveExternal(_ observation: TrackObservation) {
        lastPlayerAt = Date()
        if track?.key == observation.key { sync(observation) } else { switchTo(observation) }
    }

    private func receiveListening(_ observation: TrackObservation) {
        // A player reading is authoritative; listening only fills in when none exists.
        if let track, track.source == .netEase, Date().timeIntervalSince(lastPlayerAt) < 5 { return }
        if track?.key == observation.key { sync(observation) } else { switchTo(observation) }
        listeningStatus = "已识别《\(observation.title)》"
    }

    /// Small disagreements are ignored so lines never jitter; seeks and pauses re-anchor.
    private func sync(_ observation: TrackObservation) {
        let drift = observation.position - playhead.position(at: observation.date)
        let tolerance = observation.source == .listening ? 1.5 : 0.65
        if observation.isPlaying != playhead.isPlaying || abs(drift) > tolerance {
            playhead = observation.playhead
            pausedSince = observation.isPlaying ? nil : (pausedSince ?? Date())
        }
        if track?.duration == nil, observation.duration != nil { track?.duration = observation.duration }
    }

    private func switchTo(_ observation: TrackObservation) {
        track = observation
        playhead = observation.playhead
        pausedSince = observation.isPlaying ? nil : Date()
        lyrics = nil; candidates = []; lyricsStatus = .searching; lyricsFromCache = false; lyricsUserChosen = false
        stage = .message("正在查找歌词…", title: display(observation.title), artist: display(observation.artist), id: "searching-\(observation.key)")
        let query = SongQuery(observation)
        currentQuery = query
        lyricOffset = 0
        artwork.update(enabled: true, reference: observation.netEaseID.map { AlbumArtworkReference.netEase($0) })
        lookup(query, key: observation.key)
        overlayChanged?()
    }

    private func clearTrack() {
        lookupTask?.cancel(); lookupTask = nil
        track = nil; currentQuery = nil; lyrics = nil; candidates = []
        playhead = .stopped; stage = .empty; lyricsStatus = .idle; pausedSince = nil
        artwork.update(enabled: true, reference: nil)
        overlayChanged?()
    }

    // MARK: Lyrics

    private func lookup(_ query: SongQuery, key: String) {
        lookupTask?.cancel()
        let service = lyricsService
        lookupTask = Task { [weak self] in
            for attempt in 0..<3 {
                let result = await service.lookup(query)
                let offset = await service.offset(for: query)
                guard let self, !Task.isCancelled, self.track?.key == key else { return }
                self.apply(result, offset: offset)
                // Retry only when providers failed (network), never for a genuine miss.
                guard result.lyrics == nil, !result.failures.isEmpty, attempt < 2 else { return }
                try? await Task.sleep(for: .seconds(8 * Double(attempt + 1)))
                guard !Task.isCancelled else { return }
            }
        }
    }

    /// Album art for players that give no NetEase ID: borrow a matching NetEase entry.
    private func updateArtwork(from candidates: [LyricsCandidate]) {
        guard track?.netEaseID == nil, track?.source != .manual || candidates.count == 1,
              let match = candidates.first(where: { $0.source == .netEase && $0.tier <= .strong }),
              let id = Int64(match.remoteID), id > 0 else { return }
        artwork.update(enabled: true, reference: .netEase(id))
    }

    /// The picker asks again: the service keeps collecting slower providers after its first answer.
    func refreshCandidates() {
        guard let query = currentQuery, let key = track?.key else { return }
        let service = lyricsService
        Task { [weak self] in
            let result = await service.lookup(query)
            guard let self, self.track?.key == key, result.candidates.count > self.candidates.count else { return }
            self.candidates = result.candidates
            self.updateArtwork(from: result.candidates)
        }
    }

    private func apply(_ result: LyricsLookup, offset: Double) {
        candidates = result.candidates
        updateArtwork(from: result.candidates)
        lyricsFromCache = result.fromCache
        lyricsUserChosen = result.userChosen
        if lyricOffset != offset { lyricOffset = offset }
        if let lyrics = result.lyrics { show(lyrics) } else {
            lyrics = nil
            lyricsStatus = result.failures.isEmpty ? .notFound : .failed(result.failures.joined(separator: "；"))
            stage = .message(result.failures.isEmpty ? "暂未找到歌词" : "歌词服务暂时无法连接，稍后自动重试",
                             title: display(track?.title ?? ""), artist: display(track?.artist ?? ""), id: "missing-\(track?.key ?? "")")
        }
        overlayChanged?()
    }

    private func show(_ lyrics: Lyrics) {
        self.lyrics = lyrics
        lyricsStatus = lyrics.instrumental && !lyrics.isSynced ? .instrumental : .found
        stage = .make(lyrics: lyrics, title: track?.title ?? lyrics.candidate.title, artist: track?.artist ?? lyrics.candidate.artist,
                      duration: track?.duration ?? lyrics.candidate.duration, simplified: sources.simplifiedChinese)
        overlayChanged?()
    }

    /// 「换一个版本」: remembered for this song from now on.
    func use(_ candidate: LyricsCandidate) {
        guard let query = currentQuery, let key = track?.key, track?.source != .manual else { playManually(candidate); return }
        let service = lyricsService
        lyricsStatus = .searching
        Task { [weak self] in
            await service.choose(candidate, for: query)
            do {
                let lyrics = try await service.fetch(candidate)
                guard let self, self.track?.key == key else { return }
                self.lyricsUserChosen = true
                self.show(lyrics)
            } catch {
                self?.lyricsStatus = .failed("这个版本暂时无法下载：\(error.localizedDescription)")
            }
        }
    }

    func resetChoice() {
        guard let query = currentQuery, let key = track?.key else { return }
        let service = lyricsService
        Task { [weak self] in
            await service.clearChoice(for: query)
            self?.lookup(query, key: key)
        }
    }

    func retryLookup() {
        guard let query = currentQuery, let key = track?.key else { return }
        lyricsStatus = .searching
        lookup(query, key: key)
    }

    func nudgeOffset(_ delta: Double) { lyricOffset = ((lyricOffset + delta) * 10).rounded() / 10 }

    func search() {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searchTask?.cancel()
        searching = true; searchMessage = "正在搜索…"
        let service = lyricsService, duration = track?.duration
        searchTask = Task { [weak self] in
            let results = await service.search(text, duration: duration)
            guard let self, !Task.isCancelled else { return }
            self.searchResults = results; self.searching = false
            self.searchMessage = results.isEmpty ? "没有找到，试试「歌名 歌手」" : "共 \(results.count) 个结果"
        }
    }

    /// Without a player: start these lyrics from 0:00 now.
    func playManually(_ candidate: LyricsCandidate) {
        let service = lyricsService
        Task { [weak self] in
            guard let lyrics = try? await service.fetch(candidate), let self else { return }
            let observation = TrackObservation(key: "manual:\(candidate.id)", title: candidate.title, artist: candidate.artist,
                                               album: candidate.album, duration: candidate.duration, position: 0, date: Date(),
                                               isPlaying: true, source: .manual, netEaseID: nil)
            self.lookupTask?.cancel()
            self.track = observation; self.playhead = observation.playhead; self.currentQuery = SongQuery(observation)
            self.candidates = [candidate]; self.lyricOffset = 0; self.pausedSince = nil
            self.artwork.update(enabled: true, reference: nil)
            self.show(lyrics)
        }
    }

    /// Debug: loop the sample lyrics on the real overlay (`--demo`).
    func showDemo() {
        let observation = TrackObservation(key: "demo", title: "听见", artist: "桌面歌词演示", album: nil, duration: StageTrack.demoLength,
                                           position: 0, date: Date(), isPlaying: true, source: .manual, netEaseID: nil)
        lookupTask?.cancel()
        track = observation; playhead = observation.playhead; stage = .demo; lyricsStatus = .idle
        Timer.scheduledTimer(withTimeInterval: StageTrack.demoLength, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.playhead = Playhead(position: 0, date: Date(), rate: 1) }
        }
        overlayChanged?()
    }

    func restartManual() {
        guard let track, track.source == .manual else { return }
        playhead = Playhead(position: 0, date: Date(), rate: 1)
    }

    func toggleManualPause() {
        guard let track, track.source == .manual else { return }
        let now = Date()
        playhead = Playhead(position: playhead.position(at: now), date: now, rate: playhead.isPlaying ? 0 : 1)
        pausedSince = playhead.isPlaying ? nil : now
    }

    // MARK: Sound capture (captions and listening)

    private func applySources(previous: SourceSettings) {
        tracker.followNetEase = sources.followNetEase
        if previous.simplifiedChinese != sources.simplifiedChinese, let lyrics { show(lyrics) }
        if previous.mode != sources.mode || previous.listenToIdentify != sources.listenToIdentify || previous.captionLanguage != sources.captionLanguage {
            if !sources.listenToIdentify { recognizer.reset(); if track?.source == .listening { clearTrack() } }
            let restart = previous.mode != sources.mode || previous.captionLanguage != sources.captionLanguage
            updateCapture(restart: restart)
        }
        overlayChanged?()
    }

    private var needsCapture: Bool { sources.mode != .lyrics || sources.listenToIdentify }
    private var needsSpeech: Bool { sources.mode != .lyrics }

    func updateCapture(restart: Bool = false) {
        if !needsCapture || restart {
            guard captureState != .off else { if needsCapture { startCapture() }; return }
            stopCapture { [weak self] in if self?.needsCapture == true { self?.startCapture() } }
            return
        }
        if captureState == .off { startCapture() }
    }

    func retryCapture() { stopCapture { [weak self] in self?.startCapture() } }

    private func startCapture() {
        captureState = .starting
        caption = ""
        captionAnchor = Date()
        let speechNeeded = needsSpeech, language = sources.captionLanguage
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                if speechNeeded {
                    try await self.speech.start(language: language, onCaption: { [weak self] result in
                        Task { @MainActor in
                            guard let self, self.captureState == .running else { return }
                            self.caption = String(result.text.suffix(160))
                        }
                    }, onStatus: { _ in })
                }
                try await self.capture.start()
                guard !Task.isCancelled else { return }
                self.captureState = .running
            } catch {
                await self.capture.stop(); await self.speech.stop()
                guard !Task.isCancelled else { return }
                self.captureState = SystemAudioCapture.needsPermission(error) ? .needsPermission : .failed(error.localizedDescription)
            }
            self.overlayChanged?()
        }
    }

    private func stopCapture(then next: (@MainActor () -> Void)? = nil) {
        captureTask?.cancel()
        let previous = captureTask
        captureState = .off; level = 0; caption = ""
        ring.reset(); recognizer.reset()
        Task { [weak self] in
            await previous?.value
            await self?.capture.stop(); await self?.speech.stop()
            next?()
        }
    }

    private func captureFailed(_ error: Error) {
        guard captureState == .running || captureState == .starting else { return }
        let temporary = SystemAudioCapture.isTemporary(error)
        captureState = SystemAudioCapture.needsPermission(error) ? .needsPermission : .failed(error.localizedDescription)
        if temporary {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.needsCapture, case .failed = self.captureState else { return }
                self.retryCapture()
            }
        }
    }

    private func receiveLevel(_ value: Float) {
        guard captureState == .running, value.isFinite else { return }
        level = value
        let now = Date()
        if value > 0.002 {
            if now.timeIntervalSince(lastSoundAt) > 1.5 { recognizer.soundResumed(at: now) }
            lastSoundAt = now
        }
    }

    func openRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }

    // MARK: Clock

    private func tick() {
        let now = Date()
        let soundy = now.timeIntervalSince(lastSoundAt) < 1.5
        if sources.listenToIdentify, captureState == .running, track == nil || track?.source == .listening {
            recognizer.tick(ring: ring, soundy: soundy, identified: track?.source == .listening, now: now)
        }
        // Listening has no player clock: silence pauses, sound resumes.
        if track?.source == .listening {
            if !soundy, playhead.isPlaying {
                playhead = Playhead(position: playhead.position(at: lastSoundAt), date: lastSoundAt, rate: 0); pausedSince = now
            } else if soundy, !playhead.isPlaying {
                playhead = Playhead(position: playhead.position, date: now, rate: 1); pausedSince = nil
            }
        }
        if let duration = track?.duration, track?.source == .manual, playhead.position(at: now) > duration + 3 {
            playhead = Playhead(position: duration, date: now, rate: 0)
        }
    }
}
