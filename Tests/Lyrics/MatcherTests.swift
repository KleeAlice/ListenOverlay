import Foundation

@main struct MatcherTests {
    static func hit(_ source: LyricsSource, _ id: String, _ title: String, _ artists: [String], _ album: String? = nil,
                    _ duration: Double? = nil, rank: Int = 0) -> LyricsSearchHit {
        var value = LyricsSearchHit(source: source, remoteID: id, title: title, artists: artists, album: album, duration: duration, rank: rank)
        if source == .kugou { value.syncedHint = 1; value.wordHint = 0.9 }
        return value
    }

    static func lyrics(_ tier: MatchTier, _ score: Double, synced: Bool = true, words: Bool = false, plain: Bool = false,
                       instrumental: Bool = false, id: String) -> Lyrics {
        let candidate = LyricsCandidate(id: id, source: .lrclib, remoteID: id, title: "t", artist: "a", album: nil, duration: nil,
                                        tier: tier, score: score, note: "", extra: [:])
        var lines: [LyricLine] = []
        if synced {
            let wordList = words ? [LyricWord(start: 1, end: 2, text: "甲")] : nil
            lines = [LyricLine(start: 1, end: 2, text: "甲", translation: nil, words: wordList)]
        }
        return Lyrics(candidate: candidate, lines: lines, plainText: synced || plain ? "甲" : nil, credits: [], instrumental: instrumental)
    }

    static func main() {
        var t = Checks("matcher")

        // MARK: SongText
        t.equal(SongText.normalized("周杰倫 Jay-Chou！"), "周杰伦jaychou", "Traditional→Simplified, case and punctuation folded")
        t.equal(SongText.normalized("Ｌｅｍｏｎ"), "lemon", "full-width folded")
        t.equal(SongText.normalized("Beyoncé"), "beyonce", "diacritics folded")
        t.equal(SongText.baseTitle("晴天 (Live)"), "晴天", "base: (Live)")
        t.equal(SongText.baseTitle("晴天（现场版）"), "晴天", "base: full-width brackets")
        t.equal(SongText.baseTitle("晴天 - Live"), "晴天", "base: dash suffix")
        t.equal(SongText.baseTitle("最长的电影 (The Longest Movie)"), "最长的电影", "base: bilingual alias")
        t.equal(SongText.baseTitle("Hey Jude - Remastered 2015"), "Hey Jude", "base: remaster suffix")
        t.equal(SongText.baseTitle("Shape of You (feat. Stormzy) [Remix]"), "Shape of You", "base: feat + remix")
        t.equal(SongText.baseTitle("Bad Habits feat. Somebody"), "Bad Habits", "base: unbracketed feat.")
        t.equal(SongText.baseTitle("晴天 (DJ阿lo版)"), "晴天", "base: DJ版")
        t.equal(SongText.baseTitle("晴天 (伴奏)"), "晴天", "base: 伴奏")
        t.equal(SongText.baseTitle("Lemon cover：米津玄师"), "Lemon", "base: cover marker")
        t.equal(SongText.baseTitle("03.晴天"), "晴天", "base: track number")
        t.equal(SongText.baseTitle("Live Forever"), "Live Forever", "base: a title word is not a tag")
        t.equal(SongText.titleNames("最長的電影 - The Longest Movie"), ["最长的电影", "thelongestmovie"], "bilingual dash names")
        t.equal(SongText.versionTags("晴天 (Live)", album: nil), ["live"], "tags: live")
        t.equal(SongText.versionTags("晴天", album: "周杰伦 2004 无与伦比 演唱会 Live CD"), ["live"], "tags: live album")
        t.equal(SongText.versionTags("晴天 (DJ阿lo版)", album: nil), ["dj"], "tags: dj")
        t.equal(SongText.versionTags("晴天 (0.8x DJ 阿Bo版)", album: nil), ["dj", "tempo"], "tags: tempo")
        t.equal(SongText.versionTags("晴天 (KTV版伴奏)", album: nil), ["instrumental"], "tags: 伴奏")
        t.equal(SongText.versionTags("晴天 (原唱 周杰伦)", album: nil), ["cover"], "tags: 原唱 means a cover")
        t.equal(SongText.versionTags("晴天+安静+修炼爱情 (2017演唱会)", album: nil), ["live", "medley"], "tags: medley")
        t.equal(SongText.versionTags("Hey Jude - Remastered 2015", album: nil), ["remaster"], "tags: remaster")
        t.equal(SongText.versionClass(["remaster"]), "studio", "remaster keeps the studio class")
        t.equal(SongText.versionTags("Lemon (柠檬) (Single Version)", album: nil), [], "tags: neutral version words")
        t.equal(SongText.versionTags("Beat It", album: "Beat It"), [], "tags: weak words ignored in albums")
        t.equal(SongText.versionTags("光年之外 (G.E.M.重生版)", album: nil), ["variant"], "tags: other 版")
        t.equal(SongText.artists("周杰伦 (Jay Chou)"), ["周杰伦", "Jay Chou"], "artists: bracketed alias")
        t.equal(SongText.artists("Ed Sheeran feat. Beyoncé"), ["Ed Sheeran", "Beyoncé"], "artists: feat.")
        t.equal(SongText.artists("林俊杰和周杰伦"), ["林俊杰", "周杰伦"], "artists: 和")
        t.equal(SongText.artists("张和平"), ["张和平"], "artists: 和 inside a name")
        t.equal(SongText.artists("Marshmello x Bastille"), ["Marshmello", "Bastille"], "artists: x")
        t.equal(SongText.artists("Lil Nas X"), ["Lil Nas X"], "artists: trailing X is a name")
        t.equal(SongText.artists("周杰伦、费玉清/A & B;C"), ["周杰伦", "费玉清", "A", "B", "C"], "artists: separators")
        t.equal(SongText.artistMatch(SongText.artistKeys("邓紫棋"), SongText.artistKeys("G.E.M.邓紫棋")), .contains, "containment 邓紫棋")
        t.equal(SongText.artistMatch(SongText.artistKeys("G.E.M."), SongText.artistKeys("G.E.M.邓紫棋")), .contains, "containment G.E.M.")
        t.equal(SongText.artistMatch(SongText.artistKeys("Anna"), SongText.artistKeys("Hannah")), .none, "no substring match inside words")
        t.equal(SongText.artistMatch(SongText.artistKeys("群星"), SongText.artistKeys("日韩群星")), .none, "placeholder credits never match")
        t.that(SongText.similarity("后来", "后来的我们") < 0.85, "short containment is not similar")
        t.near(SongText.similarity("光年之外", "光年之外热爱版"), 0.85, "≥ 4 character containment counts as 0.85")

        // MARK: Tiers — studio query (metadata from real catalog rows)
        let studio = LyricsMatchContext(SongQuery(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269))
        func tier(_ context: LyricsMatchContext, _ value: LyricsSearchHit) -> MatchTier? { LyricsMatcher.evaluate(value, context: context)?.candidate.tier }
        func note(_ context: LyricsMatchContext, _ value: LyricsSearchHit) -> String { LyricsMatcher.evaluate(value, context: context)?.candidate.note ?? "-" }
        t.equal(tier(studio, hit(.qqMusic, "0039MnYb0qxYhV", "晴天", ["周杰伦"], "叶惠美", 269)), .exact, "same song")
        t.equal(tier(studio, hit(.kugou, "461810434", "晴天", ["周杰伦"], nil, 265.072)), .strong, "4 s apart")
        t.equal(tier(studio, hit(.kugou, "539106757", "晴天", ["周杰伦"], nil, 253.361)), .version, "16 s apart")
        t.equal(tier(studio, hit(.lrclib, "29743129", "周杰伦 - 03.晴天", ["周杰伦"], "叶惠美", 269)), .exact, "artist prefix and track number cleaned")
        t.equal(tier(studio, hit(.lrclib, "38317510", "周杰伦", ["晴天"], "叶惠美", 269)), .exact, "swapped title/artist fields")
        let liveRow = hit(.qqMusic, "001398Rf3gykz8", "晴天 (Live)", ["周杰伦"], "周杰伦 2004 无与伦比 演唱会 Live CD", 299)
        t.equal(tier(studio, liveRow), .version, "studio song, live lyrics")
        t.equal(note(studio, liveRow), "使用现场版歌词，时间轴可能有偏差", "studio song, live lyrics note")
        t.equal(tier(studio, hit(.qqMusic, "004SB5DZ1JTN7Y", "晴天 (DJ阿lo版)", ["周杰伦"], nil, 218)), .version, "DJ版 of the same song")
        t.equal(tier(studio, hit(.qqMusic, "001naPHz2ER9qv", "晴天 (Live)", ["林俊杰", "周杰伦"], nil, 239)), .version, "duet live version")
        t.that(tier(studio, hit(.qqMusic, "001Wiw9y1SeFO4", "晴天 (KTV版伴奏)", ["周杰伦"], nil, 269)) == nil, "伴奏 rejected")
        t.that(tier(studio, hit(.netEase, "3440441479", "晴天", ["Jay"], "晴天", 112.373)) == nil, "112 s track rejected (duration)")
        t.that(tier(studio, hit(.qqMusic, "001Bbywq2gicae", "搁浅", ["周杰伦"], "七里香", 240)) == nil, "same artist, different song")
        t.that(tier(studio, hit(.qqMusic, "000qP0Lr0WSszt", "晴天+安静+修炼爱情+最长的电影 (2017周杰伦地表最强演唱会台北站)",
                                ["周杰伦", "林俊杰"], nil, 268)) == nil, "medley rejected")
        t.equal(tier(studio, hit(.netEase, "2668397359", "晴天 (原唱 周杰伦)", ["RyaVocal"], "晴天", 270.738)), .loose, "cover by another singer")
        t.that(tier(studio, hit(.netEase, "3391116218", "晴天", ["梦里啥都有"], "晴天", 228)) == nil, "other singer, 15 % shorter")
        t.equal(tier(studio, hit(.netEase, "2658336658", "晴天 (钢琴版)", ["CIP Music"], "周杰伦钢琴曲集", 267)), .loose, "piano cover stays loose")

        // Live query.
        let live = LyricsMatchContext(SongQuery(title: "晴天 (Live)", artist: "周杰伦", album: "2004 无与伦比 演唱会", duration: 299))
        t.equal(tier(live, liveRow), .exact, "live song, same live recording")
        t.equal(tier(live, hit(.lrclib, "30639144", "晴天", ["周杰伦"], "周杰伦 2004 无与伦比 演唱会 Live", 299)), .strong, "live album marks the row live")
        let untagged = hit(.kugou, "1", "晴天", ["周杰伦"], nil, 299.4)
        t.equal(tier(live, untagged), .strong, "untagged row with the live duration")
        t.equal(note(live, untagged), "现场版 · 时长一致", "bridge note")
        let studioRow = hit(.qqMusic, "0039MnYb0qxYhV", "晴天", ["周杰伦"], "叶惠美", 269)
        t.equal(tier(live, studioRow), .version, "live song, studio lyrics")
        t.equal(note(live, studioRow), "现场版 · 使用录音室歌词，时间轴可能有偏差", "live song, studio lyrics note")

        // 繁体 vs 简体, romanized names, containment, feat. credits.
        let traditional = LyricsMatchContext(SongQuery(title: "後來", artist: "劉若英", duration: 341))
        t.equal(tier(traditional, hit(.qqMusic, "1", "后来", ["刘若英"], "我等你", 341)), .exact, "Traditional query, Simplified catalog")
        t.that(tier(traditional, hit(.qqMusic, "2", "后来的我们", ["五月天"], nil, 330)) == nil, "different song sharing a prefix")
        let romanized = LyricsMatchContext(SongQuery(title: "晴天", artist: "Jay Chou", duration: 269))
        t.equal(tier(romanized, studioRow), .version, "Jay Chou vs 周杰伦 with equal duration")
        t.equal(note(romanized, studioRow), "歌手名不同（可能是译名或别名），时长一致", "alias note")
        let gem = LyricsMatchContext(SongQuery(title: "光年之外", artist: "邓紫棋", duration: 235))
        t.equal(tier(gem, hit(.netEase, "449818741", "光年之外", ["G.E.M.邓紫棋"], "光年之外", 235.505)), .exact, "G.E.M.邓紫棋 contains 邓紫棋")
        t.equal(tier(gem, hit(.netEase, "1957866769", "光年之外", ["Ayu刘语淇"], "光年之外", 235)), .loose, "same-script other singer stays loose")
        let duet = LyricsMatchContext(SongQuery(title: "Señorita", artist: "Shawn Mendes, Camila Cabello", duration: 191))
        t.equal(tier(duet, hit(.lrclib, "9", "Señorita", ["Shawn Mendes & Camila Cabello"], nil, 191)), .exact, "credit separators and diacritics")
        let stay = LyricsMatchContext(SongQuery(title: "STAY", artist: "The Kid LAROI", duration: 141))
        t.equal(tier(stay, hit(.qqMusic, "8", "Stay (with Justin Bieber)", ["The Kid LAROI", "Justin Bieber"], nil, 141)), .strong, "feat. in the title")
        let bilingual = LyricsMatchContext(SongQuery(title: "The Longest Movie", artist: "Jay Chou", duration: 236))
        t.equal(tier(bilingual, hit(.qqMusic, "7", "最长的电影 (The Longest Movie)", ["周杰伦"], nil, 236)), .version, "English title matches the bilingual alias")
        let chinese = LyricsMatchContext(SongQuery(title: "最长的电影", artist: "周杰伦", duration: 236))
        t.equal(tier(chinese, hit(.lrclib, "6", "最長的電影 - The Longest Movie", ["周杰倫"], nil, 237)), .strong, "dash alias row")

        // Covers, remixes, accompaniment, other songs, durations far off (NetEase/QQ rows for Lemon).
        let lemon = LyricsMatchContext(SongQuery(title: "Lemon", artist: "米津玄師", duration: 255))
        t.equal(tier(lemon, hit(.kugou, "382052084", "Lemon", ["米津玄師"], nil, 255.582)), .exact, "Lemon exact")
        t.equal(tier(lemon, hit(.netEase, "1939880626", "lemon(cos：米津玄师)", ["米津玄师", "韩少泽"], "翻唱", 255)), .version, "credited cover")
        t.equal(tier(lemon, hit(.netEase, "2", "lemon（翻自 米津玄師）", ["龚林"], "Lemon", 251)), .loose, "uncredited cover")
        t.equal(tier(lemon, hit(.qqMusic, "0005KUba33doP6", "Lemon (Live)", ["米津玄師"], nil, 248)), .version, "live take")
        t.that(tier(lemon, hit(.netEase, "1444387266", "Lemon（伴奏）", ["米津玄师"], "Lemon（伴奏）", 256)) == nil, "伴奏 rejected")
        t.that(tier(lemon, hit(.netEase, "1344729444", "lemon（钢琴改编版）（翻自 米津玄師）", ["米津玄師"], nil, 87)) == nil, "87 s arrangement rejected")
        t.that(tier(lemon, hit(.netEase, "536623987", "Paper Flower", ["米津玄師"], "Lemon", 276)) == nil, "same album, different song")
        let remix = LyricsMatchContext(SongQuery(title: "Shape of You", artist: "Ed Sheeran", duration: 233))
        t.equal(tier(remix, hit(.lrclib, "5", "Shape of You (Major Lazer Remix)", ["Ed Sheeran"], nil, 210)), .version, "remix of the song")

        // Identity and unknown durations.
        let identity = LyricsMatchContext(SongQuery(title: "晴天", artist: "周杰伦", duration: 269, netEaseID: 12345))
        let identityHit = LyricsMatcher.evaluate(hit(.netEase, "12345", "完全不同的名字", ["别人"], nil, 100), context: identity)
        t.equal(identityHit?.candidate.tier, .exact, "the player's own NetEase song is exact")
        t.equal(identityHit?.candidate.note, LyricsMatcher.identityNote, "identity note")
        let noDuration = LyricsMatchContext(SongQuery(title: "晴天", artist: "周杰伦"))
        t.equal(tier(noDuration, studioRow), .strong, "unknown duration: strong")
        t.that(tier(noDuration, hit(.netEase, "3443411735", "晴天", ["清柚"], "晴天", 231, rank: 5)) == nil, "unknown duration, other singer, low rank")
        t.equal(tier(noDuration, hit(.netEase, "3443411735", "晴天", ["清柚"], "晴天", 231, rank: 1)), .loose, "unknown duration, other singer, top rank")

        // Nonsense durations from a player are ignored, never trapped on.
        t.equal(LyricsCacheKey.make(SongQuery(title: "晴天", artist: "周杰伦", duration: 1e20)), "晴天|周杰伦|-", "absurd duration → unknown bucket")
        t.equal(LyricsCacheKey.make(SongQuery(title: "晴天", artist: "周杰伦", duration: 269.4)), "晴天|周杰伦|270", "2 s bucket")
        t.that(LyricsMatchContext(SongQuery(title: "晴天", artist: "周杰伦", duration: .infinity)).duration == nil, "infinite duration ignored")
        t.equal(LyricsService.searchRequest(SongQuery(title: "晴天 (Live)", artist: "周杰伦/林俊杰", duration: 1e20), source: .kugou, attempt: 1)?.title,
                "晴天", "searches use the base title and the first artist")
        t.equal(LyricsService.searchRequest(SongQuery(title: "後來", artist: "劉若英"), source: .qqMusic, attempt: 2)?.keywords,
                "后来 刘若英", "second attempt: simplified script")
        t.equal(LyricsService.searchRequest(SongQuery(title: "晴天", artist: "Jay Chou"), source: .qqMusic, attempt: 2)?.keywords,
                "晴天", "second attempt: title only for romanized names")
        t.equal(LyricsService.searchRequest(SongQuery(title: "晴天", artist: "Jay Chou"), source: .lrclib, attempt: 2)?.broad, true,
                "LRCLIB second attempt uses free text")

        // MARK: Ranking
        let qq = LyricsMatcher.evaluate(hit(.qqMusic, "q", "晴天", ["周杰伦"], "叶惠美", 269), context: studio)!
        let kugou = LyricsMatcher.evaluate(hit(.kugou, "k", "晴天", ["周杰伦"], nil, 269), context: studio)!
        t.that(kugou.candidate.score > qq.candidate.score, "word-timed Kugou ranks first without a preference")
        let preferQQ = LyricsMatchContext(SongQuery(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269, preferredSource: .qqMusic))
        let qqPreferred = LyricsMatcher.evaluate(hit(.qqMusic, "q", "晴天", ["周杰伦"], "叶惠美", 269), context: preferQQ)!
        let kugouOther = LyricsMatcher.evaluate(hit(.kugou, "k", "晴天", ["周杰伦"], nil, 269), context: preferQQ)!
        let qqContent = LyricsMatcher.accept(lyrics(.exact, 0, id: "q"), for: qqPreferred, duration: 269)!
        let kugouContent = LyricsMatcher.accept(lyrics(.exact, 0, words: true, id: "k"), for: kugouOther, duration: 269)!
        t.equal(LyricsMatcher.best([kugouContent, qqContent])?.candidate.id, qqPreferred.candidate.id, "the playing platform wins within a tier")
        let ordered = LyricsMatcher.ordered([kugou.candidate, LyricsMatcher.evaluate(liveRow, context: studio)!.candidate, qq.candidate])
        t.equal(ordered.map(\.tier), [.exact, .exact, .version], "candidates ordered by tier, then score")

        // Synced over plain: plain only when no synced result in the same or the next tier.
        t.equal(LyricsMatcher.best([lyrics(.exact, 0.9, synced: false, plain: true, id: "plain"), lyrics(.strong, 0.5, id: "synced")])?.candidate.id,
                "synced", "synced 匹配 beats plain 精确匹配")
        t.equal(LyricsMatcher.best([lyrics(.exact, 0.9, synced: false, plain: true, id: "plain"), lyrics(.version, 0.9, id: "synced")])?.candidate.id,
                "plain", "plain 精确匹配 beats synced 相近版本")
        t.equal(LyricsMatcher.best([lyrics(.strong, 0.9, synced: false, plain: true, id: "plain"), lyrics(.version, 0.5, id: "synced")])?.candidate.id,
                "synced", "synced next tier beats plain")
        t.equal(LyricsMatcher.best([lyrics(.exact, 0.9, synced: false, instrumental: true, id: "inst"), lyrics(.strong, 0.5, id: "synced")])?.candidate.id,
                "synced", "lyrics one tier down beat an instrumental flag")
        t.equal(LyricsMatcher.best([lyrics(.exact, 0.9, synced: false, instrumental: true, id: "inst"), lyrics(.version, 0.5, id: "synced")])?.candidate.id,
                "inst", "instrumental exact beats lyrics two tiers down")

        // Content acceptance.
        t.that(LyricsMatcher.accept(lyrics(.exact, 0, synced: false, id: "empty"), for: qq, duration: 269) == nil, "empty body rejected")
        var strongHit = qq
        strongHit.candidate.tier = .strong
        let pure = LyricsMatcher.accept(lyrics(.strong, 0, synced: false, instrumental: true, id: "q"), for: strongHit, duration: 269)
        t.that(pure?.candidate.note.hasSuffix("纯音乐") == true, "instrumental accepted for a strong match")
        var looseHit = qq
        looseHit.candidate.tier = .loose
        t.that(LyricsMatcher.accept(lyrics(.loose, 0, synced: false, instrumental: true, id: "q"), for: looseHit, duration: 269) == nil,
               "instrumental rejected for a loose match")
        let plainOnly = LyricsMatcher.accept(lyrics(.exact, 0, synced: false, plain: true, id: "q"), for: qq, duration: 269)
        t.that(plainOnly?.candidate.note.contains("无时间轴") == true, "plain note")
        var long = lyrics(.exact, 0, id: "q")
        long.lines = [LyricLine(start: 300, end: nil, text: "尾", translation: nil, words: nil)]
        let overrun = LyricsMatcher.accept(long, for: qq, duration: 269)!
        let normal = LyricsMatcher.accept(lyrics(.exact, 0, id: "q"), for: qq, duration: 269)!
        t.that(overrun.candidate.score < normal.candidate.score, "timeline longer than the song costs score")

        t.pass("matcher checks (normalization, tiers for live/studio, 繁简, aliases, feat., covers, DJ/remix, 伴奏, medleys, durations, ranking)")
    }
}
