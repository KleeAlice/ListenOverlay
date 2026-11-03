import Foundation

@main struct KRCTests {
    static func main() async {
        var t = Checks("KRC")

        // Real Kugou payload (晴天, third-party lyric 34988004): base64 → krc1 → XOR → zlib → UTF-8.
        let qingtianText: String
        do {
            qingtianText = try LyricsParser.decodeKRC(base64: Fixtures.text("kugou_qingtian.krc.b64"))
        } catch {
            t.that(false, "decode the 晴天 fixture", "\(error)")
            return
        }
        t.that(qingtianText.contains("[ar:周杰伦]") && qingtianText.contains("[ti:晴天]"), "decoded KRC header tags")
        let qingtian = LyricsParser.parseKRC(qingtianText, hint: LyricsTitleHint(title: "晴天", artist: "周杰伦"))
        t.equal(qingtian.lines.first?.text, "故事的小黄花", "first lyric line (artist-title line dropped)")
        t.equal(qingtian.credits, ["周杰伦 - 晴天", "作词：周杰伦", "作曲：周杰伦"], "header and credits moved out")
        t.near(qingtian.lines.first?.start, 29.269, "line start from [start,dur]")
        t.near(qingtian.lines.first?.end, 29.269 + 2.884, "line end from the KRC duration")
        let firstWords = qingtian.lines.first?.words ?? []
        t.equal(firstWords.count, 6, "one word per character")
        t.near(firstWords.first?.start, 29.269, "word start is absolute")
        t.near(firstWords.first?.end, 29.623, "word end = offset + duration")
        t.near(firstWords.last?.start, 29.269 + 2.478, "last word offset")
        t.that(qingtian.lines.allSatisfy { ($0.words ?? []).map(\.text).joined() == $0.text }, "every line equals its joined words")
        t.equal(qingtian.lines[4].text, "Re So So Si Do Si La", "spaced Latin words trimmed at line ends")
        t.that(qingtian.lines.count > 50 && !qingtian.instrumental, "whole song parsed")
        t.that(qingtian.lines.allSatisfy { $0.translation == nil }, "empty language tag adds no translation")

        // Real payload with a translation in the [language:] tag (Lemon).
        guard let lemonText = try? LyricsParser.decodeKRC(base64: Fixtures.text("kugou_lemon.krc.b64")) else {
            t.that(false, "decode the Lemon fixture")
            return
        }
        let lemon = LyricsParser.parseKRC(lemonText, hint: LyricsTitleHint(title: "Lemon", artist: "米津玄師"))
        t.equal(lemon.lines.first?.text, "夢ならば", "Lemon first line")
        t.equal(lemon.lines.first?.translation, "如果这只是场梦", "type-1 translation aligned to its lyric line")
        t.equal(lemon.lines[1].translation, "那该有多好", "second translation")
        t.equal(lemon.credits.first, "Lemon (Single Version) - 日韩群星", "title line recognised through the [ti:]/[ar:] tags")
        t.that(lemon.credits.contains("原唱：米津玄師"), "原唱 credit")
        t.that(!lemon.lines.contains { $0.translation?.contains("文曲大模型") == true }, "translation of the dropped title line goes with it")
        t.that(lemon.lines.filter { $0.translation != nil }.count >= 45, "most lines translated")

        // Synthetic payload: alignment includes the header line, empty translations stay nil, type-0 ignored.
        let language = #"{"content":[{"type":0,"language":0,"lyricContent":[["a"],["b"],["c"]]},{"type":1,"language":0,"lyricContent":[["标题"],["Hello there"],[""]]}],"version":1}"#
        let synthetic = """
        [ti:测试]
        [ar:歌手]
        [language:\(Data(language.utf8).base64EncodedString())]
        [offset:0]
        [0,1000]<0,500,0>歌手<500,500,0>-测试
        [1000,2000]<0,1000,0>你好<1000,1000,0>呀
        [3000,1000]<0,1000,0>再见
        """
        let parsed = LyricsParser.parseKRC(synthetic, hint: LyricsTitleHint(title: "测试", artist: "歌手"))
        t.equal(parsed.lines.map(\.text), ["你好呀", "再见"], "synthetic lines")
        t.equal(parsed.lines.map { $0.translation ?? "-" }, ["Hello there", "-"], "translations aligned by line index")
        t.equal(parsed.credits, ["歌手-测试"], "synthetic header")

        // Corrupt payloads are rejected, not crashed on.
        var rejected = 0
        for bad in ["", "bm90IGtyYw==", Data("krc1".utf8).base64EncodedString() + "AAAA", Data([0x6B, 0x72, 0x63, 0x31, 1, 2, 3, 4, 5, 6]).base64EncodedString()] {
            do { _ = try LyricsParser.decodeKRC(base64: bad) } catch { rejected += 1 }
        }
        t.equal(rejected, 4, "invalid KRC payloads throw")

        // Provider end to end through stubbed HTTP: KRC first, plain LRC when the KRC is unusable.
        let krc = Fixtures.text("kugou_qingtian.krc.b64")
        StubRoute.install([
            StubRoute(host: "lyrics.kugou.com", path: "/download", query: ["id": "1", "fmt": "krc"], reply: .json(["status": 200, "fmt": "krc", "content": krc])),
            StubRoute(host: "lyrics.kugou.com", path: "/download", query: ["id": "2", "fmt": "krc"], reply: .json(["status": 200, "fmt": "krc", "content": "a3JjMQ=="])),
            StubRoute(host: "lyrics.kugou.com", path: "/download", query: ["id": "2", "fmt": "lrc"],
                      reply: .json(["status": 200, "fmt": "lrc", "content": Data("[00:01.00]第一句\n[00:03.00]第二句".utf8).base64EncodedString()])),
        ])
        let http = LyricsHTTP(session: StubURLProtocol.makeSession(), limiter: LyricsRateLimiter(), timeout: 3, maxBytes: 2_000_000, now: { Date() })
        let provider = KugouLyricsProvider()
        func candidate(_ id: String) -> LyricsCandidate {
            LyricsCandidate(id: "kugou:\(id)", source: .kugou, remoteID: id, title: "晴天", artist: "周杰伦", album: nil, duration: 269,
                            tier: .exact, score: 1, note: "", extra: ["accesskey": "KEY"])
        }
        do {
            let lyrics = try await provider.lyrics(for: candidate("1"), http: http)
            t.that(lyrics.hasWordTiming && lyrics.lines.first?.text == "故事的小黄花", "Kugou provider decodes KRC with word timing")
            let fallback = try await provider.lyrics(for: candidate("2"), http: http)
            t.equal(fallback.texts, ["第一句", "第二句"], "Kugou falls back to fmt=lrc")
            t.that(!fallback.hasWordTiming, "plain LRC fallback has no word timing")
        } catch {
            t.that(false, "Kugou provider", "\(error)")
        }
        t.pass("KRC checks (real fixture decode, word timing, language-tag translations, corrupt input, provider fallback)")
    }
}
