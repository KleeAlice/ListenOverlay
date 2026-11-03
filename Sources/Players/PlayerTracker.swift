import AppKit

enum TrackSource: Equatable, Sendable {
    /// NetEase Cloud Music's own playback log: song ID, position, works in the background.
    case netEase
    /// macOS system "Now Playing" (QQ 音乐 and others), when a bridge is available.
    case nowPlaying(bundle: String, app: String)
    /// Identified from the Mac's sound.
    case listening
    /// Lyrics picked by hand, timed from the moment they were chosen.
    case manual

    var label: String {
        switch self {
        case .netEase: return "网易云音乐"
        case .nowPlaying(_, let app): return app
        case .listening: return "听歌识曲"
        case .manual: return "手动选择"
        }
    }
    var detail: String {
        switch self {
        case .netEase: return "本机播放状态 · 后台切歌同步"
        case .nowPlaying: return "系统正在播放"
        case .listening: return "根据声音识别"
        case .manual: return "从选择时开始计时"
        }
    }
}

/// One reading of what is playing and where.
struct TrackObservation: Equatable, Sendable {
    var key: String
    var title: String
    var artist: String
    var album: String?
    var duration: Double?
    var position: Double
    var date: Date
    var isPlaying: Bool
    var source: TrackSource
    var netEaseID: Int64?

    var playhead: Playhead { Playhead(position: position, date: date, rate: isPlaying ? 1 : 0) }
}

/// Reads NetEase's playback log off the main thread (files can be several MB).
actor NetEaseLocalFeed {
    private let reader = NetEaseLocalPlaybackReader()
    static let bundleID = "com.netease.163music"

    func observe() -> (running: Bool, observation: TrackObservation?) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            reader.reset()
            return (false, nil)
        }
        let pid = app.processIdentifier
        guard let local = reader.read(processID: pid, outputActive: PlayerAudioOutput.isActive(processID: pid)) else { return (true, nil) }
        let observation = TrackObservation(key: "netease:\(local.songID)", title: local.title, artist: local.artist,
                                           album: local.album.isEmpty ? nil : local.album, duration: local.duration,
                                           position: local.position, date: Date(), isPlaying: local.isPlaying ?? true,
                                           source: .netEase, netEaseID: local.songID)
        return (true, observation)
    }
}

/// Polls the player feeds and reports which supported players are running.
@MainActor final class PlayerTracker {
    struct Players: Equatable {
        var netEase = false
        var qqMusic = false
    }
    var onObservation: ((TrackObservation?) -> Void)?
    var onPlayers: ((Players) -> Void)?
    var followNetEase = true { didSet { if !followNetEase { onObservation?(nil) } } }
    private(set) var players = Players()
    private let netEase = NetEaseLocalFeed()
    private var task: Task<Void, Never>?
    static let qqBundleIDs = ["com.tencent.QQMusicMac", "com.tencent.QQMusic"]

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    private func poll() async {
        let reading = followNetEase ? await netEase.observe() : (running: !NSRunningApplication.runningApplications(withBundleIdentifier: NetEaseLocalFeed.bundleID).isEmpty, observation: nil)
        let qq = Self.qqBundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        let now = Players(netEase: reading.running, qqMusic: qq)
        if now != players { players = now; onPlayers?(now) }
        if followNetEase { onObservation?(reading.observation) }
    }
}
