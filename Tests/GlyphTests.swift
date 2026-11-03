import AppKit
import SwiftUI

@main struct GlyphTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ label: String) {
        checks += 1
        guard condition else { fputs("FAIL: \(label)\n", stderr); exit(1) }
    }

    @MainActor static func main() {
        let font = NSFont.systemFont(ofSize: 34, weight: .bold)
        let cjk = GlyphLayout.block("听见每一句歌词", font: font, kern: 0, maxWidth: 2000)
        expect(cjk.glyphs.count == 7, "one glyph per Chinese character")
        expect(cjk.glyphs.map(\.character) == Array(0..<7), "glyphs map to UTF-16 offsets in order")
        expect(cjk.glyphs.allSatisfy { $0.rect.width > 0 && !$0.path.isEmpty }, "glyphs have outlines and advances")
        expect(cjk.lineRects.count == 1 && cjk.size.width > 100 && cjk.size.height > 30, "short lines stay on one line")
        expect(GlyphLayout.block("听见每一句歌词", font: font, kern: 0, maxWidth: 2000) === cjk, "layouts are cached")

        let mixed = GlyphLayout.block("Hi 世界", font: font, kern: 0, maxWidth: 2000)
        expect(mixed.glyphs.map(\.character) == [0, 1, 2, 3, 4], "Latin, space and CJK keep their offsets")

        let long = String(repeating: "长歌词需要换行显示", count: 4)
        let wrapped = GlyphLayout.block(long, font: font, kern: 0, maxWidth: 500)
        expect(wrapped.lineRects.count == 2 && wrapped.size.width <= 500.5, "long lines wrap into two balanced lines")
        let shrunk = GlyphLayout.block(long, font: font, kern: 0, maxWidth: 500, maxLines: 1)
        expect(shrunk.lineRects.count == 1 && shrunk.size.width <= 500.5 || shrunk.em < font.pointSize * 1.2, "single-line mode shrinks to fit")
        // Regression: the ticker lays out with unlimited width (used to trap building the cache key).
        let unlimited = GlyphLayout.block("跑马灯", font: font, kern: 0, maxWidth: .greatestFiniteMagnitude, maxLines: 1)
        expect(unlimited.glyphs.count == 3, "unlimited width is accepted")
        expect(GlyphLayout.block("", font: font, kern: 0, maxWidth: 400).glyphs.isEmpty, "empty text lays out to nothing")

        let sprite = GlyphSprites.shared.sprite(cjk.glyphs[0], scale: 2)
        expect(sprite != nil && sprite!.bounds.width > 10 && sprite!.bounds.height > 10, "glyph images render once per glyph")
        let outlined = GlyphSprites.shared.sprite(cjk.glyphs[0], outline: 3, scale: 2)
        expect(outlined != nil && outlined!.bounds.width > sprite!.bounds.width, "outline images include the stroke")
        let space = mixed.glyphs[2]
        expect(GlyphSprites.shared.sprite(space, scale: 2) == nil, "blank glyphs have no image")

        // LED matrix: lamps sit on the pixel font's grid, inside a wider dark housing.
        let pixel = LyricTypeface.pixel.nsFont(size: 36, weight: .regular)
        let dash = GlyphLayout.block("一", font: pixel, kern: 0, maxWidth: 400).glyphs[0]
        let lamps = GlyphSprites.shared.sprite(dash, dots: 0.42, scale: 2), housing = GlyphSprites.shared.sprite(dash, dots: 0.74, scale: 2)
        expect(pixel.fontName.hasPrefix("Fusion-Pixel") && lamps != nil && housing != nil, "pixel glyphs render as LED lamps")
        expect(lamps!.bounds.height < 36 * 0.4 && housing!.bounds.width > lamps!.bounds.width, "a one-pixel stroke is one row of lamps; the housing is wider")

        // Where the words are, for every layout.
        for preset in LyricPreset.allCases {
            let style = preset.style
            let painter = LyricStagePainter(track: .demo, time: 1.0, clock: 1, style: style, width: 640)
            let rect = painter.textRect()
            let stage = LyricStageMetrics.size(style, width: 640)
            expect(!rect.isNull && rect.width > 50 && rect.maxY <= stage.height + 1, "\(preset.title) reports its text area inside the stage")
        }
        let idle = LyricStagePainter(track: StageTrack(id: "idle", title: "", artist: "", lines: [], timing: .none, message: "等待播放…"), time: 0, clock: 0, style: LyricPreset.clean.style, width: 640)
        expect(!idle.textRect().isNull, "messages are hit-testable too")

        print("PASS: \(checks) glyph layout, sprite and stage checks")
    }
}
