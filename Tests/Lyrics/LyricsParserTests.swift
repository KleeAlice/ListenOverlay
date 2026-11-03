import Foundation

@main struct LyricsParserTests {
    static func main() {
        var t = Checks("LRC parser")
        let hint = LyricsTitleHint(title: "晴天", artist: "周杰伦")

        // Timestamps in every common shape.
        t.near(LyricsParser.timestamp("01:02.34"), 62.34, "mm:ss.xx")
        t.near(LyricsParser.timestamp("01:02.345"), 62.345, "mm:ss.xxx")
        t.near(LyricsParser.timestamp("01:02"), 62, "mm:ss")
        t.near(LyricsParser.timestamp("01:02:34"), 62.34, "mm:ss:xx")
        t.near(LyricsParser.timestamp("1:01:02.5"), 3662.5, "h:mm:ss.x")
        t.that(LyricsParser.timestamp("ti:晴天") == nil, "a tag is not a timestamp")

        // Multiple stamps per line, sorting, gaps, ends, credits, JSON lines, the title line.
        let body = """
        [ti:晴天]
        [ar:周杰伦]
        {"t":0,"c":[{"tx":"作词: "},{"tx":"周杰伦"}]}
        [00:00.00]晴天 - 周杰伦 (Jay Chou)
        [00:01.00] 作词 : 周杰伦
        [00:02.00] 作曲 : 周杰伦
        [00:03.00]编曲：周杰伦
        [00:10.00][00:40.00]第一句
        [00:15.50]第二句
        [00:20.00]
        [00:21.00]
        [00:30.00]第三句
        [00:45.00]OP：某某音乐
        [00:46.00]未经许可，不得翻唱或使用
        """
        let parsed = LyricsParser.parseLRC(body, hint: hint)
        t.equal(parsed.lines.map(\.text), ["第一句", "第二句", "", "第三句", "第一句"], "sorted lines, repeated stamp, gap collapsed, credits removed")
        t.near(parsed.lines[0].start, 10, "first lyric start")
        t.near(parsed.lines[0].end, 15.5, "end filled from the next line")
        t.near(parsed.lines[2].start, 20, "first gap of a run is kept")
        t.that(parsed.lines.last?.end == nil, "last line has no known end")
        t.equal(parsed.credits, ["作词: 周杰伦", "晴天 - 周杰伦 (Jay Chou)", "作词 : 周杰伦", "作曲 : 周杰伦", "编曲：周杰伦",
                                 "OP：某某音乐", "未经许可，不得翻唱或使用"], "JSON, title line, leading and trailing credits")
        t.equal(parsed.tags["ti"], "晴天", "metadata tags kept")
        t.that(!parsed.instrumental, "lyrics are not instrumental")
        t.equal(parsed.plainText, "第一句\n第二句\n第三句\n第一句", "plain text derived from synced lines")

        let leading = LyricsParser.parseLRC("[00:00.00] 作词 : 甲\n[00:08.00]\n[00:12.00]第一句")
        t.equal(leading.lines.map(\.text), ["", "第一句"], "leading gap kept after credits")
        t.near(leading.lines.first?.end, 12, "gap ends when singing starts")

        // A lyric line that merely mentions a colon later in the song stays.
        let colon = LyricsParser.parseLRC("[00:01.00]第一句\n[00:05.00]他说：再见\n[00:09.00]最后一句", hint: hint)
        t.equal(colon.lines.map(\.text), ["第一句", "他说：再见", "最后一句"], "colon inside lyrics is not a credit")

        // [offset:+500] shows lyrics 0.5 s earlier.
        let offset = LyricsParser.parseLRC("[offset:+500]\n[00:10.00]甲\n[00:12.00]乙")
        t.near(offset.lines[0].start, 9.5, "positive offset moves lines earlier")
        let negative = LyricsParser.parseLRC("[offset:-250]\n[00:10.00]甲")
        t.near(negative.lines[0].start, 10.25, "negative offset moves lines later")

        // Separate translation LRC, merged by timestamp within 0.1 s; "//" placeholders ignored.
        let original = "[00:01.00]Hello\n[00:05.00]World\n[00:09.00]Again\n[00:13.00]Same"
        let translation = "[by:someone]\n[00:01.05]你好\n[00:05.00]//\n[00:09.30]太远了\n[00:13.00]Same"
        let merged = LyricsParser.parseLRC(original, translation: translation)
        t.equal(merged.lines.map { $0.translation ?? "-" }, ["你好", "-", "-", "-"], "translation tolerance and placeholders")

        // Bilingual LRC with both languages on the same stamp, and exact duplicates.
        let bilingual = LyricsParser.parseLRC("[00:01.00]夢ならば\n[00:01.00]如果这是梦\n[00:04.00]同一句\n[00:04.00]同一句")
        t.equal(bilingual.lines.count, 2, "same-stamp duplicates merged")
        t.equal(bilingual.lines[0].translation, "如果这是梦", "second text on one stamp is its translation")
        t.that(bilingual.lines[1].translation == nil, "an exact repeat is dropped, not a translation")

        // Enhanced LRC word stamps: words joined equal the line text, ends from the next stamp.
        let enhanced = LyricsParser.parseLRC("[00:01.00]<00:01.00>Hello <00:01.50>world<00:02.20>\n[00:03.00]<00:03.00>Next <00:03.40>line")
        let words = enhanced.lines[0].words ?? []
        t.equal(words.map(\.text), ["Hello ", "world"], "enhanced LRC words")
        t.equal(words.map(\.text).joined(), enhanced.lines[0].text, "joined words equal the line text")
        t.near(words.first?.end, 1.5, "word ends at the next stamp")
        t.near(words.last?.end, 2.2, "a closing stamp ends the last word")
        t.near(enhanced.lines[0].end, 2.2, "line end from word timing")
        t.near(enhanced.lines[1].words?.last?.end, 4.4, "last word of the song ends a second later")

        // Instrumental and placeholder bodies.
        let instrumental = LyricsParser.parseLRC("[00:00.00] 作曲 : Yiruma\n[00:05.00]纯音乐，请欣赏\n")
        t.that(instrumental.instrumental && instrumental.lines.isEmpty, "纯音乐，请欣赏 marks instrumental")
        t.equal(instrumental.credits, ["作曲 : Yiruma"], "instrumental keeps its credits")
        let placeholder = LyricsParser.parseLRC("[00:00.00]暂无歌词\n")
        t.that(!placeholder.hasContent, "暂无歌词 is no content")
        let creditsOnly = LyricsParser.parseLRC("[00:00.00]作词：甲\n[00:01.00]作曲：乙")
        t.that(!creditsOnly.hasContent, "credits alone are no content")

        // Untimed text.
        let plain = LyricsParser.parsePlain("晴天 - 周杰伦\n词：周杰伦\n\n第一段第一句\n第一段第二句\n\n\n第二段", hint: hint)
        t.equal(plain.plainText, "第一段第一句\n第一段第二句\n\n第二段", "plain text paragraphs, header and credits removed")
        t.equal(plain.credits, ["晴天 - 周杰伦", "词：周杰伦"], "plain credits")
        t.equal(LyricsParser.parsePlain("[Verse 1]\n第一句\n[Chorus]\n副歌").plainText, "第一句\n副歌", "section headers skipped")
        let untimed = LyricsParser.parseLRC("[ti:x]\n第一句\n第二句")
        t.that(untimed.lines.isEmpty && untimed.plainText == "第一句\n第二句", "LRC without stamps is plain text")

        // QQ Music escapes.
        t.equal(LyricsParser.decodeEntities("[00&#58;01.00]It&apos;s &#40;Live&#41;&#10;&amp; more"), "[00:01.00]It's (Live)\n& more", "HTML entities")
        t.equal(LyricsParser.decodeEntities("A & B; C"), "A & B; C", "a bare ampersand stays")
        let base64 = Data("[00:01.00]第一句".utf8).base64EncodedString()
        t.equal(QQMusicLyricsProvider.text(base64), "[00:01.00]第一句", "base64 body when nobase64 is ignored")

        // Credit detection rules.
        t.that(LyricsParser.isCreditLine("录音工程：杨瑞代（Alfa Studio）", strict: true), "compound credit label")
        t.that(LyricsParser.isCreditLine("Lyrics by Someone", strict: false), "English credit")
        t.that(!LyricsParser.isCreditLine("我说：我爱你", strict: true), "speech is not a credit")
        t.that(LyricsParser.isTitleLine("周杰伦-晴天", hint: hint, tags: [:]), "artist-title header line")
        t.that(!LyricsParser.isTitleLine("晴天的时候", hint: hint, tags: [:]), "a lyric with the title is not the header")

        t.pass("LRC parser checks (stamps, offset, gaps, credits, translations, words, instrumental, plain, entities)")
    }
}
