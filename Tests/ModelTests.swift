import AppKit
import Foundation

/// Answers every lyrics request offline: NetEase lyric JSON for "song/lyric", empty lists elsewhere.
private final class OfflineLyrics: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!.absoluteString
        let body: Data
        if url.contains("song/lyric") {
            let id = URLComponents(string: url)?.queryItems?.first { $0.name == "id" }?.value ?? "0"
            let lrc = "[00:01.00]第一句 \(id)\\n[00:05.00]第二句 \(id)\\n[00:09.00]第三句 \(id)"
            body = Data(#"{"code":200,"lrc":{"lyric":"\#(lrc)"},"tlyric":{"lyric":""}}"#.utf8)
        } else if url.contains("lrclib") {
            body = Data("[]".utf8)
        } else {
            body = Data(#"{"code":200,"result":{"songs":[]},"data":{"song":{"list":[]}},"candidates":[]}"#.utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct ModelTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ label: String) {
        checks += 1
        guard condition else { fputs("FAIL: \(label)\n", stderr); exit(1) }
    }
    static func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.05) -> Bool { abs(a - b) <= tolerance }

    @MainActor static func reading(_ title: String, id: Int64, at position: Double, playing: Bool = true, date: Date = Date()) -> TrackObservation {
        TrackObservation(key: "netease:\(id)", title: title, artist: "测试歌手", album: "测试专辑", duration: 200, position: position, date: date,
                         isPlaying: playing, source: .nowPlaying(bundle: "test", app: "测试播放器"), netEaseID: id)
    }

    @MainActor static func waitFor(_ condition: @MainActor () -> Bool, seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @MainActor static func main() async {
        _ = NSApplication.shared
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineLyrics.self]
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("tj-model-\(UUID().uuidString)")
        let model = AppModel(lyricsService: LyricsService(session: URLSession(configuration: configuration), cacheDirectory: cache))
        model.sources.followNetEase = false
        model.sources.mode = .lyrics

        // A song starts: the clock anchors at once, lyrics arrive by the player's song ID.
        let start = Date()
        model.receiveExternal(reading("歌一", id: 101, at: 30, date: start))
        expect(model.track?.key == "netease:101" && near(model.playhead.position(at: start), 30), "a new song anchors the clock immediately")
        expect(model.lyricsStatus == .searching && model.stage.lines.isEmpty, "lyrics are looked up while the title shows")
        expect(await waitFor { model.stage.lines.count == 3 }, "lyrics for the player's song ID are shown")
        expect(model.stage.lines[0].text == "第一句 101", "the lyrics belong to this song")

        // Small reading jitter must not move the lyrics; a seek must.
        let anchor = model.playhead
        model.receiveExternal(reading("歌一", id: 101, at: 30.3, date: start.addingTimeInterval(0.1)))
        expect(model.playhead == anchor, "sub-second disagreement does not jolt the lyrics")
        model.receiveExternal(reading("歌一", id: 101, at: 80, date: start.addingTimeInterval(0.2)))
        expect(near(model.playhead.position(at: start.addingTimeInterval(0.2)), 80), "a seek re-anchors the clock")

        // Pause freezes, resume continues.
        model.receiveExternal(reading("歌一", id: 101, at: 82, playing: false, date: start.addingTimeInterval(2)))
        expect(!model.playhead.isPlaying && model.pausedSince != nil, "pause stops the clock")
        expect(near(model.playhead.position(at: start.addingTimeInterval(20)), 82), "paused lyrics stay put")
        model.receiveExternal(reading("歌一", id: 101, at: 82, playing: true, date: start.addingTimeInterval(21)))
        expect(model.playhead.isPlaying && model.pausedSince == nil, "resume restarts the clock")

        // Per-song timing offset is remembered.
        model.nudgeOffset(0.5); model.nudgeOffset(0.5)
        expect(near(model.lyricOffset, 1), "offset nudges add up")

        // Background song change: switch instantly, old lyrics never linger.
        model.receiveExternal(reading("歌二", id: 202, at: 3))
        expect(model.track?.key == "netease:202" && model.stage.lines.isEmpty && model.lyricOffset == 0, "a new song clears old lyrics and offset")
        expect(await waitFor { model.stage.lines.first?.text == "第一句 202" }, "the new song's lyrics follow")

        // Back to the first song: its lyrics come from cache and its offset returns.
        model.receiveExternal(reading("歌一", id: 101, at: 10))
        expect(await waitFor { model.stage.lines.first?.text == "第一句 101" && near(model.lyricOffset, 1) }, "returning to a song restores its lyrics and offset")
        expect(model.lyricsFromCache, "the second lookup is served from the cache")

        // Manual lyrics without a player.
        let candidate = model.candidates.first
        expect(candidate != nil, "candidates are listed for switching versions")

        // What the overlay shows.
        // (Caption mode is not switched on here: it would ask macOS for recording permission.)
        expect(model.overlayTrack.id == model.stage.id && !model.showingCaptions, "the overlay follows the current song")

        try? FileManager.default.removeItem(at: cache)
        print("PASS: \(checks) player-following and lyrics-switching checks")
        exit(0)
    }
}
