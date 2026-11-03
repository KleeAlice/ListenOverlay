import Foundation

/// A controllable wall clock for cache expiry and 429 back-off.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Provider responses shaped like the real ones (trimmed to the fields the module reads).
enum Catalog {
    typealias Reply = StubURLProtocol.Reply

    static func netEaseSongs(_ rows: [(id: Int64, name: String, artists: [String], album: String, seconds: Double)], delay: TimeInterval = 0) -> Reply {
        .json(["code": 200, "result": ["songCount": rows.count, "songs": rows.map { row in
            ["id": row.id, "name": row.name, "artists": row.artists.map { ["name": $0] }, "album": ["name": row.album],
             "duration": Int(row.seconds * 1000), "alias": [String]()] as [String: Any]
        }]], delay: delay)
    }

    static func netEaseLyric(_ lrc: String, translation: String = "", extra: [String: Any] = [:], delay: TimeInterval = 0) -> Reply {
        var body: [String: Any] = ["code": 200, "lrc": ["version": 1, "lyric": lrc], "tlyric": ["version": 0, "lyric": translation]]
        for (key, value) in extra { body[key] = value }
        return .json(body, delay: delay)
    }

    static func qqSongs(_ rows: [(mid: String, title: String, singers: [String], album: String, seconds: Double)], delay: TimeInterval = 0) -> Reply {
        .json(["code": 0, "data": ["song": ["list": rows.map { row in
            ["mid": row.mid, "title": row.title, "name": row.title, "subtitle": "", "interval": Int(row.seconds),
             "singer": row.singers.map { ["name": $0] }, "album": ["name": row.album]] as [String: Any]
        }]]], delay: delay)
    }

    static func qqLyric(_ lrc: String, trans: String = "", delay: TimeInterval = 0) -> Reply {
        .json(["retcode": 0, "code": 0, "subcode": 0, "lyric": lrc, "trans": trans], delay: delay)
    }

    static func kugouCandidates(_ rows: [(id: String, key: String, singer: String, song: String, seconds: Double, score: Int)], delay: TimeInterval = 0) -> Reply {
        .json(["status": 200, "info": "OK", "candidates": rows.map { row in
            ["id": row.id, "accesskey": row.key, "singer": row.singer, "song": row.song, "duration": Int(row.seconds * 1000),
             "score": row.score, "product_from": "官方推荐歌词"] as [String: Any]
        }], delay: delay)
    }

    static func kugouKRC(_ base64: String, delay: TimeInterval = 0) -> Reply {
        .json(["status": 200, "info": "OK", "fmt": "krc", "content": base64], delay: delay)
    }

    static func lrclib(_ rows: [(id: Int64, track: String, artist: String, album: String, seconds: Double, synced: String?, plain: String?)],
                       delay: TimeInterval = 0) -> Reply {
        .json(rows.map { row -> [String: Any] in
            ["id": row.id, "trackName": row.track, "artistName": row.artist, "albumName": row.album, "duration": row.seconds,
             "instrumental": false, "syncedLyrics": row.synced ?? NSNull(), "plainLyrics": row.plain ?? NSNull()]
        }, delay: delay)
    }

    static let qqBody = "[ti:晴天]\n[ar:周杰伦]\n[offset:0]\n[00:00.00]晴天 - 周杰伦 (Jay Chou)\n[00:02.25]词：周杰伦\n[00:04.50]曲：周杰伦\n[00:29.26]It&apos;s 第一句\n[00:32.71]第二句\n[00:36.24]第三句\n"
    static let lrclibBody = "[00:29.36]第一句\n[00:32.77]第二句\n[00:36.15]第三句"

    /// Every provider has 晴天; Kugou carries the real KRC fixture.
    static func qingtianRoutes(kugouDelay: TimeInterval = 0.1, qqDelay: TimeInterval = 0) -> [StubRoute] {
        [
            StubRoute(host: "music.163.com", path: "/api/search/get",
                      reply: netEaseSongs([(2668397359, "晴天 (原唱 周杰伦)", ["RyaVocal"], "晴天", 270.738), (3440441479, "晴天", ["Jay"], "晴天", 112.373)])),
            StubRoute(host: "music.163.com", path: "/api/song/lyric", query: ["id": "2668397359"], reply: netEaseLyric("[00:01.00]翻唱的第一句\n[00:04.00]翻唱的第二句")),
            StubRoute(host: "c.y.qq.com", path: "/soso/fcgi-bin/client_search_cp",
                      reply: qqSongs([("0039MnYb0qxYhV", "晴天", ["周杰伦"], "叶惠美", 269), ("001398Rf3gykz8", "晴天 (Live)", ["周杰伦"], "周杰伦 2004 无与伦比 演唱会 Live CD", 299),
                                      ("001Wiw9y1SeFO4", "晴天 (KTV版伴奏)", ["周杰伦"], "", 269)], delay: qqDelay)),
            StubRoute(host: "c.y.qq.com", path: "/lyric/fcgi-bin/fcg_query_lyric_new.fcg", query: ["songmid": "0039MnYb0qxYhV"], reply: qqLyric(qqBody)),
            StubRoute(host: "c.y.qq.com", path: "/lyric/fcgi-bin/fcg_query_lyric_new.fcg", query: ["songmid": "001398Rf3gykz8"], reply: qqLyric("[00:01.00]现场第一句")),
            StubRoute(host: "lyrics.kugou.com", path: "/search", reply: kugouCandidates([("34988004", "383D2983B550D9A0AAB8FD92EE4E2286", "周杰伦", "晴天", 269, 60)])),
            StubRoute(host: "lyrics.kugou.com", path: "/download", query: ["id": "34988004"], reply: kugouKRC(Fixtures.text("kugou_qingtian.krc.b64"), delay: kugouDelay)),
            StubRoute(host: "lrclib.net", path: "/api/search", reply: lrclib([(36308272, "晴天", "周杰伦", "叶惠美", 270, lrclibBody, "第一句\n第二句\n第三句")])),
        ]
    }

    static func empty(except hosts: Set<String> = []) -> [StubRoute] {
        var routes: [StubRoute] = []
        if !hosts.contains("music.163.com") { routes.append(StubRoute(host: "music.163.com", path: "/api/search/get", reply: netEaseSongs([]))) }
        if !hosts.contains("c.y.qq.com") { routes.append(StubRoute(host: "c.y.qq.com", path: "/soso/fcgi-bin/client_search_cp", reply: qqSongs([]))) }
        if !hosts.contains("lyrics.kugou.com") { routes.append(StubRoute(host: "lyrics.kugou.com", path: "/search", reply: kugouCandidates([]))) }
        if !hosts.contains("lrclib.net") { routes.append(StubRoute(host: "lrclib.net", path: "/api/search", reply: lrclib([]))) }
        return routes
    }
}

@main struct ServiceTests {
    static func service(_ directory: URL, clock: TestClock, limit: Int = 500) -> LyricsService {
        var configuration = LyricsServiceConfiguration()
        configuration.requestTimeout = 1.0
        configuration.softDeadline = 0.25
        configuration.relaxedDeadline = 0.6
        configuration.lookupBudget = 2.5
        configuration.cacheLimit = limit
        configuration.now = { clock.now() }
        return LyricsService(session: StubURLProtocol.makeSession(), cacheDirectory: directory, configuration: configuration)
    }

    static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func main() async {
        var t = Checks("service")
        let clock = TestClock()
        let qingtian = SongQuery(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269)

        // 1. Full lookup: word-timed exact lyrics win; the picker gets every plausible candidate.
        StubRoute.install(Catalog.qingtianRoutes())
        let directory = Fixtures.temporaryDirectory("main")
        let main = service(directory, clock: clock)
        var start = ContinuousClock.now
        let first = await main.lookup(qingtian)
        t.equal(first.lyrics?.candidate.source, .kugou, "word-timed Kugou lyrics chosen")
        t.equal(first.lyrics?.candidate.tier, .exact, "exact tier")
        t.that(first.lyrics?.hasWordTiming == true, "word timing kept")
        t.equal(first.lyrics?.lines.first?.text, "故事的小黄花", "KRC body served")
        t.equal(first.candidates.first?.id, first.lyrics?.candidate.id, "chosen candidate first")
        let sources = Set(first.candidates.map(\.source))
        t.that(sources.isSuperset(of: [.qqMusic, .lrclib, .netEase, .kugou]), "candidates from every provider", "\(sources)")
        t.that(!first.candidates.contains { $0.remoteID == "001Wiw9y1SeFO4" }, "伴奏 not offered")
        t.that(!first.candidates.contains { $0.remoteID == "3440441479" }, "112 s track not offered")
        t.equal(first.candidates.first { $0.remoteID == "001398Rf3gykz8" }?.tier, .version, "live row offered as 相近版本")
        t.that(first.failures.isEmpty && !first.fromCache && !first.userChosen, "clean first lookup", "\(first.failures)")
        t.that(elapsed(since: start) < 1.5, "fast lookup")

        // 2. Cached: no network.
        StubURLProtocol.install { _ in nil }
        let cached = await main.lookup(qingtian)
        t.that(cached.fromCache && cached.lyrics?.candidate.id == first.lyrics?.candidate.id, "second lookup from cache")
        t.equal(StubURLProtocol.requests.count, 0, "cache hit makes no request")
        let jitter = await main.lookup(SongQuery(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 270.4))
        t.that(jitter.fromCache && jitter.lyrics != nil, "duration jitter still hits the cache")

        // 3. A new service instance reads the same disk cache (lyrics, candidates).
        let reopened = service(directory, clock: clock)
        let fromDisk = await reopened.lookup(qingtian)
        t.that(fromDisk.fromCache, "disk cache survives a restart")
        t.equal(fromDisk.lyrics?.lines, first.lyrics?.lines, "cached lines identical")
        t.equal(fromDisk.candidates.map(\.id), first.candidates.map(\.id), "cached candidates identical")

        // 4. User choice wins, persists, and can be cleared; offsets round-trip.
        guard let lrclibCandidate = first.candidates.first(where: { $0.source == .lrclib }) else {
            t.that(false, "LRCLIB candidate present")
            return
        }
        await main.choose(lrclibCandidate, for: qingtian)
        let chosen = await main.lookup(qingtian)
        t.that(chosen.userChosen && chosen.lyrics?.candidate.id == lrclibCandidate.id, "choice wins")
        t.equal(chosen.lyrics?.texts, ["第一句", "第二句", "第三句"], "chosen content served")
        let chosenElsewhere = await service(directory, clock: clock).lookup(SongQuery(title: "晴天", artist: "周杰伦", duration: 269.6))
        t.that(chosenElsewhere.userChosen && chosenElsewhere.lyrics?.candidate.id == lrclibCandidate.id, "choice persisted and jitter-tolerant")
        t.equal(StubURLProtocol.requests.count, 0, "chosen content came from disk")
        await main.clearChoice(for: qingtian)
        let automatic = await main.lookup(qingtian)
        t.that(!automatic.userChosen && automatic.lyrics?.candidate.source == .kugou, "clearing the choice restores the automatic result")
        await main.setOffset(0.8, for: qingtian)
        t.near(await main.offset(for: qingtian), 0.8, "offset stored")
        t.near(await main.offset(for: SongQuery(title: "晴天", artist: "周杰伦", duration: 270.2)), 0.8, "offset tolerant of duration jitter")
        t.near(await service(directory, clock: clock).offset(for: qingtian), 0.8, "offset persisted")
        await main.setOffset(0, for: qingtian)
        t.near(await main.offset(for: qingtian), 0, "zero offset clears it")
        t.near(await main.offset(for: SongQuery(title: "夜曲", artist: "周杰伦")), 0, "unknown song has no offset")

        // 5. The playing platform is preferred.
        StubRoute.install(Catalog.qingtianRoutes())
        var preferred = qingtian
        preferred.preferredSource = .qqMusic
        let qqFirst = await service(Fixtures.temporaryDirectory("prefer"), clock: clock).lookup(preferred)
        t.equal(qqFirst.lyrics?.candidate.source, .qqMusic, "QQ lyrics for a QQ player")
        t.equal(qqFirst.lyrics?.lines.first?.text, "It's 第一句", "QQ entities decoded")
        t.equal(qqFirst.lyrics?.credits, ["晴天 - 周杰伦 (Jay Chou)", "词：周杰伦", "曲：周杰伦"], "QQ credits")

        // 6. NetEase-by-ID: synced lyrics return without waiting for anyone else.
        var slow = Catalog.qingtianRoutes(kugouDelay: 1.5, qqDelay: 1.5).map { route -> StubRoute in
            var delayed = route
            delayed.reply.delay = max(route.reply.delay, 1.5)
            return delayed
        }
        slow.insert(StubRoute(host: "music.163.com", path: "/api/song/lyric", query: ["id": "12345"],
                              reply: Catalog.netEaseLyric("[00:00.000] 作词 : 周杰伦\n[00:29.000]网易第一句\n[00:33.000]网易第二句", translation: "[00:29.000]translation")), at: 0)
        StubRoute.install(slow)
        var byID = qingtian
        byID.netEaseID = 12345
        start = ContinuousClock.now
        let identity = await service(Fixtures.temporaryDirectory("id"), clock: clock).lookup(byID)
        t.that(elapsed(since: start) < 0.8, "by-ID lyrics do not wait for slow providers", "\(elapsed(since: start))")
        t.equal(identity.lyrics?.candidate.id, "netEase:12345", "identity candidate")
        t.equal(identity.lyrics?.candidate.note, LyricsMatcher.identityNote, "identity note")
        t.equal(identity.lyrics?.lines.first?.translation, "translation", "NetEase translation merged")

        // 7. Early publish at the soft deadline, then background completion enriches the cache.
        var late = Catalog.empty(except: ["c.y.qq.com", "lrclib.net", "music.163.com"])
        late.append(StubRoute(host: "lrclib.net", path: "/api/search",
                              reply: Catalog.lrclib([(36308272, "晴天", "周杰伦", "叶惠美", 270, Catalog.lrclibBody, nil)])))
        late.append(StubRoute(host: "c.y.qq.com", path: "/soso/fcgi-bin/client_search_cp",
                              reply: Catalog.qqSongs([("0039MnYb0qxYhV", "晴天", ["周杰伦"], "叶惠美", 269)], delay: 0.45)))
        late.append(StubRoute(host: "music.163.com", path: "/api/search/get", reply: Catalog.netEaseSongs([], delay: 0.95)))
        StubRoute.install(late)
        let enriching = service(Fixtures.temporaryDirectory("late"), clock: clock)
        start = ContinuousClock.now
        let early = await enriching.lookup(qingtian)
        let earlyTime = elapsed(since: start)
        t.that(earlyTime < 0.42, "published at the soft deadline", "\(earlyTime)")
        t.equal(early.lyrics?.candidate.source, .lrclib, "best available lyrics")
        t.that(!early.candidates.contains { $0.source == .qqMusic }, "slow provider not waited for")
        await pause(0.7 - elapsed(since: start))
        let midway = await enriching.lookup(qingtian)
        t.that(midway.fromCache && midway.candidates.contains { $0.source == .qqMusic }, "re-lookup during background completion lists late candidates")
        t.equal(midway.lyrics?.candidate.id, early.lyrics?.candidate.id, "re-lookup keeps the shown lyrics")
        await pause(0.8)
        let enriched = await enriching.lookup(qingtian)
        t.that(enriched.fromCache && enriched.lyrics?.candidate.source == .lrclib, "displayed lyrics stay stable")
        t.that(enriched.candidates.contains { $0.source == .qqMusic }, "late candidates added to the cache")

        // 7b. Word-timed lyrics that arrive after publishing replace the cached choice for the next play only.
        var upgrade = Catalog.empty(except: ["lrclib.net", "lyrics.kugou.com"])
        upgrade.append(StubRoute(host: "lrclib.net", path: "/api/search",
                                 reply: Catalog.lrclib([(36308272, "晴天", "周杰伦", "叶惠美", 270, Catalog.lrclibBody, nil)])))
        upgrade.append(StubRoute(host: "lyrics.kugou.com", path: "/search",
                                 reply: Catalog.kugouCandidates([("34988004", "KEY", "周杰伦", "晴天", 269, 60)])))
        upgrade.append(StubRoute(host: "lyrics.kugou.com", path: "/download", reply: Catalog.kugouKRC(Fixtures.text("kugou_qingtian.krc.b64"), delay: 0.5)))
        StubRoute.install(upgrade)
        let upgradeDirectory = Fixtures.temporaryDirectory("upgrade")
        let upgrading = service(upgradeDirectory, clock: clock)
        let shown = await upgrading.lookup(qingtian)
        t.equal(shown.lyrics?.candidate.source, .lrclib, "first play shows the fast result")
        await pause(0.9)
        let replay = await upgrading.lookup(qingtian)
        t.that(replay.fromCache && replay.lyrics?.candidate.source == .lrclib, "same session keeps what it showed")
        t.that(replay.candidates.contains { $0.source == .kugou }, "late candidate listed")
        clock.advance(21 * 60)
        let later = await upgrading.lookup(qingtian)
        t.that(later.fromCache && later.lyrics?.candidate.source == .kugou && later.lyrics?.hasWordTiming == true,
               "a later play gets the word-timed lyrics found in the background")
        let relaunched = await service(upgradeDirectory, clock: clock).lookup(qingtian)
        t.equal(relaunched.lyrics?.candidate.source, .kugou, "upgrade persisted on disk")

        // 8. A live recording with only studio lyrics: 相近版本 with a note.
        var studioOnly = Catalog.empty(except: ["c.y.qq.com"])
        studioOnly.append(StubRoute(host: "c.y.qq.com", path: "/soso/fcgi-bin/client_search_cp",
                                    reply: Catalog.qqSongs([("0039MnYb0qxYhV", "晴天", ["周杰伦"], "叶惠美", 269)])))
        studioOnly.append(StubRoute(host: "c.y.qq.com", path: "/lyric/fcgi-bin/fcg_query_lyric_new.fcg", reply: Catalog.qqLyric(Catalog.qqBody)))
        StubRoute.install(studioOnly)
        let liveQuery = SongQuery(title: "晴天 (Live)", artist: "周杰伦", album: "2004 无与伦比 演唱会", duration: 299)
        let live = await service(Fixtures.temporaryDirectory("live"), clock: clock).lookup(liveQuery)
        t.equal(live.lyrics?.candidate.tier, .version, "studio lyrics for a live recording")
        t.equal(live.lyrics?.candidate.note, "现场版 · 使用录音室歌词，时间轴可能有偏差", "live note")
        t.that(live.lyrics?.isSynced == true, "still synced")

        // 9. Synced beats plain one tier down; plain beats synced two tiers down.
        var plainExact = Catalog.empty(except: ["lrclib.net", "lyrics.kugou.com"])
        plainExact.append(StubRoute(host: "lrclib.net", path: "/api/search",
                                    reply: Catalog.lrclib([(1, "晴天", "周杰伦", "叶惠美", 269, nil, "第一句\n第二句")])))
        plainExact.append(StubRoute(host: "lyrics.kugou.com", path: "/search",
                                    reply: Catalog.kugouCandidates([("34988004", "KEY", "周杰伦", "晴天", 265, 50)])))
        plainExact.append(StubRoute(host: "lyrics.kugou.com", path: "/download", reply: Catalog.kugouKRC(Fixtures.text("kugou_qingtian.krc.b64"))))
        StubRoute.install(plainExact)
        let syncedWins = await service(Fixtures.temporaryDirectory("plain1"), clock: clock).lookup(qingtian)
        t.that(syncedWins.lyrics?.candidate.source == .kugou && syncedWins.lyrics?.candidate.tier == .strong, "synced 匹配 over plain 精确匹配")
        var plainWins = Catalog.empty(except: ["lrclib.net", "c.y.qq.com"])
        plainWins.append(StubRoute(host: "lrclib.net", path: "/api/search", reply: Catalog.lrclib([(1, "晴天", "周杰伦", "叶惠美", 269, nil, "第一句\n第二句")])))
        plainWins.append(StubRoute(host: "c.y.qq.com", path: "/soso/fcgi-bin/client_search_cp",
                                   reply: Catalog.qqSongs([("x", "晴天", ["清柚"], "晴天", 245)])))
        plainWins.append(StubRoute(host: "c.y.qq.com", path: "/lyric/fcgi-bin/fcg_query_lyric_new.fcg", reply: Catalog.qqLyric("[00:01.00]别人的第一句")))
        StubRoute.install(plainWins)
        let plain = await service(Fixtures.temporaryDirectory("plain2"), clock: clock).lookup(qingtian)
        t.that(plain.lyrics?.candidate.source == .lrclib && plain.lyrics?.isSynced == false, "plain 精确匹配 over synced 同名歌曲")
        t.equal(plain.lyrics?.plainText, "第一句\n第二句", "plain text kept")

        // 10. Provider failures are reported in Chinese; 429 backs off with Retry-After; all-failed results expire fast.
        StubRoute.install([
            StubRoute(host: "music.163.com", path: "/api/search/get", reply: Catalog.netEaseSongs([], delay: 1.6)),
            StubRoute(host: "c.y.qq.com", path: "/soso", reply: .raw("oops", status: 500)),
            StubRoute(host: "lyrics.kugou.com", path: "/search", reply: .raw("<html>not json</html>")),
            StubRoute(host: "lrclib.net", path: "/api/search", reply: .raw("slow down", status: 429, headers: ["Retry-After": "120"])),
        ])
        let failing = service(Fixtures.temporaryDirectory("fail"), clock: clock)
        let failed = await failing.lookup(qingtian)
        t.that(failed.lyrics == nil, "no lyrics when every provider fails")
        for expected in ["网易云音乐：请求超时", "QQ 音乐：服务暂时不可用（HTTP 500）", "酷狗音乐：返回数据无法解析", "LRCLIB：请求过于频繁，120 秒后再试"] {
            t.that(failed.failures.contains(expected), "failure reported: \(expected)", "\(failed.failures)")
        }
        let quickRetry = await failing.lookup(qingtian)
        t.that(quickRetry.fromCache && quickRetry.lyrics == nil, "outage remembered briefly")
        clock.advance(30)
        let lrclibBefore = StubURLProtocol.requests(host: "lrclib.net").count
        let backedOff = await failing.lookup(SongQuery(title: "夜曲", artist: "周杰伦", duration: 226))
        t.equal(StubURLProtocol.requests(host: "lrclib.net").count, lrclibBefore, "no LRCLIB request during Retry-After")
        t.that(backedOff.failures.contains { $0.hasPrefix("LRCLIB：请求过于频繁") }, "back-off reported")
        clock.advance(100)
        _ = await failing.lookup(SongQuery(title: "七里香", artist: "周杰伦", duration: 299))
        t.that(StubURLProtocol.requests(host: "lrclib.net").count > lrclibBefore, "LRCLIB requested again after Retry-After")

        // 11. Nothing anywhere: negative result cached for 30 minutes.
        StubRoute.install(Catalog.empty())
        let missingQuery = SongQuery(title: "一个不存在的歌名", artist: "无名氏", duration: 200)
        let negativeService = service(Fixtures.temporaryDirectory("negative"), clock: clock)
        let missing = await negativeService.lookup(missingQuery)
        t.that(missing.lyrics == nil && missing.candidates.isEmpty && missing.failures.isEmpty, "nothing found, nothing failed")
        let requestsAfterMiss = StubURLProtocol.requests.count
        let missingAgain = await negativeService.lookup(missingQuery)
        t.that(missingAgain.fromCache && StubURLProtocol.requests.count == requestsAfterMiss, "negative cache hit")
        clock.advance(31 * 60)
        _ = await negativeService.lookup(missingQuery)
        t.that(StubURLProtocol.requests.count > requestsAfterMiss, "negative result expires after 30 minutes")

        // 12. Cancellation returns promptly and caches nothing.
        StubRoute.install(Catalog.qingtianRoutes(kugouDelay: 1, qqDelay: 1).map { route in
            var delayed = route
            delayed.reply.delay = 1
            return delayed
        })
        let cancelDirectory = Fixtures.temporaryDirectory("cancel")
        let cancelling = service(cancelDirectory, clock: clock)
        start = ContinuousClock.now
        let task = Task { await cancelling.lookup(qingtian) }
        await pause(0.1)
        task.cancel()
        let cancelled = await task.value
        t.that(elapsed(since: start) < 0.6, "cancellation honoured promptly", "\(elapsed(since: start))")
        t.equal(cancelled.failures, ["查询已取消"], "cancelled lookup says so")
        t.that(cancelled.lyrics == nil, "cancelled lookup has no lyrics")
        StubRoute.install(Catalog.qingtianRoutes())
        let afterCancel = await cancelling.lookup(qingtian)
        t.that(!afterCancel.fromCache && afterCancel.lyrics != nil, "a cancelled lookup leaves no negative entry")

        // 13. Concurrent lookups of one song share one job.
        StubRoute.install(Catalog.qingtianRoutes(kugouDelay: 0.3, qqDelay: 0.2))
        let shared = service(Fixtures.temporaryDirectory("shared"), clock: clock)
        async let one = shared.lookup(qingtian)
        async let two = shared.lookup(qingtian)
        let (a, b) = await (one, two)
        t.that(a.lyrics?.candidate.id == b.lyrics?.candidate.id && a.lyrics != nil, "both callers get the result")
        t.equal(StubURLProtocol.requests.filter { $0.url?.path == "/soso/fcgi-bin/client_search_cp" }.count, 1, "one QQ search for two callers")

        // 14. Corrupt cache files are ignored.
        let corrupt = Fixtures.temporaryDirectory("corrupt")
        StubRoute.install(Catalog.qingtianRoutes())
        _ = await service(corrupt, clock: clock).lookup(qingtian)
        for folder in ["lookups", "lyrics"] {
            let urls = (try? FileManager.default.contentsOfDirectory(at: corrupt.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? []
            t.that(!urls.isEmpty, "\(folder) written")
            for url in urls { try? Data("{ not json".utf8).write(to: url) }
        }
        for name in ["choices.json", "offsets.json", "negative.json"] { try? Data("garbage".utf8).write(to: corrupt.appendingPathComponent(name)) }
        let recovered = await service(corrupt, clock: clock).lookup(qingtian)
        t.that(!recovered.fromCache && recovered.lyrics != nil, "corrupt cache ignored, lookup still works")
        t.near(await service(corrupt, clock: clock).offset(for: qingtian), 0, "corrupt offsets file ignored")

        // 15. The cache is bounded (LRU).
        StubURLProtocol.install { request in
            guard let url = request.url, let host = url.host else { return nil }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if host == "lrclib.net", let title = items.first(where: { $0.name == "track_name" })?.value {
                return Catalog.lrclib([(Int64(abs(title.hashValue % 100_000) + 1), title, "歌手", "专辑", 200, "[00:01.00]\(title)", nil)])
            }
            switch host {
            case "music.163.com": return Catalog.netEaseSongs([])
            case "c.y.qq.com": return Catalog.qqSongs([])
            case "lyrics.kugou.com": return Catalog.kugouCandidates([])
            default: return Catalog.lrclib([])
            }
        }
        let small = Fixtures.temporaryDirectory("lru")
        let bounded = service(small, clock: clock, limit: 3)
        for index in 1...5 {
            clock.advance(1)
            let result = await bounded.lookup(SongQuery(title: "歌\(index)", artist: "歌手", duration: 200))
            t.that(result.lyrics != nil, "LRU fill \(index)")
        }
        for folder in ["lookups", "lyrics"] {
            let count = ((try? FileManager.default.contentsOfDirectory(atPath: small.appendingPathComponent(folder).path)) ?? []).count
            t.that(count <= 3, "\(folder) bounded", "\(count) files")
        }

        // 16. NetEase says the playing song is pure music.
        var pure = Catalog.empty()
        pure.append(StubRoute(host: "music.163.com", path: "/api/song/lyric", query: ["id": "777"],
                              reply: Catalog.netEaseLyric("[00:00.00] 作曲 : Yiruma\n[00:05.00]纯音乐，请欣赏\n", extra: ["pureMusic": true])))
        StubRoute.install(pure)
        let pureMusic = await service(Fixtures.temporaryDirectory("pure"), clock: clock)
            .lookup(SongQuery(title: "River Flows in You", artist: "Yiruma", duration: 214, netEaseID: 777))
        t.that(pureMusic.lyrics?.instrumental == true && pureMusic.lyrics?.isSynced == false, "instrumental flag returned")

        // 17. Oversized responses are refused.
        var huge = Catalog.empty(except: ["lrclib.net"])
        huge.append(StubRoute(host: "lrclib.net", path: "/api/search", reply: .raw("[\"" + String(repeating: "x", count: 2_100_000) + "\"]")))
        StubRoute.install(huge)
        let oversized = await service(Fixtures.temporaryDirectory("huge"), clock: clock).lookup(qingtian)
        t.that(oversized.failures.contains("LRCLIB：响应过大"), "2 MB cap", "\(oversized.failures)")

        // 18. Manual search and fetch.
        StubRoute.install(Catalog.qingtianRoutes())
        let manual = service(Fixtures.temporaryDirectory("manual"), clock: clock)
        let found = await manual.search("晴天 周杰伦", duration: 269)
        t.that(Set(found.map(\.source)).isSuperset(of: [.qqMusic, .kugou, .lrclib]), "manual search spans providers")
        t.that(found.first.map { $0.tier <= .strong } == true, "best manual result first", "\(found.first.map { "\($0.title) \($0.tier)" } ?? "-")")
        t.that(!found.contains { $0.remoteID == "001Wiw9y1SeFO4" }, "manual search hides 伴奏")
        t.that(found.allSatisfy { $0.note.hasPrefix("手动搜索") }, "manual notes")
        if let qqCandidate = found.first(where: { $0.remoteID == "0039MnYb0qxYhV" }) {
            let fetched = try? await manual.fetch(qqCandidate)
            t.equal(fetched?.lines.first?.text, "It's 第一句", "fetch a picked candidate")
            t.equal(fetched?.candidate.id, qqCandidate.id, "fetched lyrics carry the picked candidate")
        } else {
            t.that(false, "QQ row in manual search")
        }
        StubRoute.install([StubRoute(host: "c.y.qq.com", path: "/lyric", reply: .json(["retcode": -1901, "code": -1901]))])
        do {
            _ = try await manual.fetch(LyricsCandidate(id: "qqMusic:none", source: .qqMusic, remoteID: "none", title: "x", artist: "y",
                                                       album: nil, duration: nil, tier: .loose, score: 0, note: "", extra: [:]))
            t.that(false, "fetch without lyrics throws")
        } catch {
            t.equal((error as? LyricsLookupError)?.errorDescription, "没有歌词", "Chinese error for a missing lyric")
        }
        t.equal(await manual.search("   ").count, 0, "blank manual search")

        t.pass("service checks (lookup, ranking, by-ID fast path, early publish + background completion, live/plain fallbacks, failures, 429 back-off, negative/positive/disk cache, choices, offsets, corrupt files, LRU, cancellation, sharing, size cap, manual search)")
    }
}
