import Foundation

@main struct StageTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ label: String) {
        checks += 1
        guard condition else { fputs("FAIL: \(label)\n", stderr); exit(1) }
    }
    static func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.001) -> Bool { abs(a - b) <= tolerance }

    static func main() {
        typealias Raw = (start: Double, end: Double?, text: String, translation: String?, words: [(start: Double, end: Double, text: String)])

        // Lines: sorted, ends estimated, word ranges built from pieces.
        let raw: [Raw] = [
            (10, nil, "第二句歌词", nil, []),
            (2, nil, "你好世界", "Hello world", [(2, 2.5, "你好"), (2.5, 3.2, "世界")]),
            (30, nil, "", nil, []),
            (40, nil, "最后", nil, [(40, 41, "最"), (41, 42, "不对")])
        ]
        let track = StageTrack.make(id: "t", title: "歌", artist: "人", lines: raw, timing: .synced)
        expect(track.lines.map(\.start) == [2, 10, 30, 40], "lines are sorted by time")
        expect(track.lines[0].words.map(\.range) == [0..<2, 2..<4], "word pieces become UTF-16 ranges")
        expect(near(track.lines[0].end, 3.2), "word timing sets the line end")
        expect(track.lines[3].words.isEmpty, "words that do not spell the line are dropped")
        expect(track.lines[1].end > 10 && track.lines[1].end < 16, "line end is estimated from its length, not the next line")
        expect(track.lines[2].isGap, "empty lines are instrumental gaps")

        // Which line is showing.
        expect(track.index(at: 1.9) == nil && track.index(at: 2) == 0 && track.index(at: 29.9) == 1, "binary search finds the current line")
        var frame = StageFrame.at(0, in: StageTrack.make(id: "late", title: "", artist: "", lines: [(20, nil, "晚来的第一句", nil, [])], timing: .synced))
        expect(frame.index == nil && frame.countdown == nil, "intro far from the first line has no countdown")
        frame = StageFrame.at(0.5, in: track)
        expect(frame.index == nil && frame.countdown.map { near($0, 1.5) } == true, "countdown dots start 3 s before the first line")
        frame = StageFrame.at(2 - StageFrame.lead + 0.01, in: track)
        expect(frame.index == 0, "lines switch slightly early so the eye is ready")
        frame = StageFrame.at(31, in: track)
        expect(frame.index == 1 && frame.resting, "an empty line keeps the last sung line, resting")
        frame = StageFrame.at(38, in: track)
        expect(frame.resting && frame.countdown.map { near($0, 2) } == true, "a long gap counts down to the next line")
        frame = StageFrame.at(10.1, in: track)
        expect(frame.previous == 0 && frame.exit < 1, "the outgoing line is tracked for its exit")

        // Karaoke progress.
        let wordTiming = KaraokeTiming(time: 2.25, start: 2, end: 3.2, words: track.lines[0].words)
        expect(near(wordTiming.fraction(character: 0, glyph: 0, of: 4), 1), "first glyph of a half-sung word is lit")
        expect(near(wordTiming.fraction(character: 1, glyph: 1, of: 4), 0), "second glyph waits for its share of the word")
        expect(near(wordTiming.fraction(character: 2, glyph: 2, of: 4), 0), "next word has not started")
        let lineTiming = KaraokeTiming(time: 5, start: 4, end: 6, words: [])
        expect(near(lineTiming.fraction(character: 0, glyph: 0, of: 4), 1) && near(lineTiming.fraction(character: 3, glyph: 3, of: 4), 0),
               "line timing sweeps glyph by glyph")
        expect(near(lineTiming.fraction(character: 1, glyph: 1, of: 4), 1) && near(lineTiming.fraction(character: 2, glyph: 2, of: 4), 0),
               "half a line lights half the glyphs")
        expect(near(lineTiming.onset(character: 2, glyph: 2, of: 4), 5) && near(wordTiming.onset(character: 0, glyph: 0, of: 4), track.lines[0].words[0].start),
               "each glyph knows when its singing starts")

        // Clock.
        let start = Date(timeIntervalSince1970: 1000)
        expect(near(Playhead(position: 10, date: start, rate: 1).position(at: start.addingTimeInterval(2.5)), 12.5), "playing playhead advances")
        expect(near(Playhead(position: 10, date: start, rate: 0).position(at: start.addingTimeInterval(9)), 10), "paused playhead holds")

        // Plain lyrics spread over the song.
        let estimated = StageTrack.estimated(id: "p", title: "", artist: "", text: "第一句\n\n第二句比较长一些\n第三", duration: 200)
        expect(estimated.timing == .estimated && estimated.lines.count == 3, "plain text becomes estimated lines")
        expect(estimated.lines[0].start > 0 && estimated.lines[2].start < 200, "estimated lines stay inside the song")

        // Styles.
        for preset in LyricPreset.allCases {
            let style = preset.style
            let colours = [style.baseHex, style.sungHex, style.glowHex, style.outlineHex] + style.gradientHexes + [style.sungOutlineHex].compactMap { $0 }
            expect(colours.allSatisfy(HexColor.isValid), "\(preset.title) uses valid colours")
            expect(!style.isModified && !style.with(fontSize: 50, opacity: 0.4).isModified, "\(preset.title) size/opacity changes do not count as edits")
        }
        var edited = LyricPreset.neonPixel.style; edited.glow = 0.2
        expect(edited.isModified, "changing an effect marks the style as edited")
        let roundTrip = try! JSONDecoder().decode(LyricStyle.self, from: try! JSONEncoder().encode(LyricPreset.guofeng.style))
        expect(roundTrip == LyricPreset.guofeng.style, "styles survive JSON")
        let partial = try! JSONDecoder().decode(LyricStyle.self, from: Data(#"{"preset":"fire","fontSize":500,"glow":2}"#.utf8))
        expect(partial.preset == .fire && partial.fontSize == 72 && partial.glow == 1 && partial.typeface == .system, "missing keys default, numbers clamp")
        let broken = try! JSONDecoder().decode(LyricStyle.self, from: Data(#"{"preset":"ktv","baseHex":"nothex"}"#.utf8))
        expect(broken == LyricStyle(), "invalid colours fall back to the default style")
        let future = try! JSONDecoder().decode(LyricStyle.self, from: Data(#"{"preset":"fromTheFuture","motion":"warp","fontSize":40}"#.utf8))
        expect(future.preset == .clean && future.motion == .none && future.fontSize == 40, "unknown enum values from newer versions are ignored")
        let overlay = try! JSONDecoder().decode(OverlaySettings.self, from: Data(#"{"widthFraction":5,"frameRate":45,"locked":true}"#.utf8))
        expect(overlay.widthFraction == 0.95 && overlay.frameRate == 30 && overlay.locked, "overlay settings clamp and validate")

        // Fetched lyrics → stage lines, with Traditional → Simplified.
        let candidate = LyricsCandidate(id: "kugou:1", source: .kugou, remoteID: "1", title: "愛", artist: "歌手", album: nil, duration: 200,
                                        tier: .exact, score: 1, note: "", extra: [:])
        let lyrics = Lyrics(candidate: candidate, lines: [
            LyricLine(start: 5, end: 7, text: "我愛你", translation: "I love you",
                      words: [LyricWord(start: 5, end: 6, text: "我愛"), LyricWord(start: 6, end: 7, text: "你")])
        ], plainText: nil, credits: [], instrumental: false)
        let stage = StageTrack.make(lyrics: lyrics, title: "愛", artist: "歌手", duration: 200, simplified: true)
        expect(stage.lines[0].text == "我爱你" && stage.title == "爱", "Traditional text is shown Simplified")
        expect(stage.lines[0].words.map(\.range) == [0..<2, 2..<3], "converted word pieces still line up")
        let plain = StageTrack.make(lyrics: Lyrics(candidate: candidate, lines: [], plainText: "一\n二\n三", credits: [], instrumental: false),
                                    title: "愛", artist: "歌手", duration: 200, simplified: true)
        expect(plain.timing == .estimated && plain.lines.count == 3, "plain lyrics scroll by estimate")
        let instrumental = StageTrack.make(lyrics: Lyrics(candidate: candidate, lines: [], plainText: nil, credits: [], instrumental: true),
                                           title: "愛", artist: "歌手", duration: 200, simplified: true)
        expect(instrumental.message == "纯音乐，请欣赏", "instrumental songs say so")

        print("PASS: \(checks) stage, timing, style and bridge checks")
    }
}
