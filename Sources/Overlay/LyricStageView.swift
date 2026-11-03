import AppKit
import SwiftUI

/// Animated desktop lyrics: one Canvas, repainted from cached glyph outlines.
/// Content is a pure function of song time, so the overlay, previews and
/// snapshots share it.
struct LyricStageView: View {
    var track: StageTrack
    var playhead: Playhead
    var style: LyricStyle
    var offset: Double = 0
    var width: CGFloat
    /// Loop the built-in sample instead of following a song.
    var demo = false
    var frameRate: Double = 30
    /// False while the window is hidden or covered: no frames are produced.
    var animating = true

    var body: some View {
        let size = LyricStageMetrics.size(style, width: width)
        // Paused or idle: draw once and stop, so a silent desktop costs nothing.
        TimelineView(.animation(minimumInterval: 1 / frameRate, paused: !animating || !(playhead.isPlaying || demo))) { context in
            let clock = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 86_400)
            let time = demo ? clock.truncatingRemainder(dividingBy: StageTrack.demoLength) : playhead.position(at: context.date) + offset
            LyricStageFrame(track: demo ? .demo : track, time: time, clock: clock, style: style, width: width)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// One instant of the stage (also used directly for snapshots).
struct LyricStageFrame: View {
    let track: StageTrack
    let time: Double
    let clock: Double
    let style: LyricStyle
    let width: CGFloat

    var body: some View {
        let painter = LyricStagePainter(track: track, time: time, clock: clock, style: style, width: width)
        Canvas { ctx, size in painter.draw(in: &ctx, size: size) }
            .frame(width: LyricStageMetrics.size(style, width: width).width, height: LyricStageMetrics.size(style, width: width).height)
            .opacity(style.opacity)
            .drawingGroup()
            .allowsHitTesting(false)
    }
}

enum LyricStageMetrics {
    static func lineHeight(_ style: LyricStyle) -> CGFloat { CGFloat(style.typeface.displaySize(style.fontSize)) * 1.34 }
    static func secondaryHeight(_ style: LyricStyle) -> CGFloat { CGFloat(style.secondarySize) * 1.4 }
    static func gap(_ style: LyricStyle) -> CGFloat { CGFloat(style.fontSize) * 0.22 }
    static func bulbRow(_ style: LyricStyle) -> CGFloat { style.chaseLights ? 18 : 0 }

    /// Fixed stage size, so the window does not resize on every line.
    static func size(_ style: LyricStyle, width: CGFloat) -> CGSize {
        let pad = style.effectPadding
        let content: CGFloat
        switch style.layout {
        case .stack: content = lineHeight(style) * 2 + (style.secondary == .none ? 0 : gap(style) + secondaryHeight(style))
        case .ktv: content = lineHeight(style) * 2 + gap(style)
        case .ticker: content = lineHeight(style) + bulbRow(style) * 2 + 6
        }
        return CGSize(width: width + pad * 2, height: content + pad * 2)
    }
}

struct LyricStagePainter {
    let track: StageTrack
    let time: Double
    let clock: Double
    let style: LyricStyle
    let width: CGFloat

    private enum Piece {
        case text(GlyphBlock, CGPoint, GlyphPainter, hit: Bool)
        case dots(CGPoint, remaining: Double, size: CGFloat)
    }

    private var pad: CGFloat { style.effectPadding }
    private var kern: CGFloat { CGFloat(style.letterSpacing) }
    private var primaryFont: NSFont { style.typeface.nsFont(size: style.fontSize, weight: style.weight) }
    private var secondaryFont: NSFont { style.typeface.nsFont(size: style.secondarySize, weight: style.weight.rank > 3 ? .semibold : style.weight) }
    private var messageFont: NSFont { style.typeface.nsFont(size: style.fontSize * 0.78, weight: style.weight) }

    /// Brush faces (楷体、行楷…) have poor Latin letters: English lines fall back to the system font.
    private func font(_ base: NSFont, for text: String) -> NSFont {
        guard style.typeface.isDecorativeCJK else { return base }
        let han = text.unicodeScalars.filter { $0.properties.isIdeographic }.count
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }.count
        guard letters > 0, Double(han) / Double(letters) < 0.3 else { return base }
        return .systemFont(ofSize: base.pointSize * 0.92, weight: style.weight.rank >= LyricWeight.bold.rank ? .semibold : .regular)
    }

    /// Whole-point origins keep glyph images sharp; pixel fonts land on their grid.
    private func snap(_ origin: CGPoint, _ block: GlyphBlock) -> CGPoint {
        guard let first = block.glyphs.first else { return CGPoint(x: origin.x.rounded(), y: origin.y.rounded()) }
        return CGPoint(x: (origin.x + first.origin.x).rounded() - first.origin.x, y: (origin.y + first.origin.y).rounded() - first.origin.y)
    }
    private var alignFactor: CGFloat { style.alignment == .leading ? 0 : style.alignment == .center ? 0.5 : 1 }
    private var titleLine: String { [track.title, track.artist].filter { !$0.isEmpty }.joined(separator: " · ") }

    func draw(in ctx: inout GraphicsContext, size: CGSize) {
        if style.layout == .ticker { drawTicker(ctx); return }
        for piece in pieces() { render(piece, ctx) }
    }

    /// Where the words are, in stage coordinates (for pointer hit-testing).
    func textRect() -> CGRect {
        if style.layout == .ticker {
            let row = LyricStageMetrics.lineHeight(style)
            return CGRect(x: pad, y: pad + LyricStageMetrics.bulbRow(style), width: width, height: row + 6)
        }
        return pieces().reduce(CGRect.null) { rect, piece in
            guard case .text(let block, let origin, _, let hit) = piece, hit, !block.glyphs.isEmpty else { return rect }
            return rect.union(CGRect(origin: origin, size: block.size))
        }
    }

    private func render(_ piece: Piece, _ ctx: GraphicsContext) {
        switch piece {
        case .text(let block, let origin, let painter, _): painter.draw(block, at: origin, in: ctx)
        case .dots(let origin, let remaining, let size):
            let colour = Color(hex: style.sungHex)
            for index in 0..<3 {
                let rect = CGRect(x: origin.x + CGFloat(index) * size * 1.7, y: origin.y, width: size, height: size)
                var c = ctx
                c.opacity = Double(index) < ceil(remaining) ? 1 : 0.18
                c.addFilter(.shadow(color: colour.opacity(0.8), radius: size * 0.6))
                c.fill(Path(ellipseIn: rect), with: .color(colour))
            }
        }
    }

    private func painter(_ role: LyricRole, line: Int? = nil, age: Double = 10, exit: Double = 0, dim: Double = 1) -> GlyphPainter {
        let item = line.map { track.lines[$0] }
        let timing = item.map { KaraokeTiming(time: time, start: $0.start, end: $0.end, words: $0.words) }
        return GlyphPainter(style: style, role: role, clock: clock, age: age, karaoke: role == .active ? timing : nil,
                            exit: exit, dim: dim, seed: (line ?? -1) &* 7919)
    }

    private func block(_ text: String, font base: NSFont, maxLines: Int = 2, scrambled: Bool = false) -> GlyphBlock {
        let face = font(base, for: text)
        // Wide 字距 suits Han characters; Latin set in the fallback face keeps normal spacing.
        return GlyphLayout.block(text, font: face, kern: face === base ? kern : min(kern, 1), maxWidth: width, maxLines: maxLines,
                                 alignment: style.alignment, cached: !scrambled)
    }

    private func lineText(_ index: Int, role: LyricRole, age: Double) -> (String, Bool) {
        let text = track.lines[index].text
        guard role == .active, style.entrance == .scramble, age < 0.45 else { return (text, false) }
        let pool = Array("アイウエオカキクケコサシスセソ01#%&*+=<>/▓▒░")
        let scrambled = String(text.enumerated().map { offset, character in
            if character == " " || age >= 0.08 + Double(offset) * 0.024 { return character }
            return pool[Int(lyricNoise(offset &+ index, Int(age * 30)) * Double(pool.count)) % pool.count]
        })
        return (scrambled, true)
    }

    // MARK: Layouts

    private func pieces() -> [Piece] {
        let frame = StageFrame.at(time, in: track)
        switch style.layout {
        case .stack, .ticker: return stack(frame)
        case .ktv: return ktv(frame)
        }
    }

    private func stack(_ frame: StageFrame) -> [Piece] {
        var pieces: [Piece] = []
        let primaryBottom = pad + LyricStageMetrics.lineHeight(style) * 2
        func place(_ block: GlyphBlock, bottom: CGFloat) -> CGPoint {
            snap(CGPoint(x: pad + (width - block.size.width) * alignFactor, y: bottom - block.size.height), block)
        }
        // Primary row.
        if track.lines.isEmpty || frame.index == nil {
            let text = track.lines.isEmpty ? (track.message ?? titleLine) : titleLine
            let b = block(text, font: messageFont)
            pieces.append(.text(b, place(b, bottom: primaryBottom), painter(.plain), hit: true))
        } else if let index = frame.index {
            if let previous = frame.previous, frame.exit < 1, style.entrance != .none, !frame.resting {
                let b = block(track.lines[previous].text, font: primaryFont)
                pieces.append(.text(b, place(b, bottom: primaryBottom), painter(.sung, line: previous, exit: frame.exit), hit: false))
            }
            let role: LyricRole = frame.resting ? .sung : .active
            let (text, scrambled) = lineText(index, role: role, age: frame.age)
            let b = block(text, font: primaryFont, scrambled: scrambled)
            pieces.append(.text(b, place(b, bottom: primaryBottom), painter(role, line: index, age: frame.age, dim: frame.resting ? 0.5 : 1), hit: true))
        }
        // Secondary row: translation, next line, or the song for a message.
        guard style.secondary != .none else { return pieces }
        var secondary: (String, LyricRole)?
        if track.lines.isEmpty {
            if track.message != nil, !titleLine.isEmpty { secondary = (titleLine, .plain) }
        } else {
            let current = frame.index.map { track.lines[$0] }
            if let translation = current?.translation, !translation.isEmpty, !frame.resting,
               style.secondary == .translation || style.secondary == .auto {
                secondary = (translation, .plain)
            } else if style.secondary != .translation,
                      let next = track.lines[((frame.index ?? -1) + 1)...].first(where: { !$0.isGap }) {
                secondary = (next.text, .upcoming)
            }
        }
        let rowTop = primaryBottom + LyricStageMetrics.gap(style)
        let dotSize = CGFloat(style.secondarySize) * 0.36
        let dotsWidth: CGFloat = frame.countdown == nil ? 0 : dotSize * 4.4 + 10
        let b = secondary.map { block($0.0, font: secondaryFont, maxLines: 1) }
        let total = dotsWidth + (b?.size.width ?? 0)
        let left = pad + (width - total) * alignFactor
        let rowHeight = LyricStageMetrics.secondaryHeight(style)
        if let countdown = frame.countdown {
            pieces.append(.dots(CGPoint(x: left, y: rowTop + (rowHeight - dotSize) / 2), remaining: countdown, size: dotSize))
        }
        if let b, let secondary {
            let y = rowTop + (rowHeight - b.size.height) / 2
            pieces.append(.text(b, snap(CGPoint(x: left + dotsWidth, y: y), b),
                                painter(secondary.1, age: frame.age, dim: secondary.1 == .plain ? 0.92 : 0.8), hit: true))
        }
        return pieces
    }

    private func ktv(_ frame: StageFrame) -> [Piece] {
        let sung = track.lines.indices.filter { !track.lines[$0].isGap }
        let lineHeight = LyricStageMetrics.lineHeight(style)
        guard !sung.isEmpty else {
            let b = block(track.message ?? titleLine, font: messageFont, maxLines: 1)
            return [.text(b, snap(CGPoint(x: pad, y: pad + (lineHeight - b.size.height) / 2), b), painter(.plain), hit: true)]
        }
        let ordinal = frame.index.flatMap { sung.firstIndex(of: $0) }
        var pieces: [Piece] = []
        for row in 0..<2 {
            let slot: (ordinal: Int, active: Bool)?
            if let ordinal {
                if ordinal % 2 == row { slot = (ordinal, true) }
                else { slot = ordinal + 1 < sung.count ? (ordinal + 1, false) : nil }
            } else {
                slot = row < sung.count ? (row, false) : nil
            }
            guard let slot else { continue }
            let line = sung[slot.ordinal]
            let shownSince = slot.ordinal >= 1 ? track.lines[sung[slot.ordinal - 1]].start : 0
            let age = max(0, time - (slot.active ? shownSince : (ordinal.map { track.lines[sung[$0]].start } ?? 0)))
            let role: LyricRole = slot.active ? .active : .upcoming
            let (text, scrambled) = lineText(line, role: role, age: age)
            let b = GlyphLayout.block(text, font: primaryFont, kern: kern, maxWidth: width * 0.92, maxLines: 1,
                                      alignment: row == 0 ? .leading : .trailing, cached: !scrambled)
            let x = row == 0 ? pad : pad + width - b.size.width
            let y = pad + CGFloat(row) * (lineHeight + LyricStageMetrics.gap(style)) + (lineHeight - b.size.height) / 2
            pieces.append(.text(b, snap(CGPoint(x: x, y: y), b), painter(role, line: line, age: age, dim: frame.resting && slot.active ? 0.6 : 1), hit: true))
        }
        return pieces
    }

    // MARK: Ticker (跑马灯)

    /// Lyrics laid end to end; the strip moves so the sung character stays at
    /// the reading point, then glides through the gap to the next line.
    private func drawTicker(_ ctx: GraphicsContext) {
        let row = LyricStageMetrics.lineHeight(style), bulbs = LyricStageMetrics.bulbRow(style)
        let top = pad + bulbs + 3
        let current = StageFrame.at(time, in: track).index
        var items: [(line: Int, x: CGFloat, block: GlyphBlock)] = []
        var x: CGFloat = 0
        let separator = CGFloat(style.fontSize) * 1.6
        for (index, line) in track.lines.enumerated() where !line.isGap {
            let b = GlyphLayout.block(line.text, font: primaryFont, kern: kern, maxWidth: .greatestFiniteMagnitude, maxLines: 1, alignment: .leading)
            items.append((index, x, b)); x += b.size.width + separator
        }
        let shift = width * 0.36 - head(items)
        ctx.drawLayer { layer in
            // The strip runs on past both ends; nothing may show outside the stage.
            layer.clip(to: Path(CGRect(origin: .zero, size: LyricStageMetrics.size(style, width: width))))
            if items.isEmpty {
                let b = GlyphLayout.block(track.message ?? titleLine, font: messageFont, kern: kern, maxWidth: width, maxLines: 1, alignment: .center)
                painter(.plain).draw(b, at: CGPoint(x: pad + (width - b.size.width) / 2, y: top + (row - b.size.height) / 2), in: layer)
            }
            let star = GlyphLayout.block("✦", font: style.typeface.nsFont(size: style.fontSize * 0.6, weight: .regular), kern: 0,
                                         maxWidth: .greatestFiniteMagnitude, maxLines: 1, alignment: .leading)
            for item in items where item.x + shift < width + 60 && item.x + item.block.size.width + shift > -60 {
                let role: LyricRole = current == nil || item.line > current! ? .upcoming : item.line == current! ? .active : .sung
                painter(role, line: item.line).draw(item.block, at: CGPoint(x: pad + item.x + shift, y: top + (row - item.block.size.height) / 2), in: layer)
                var plain = style; plain.fill = .solid; plain.baseHex = style.glowHex; plain.karaoke = false; plain.pixelGrid = false; plain.glow = 0.3; plain.glowOnSung = false
                GlyphPainter(style: plain, role: .plain, clock: clock, dim: 0.7)
                    .draw(star, at: CGPoint(x: pad + item.x + item.block.size.width + shift + separator / 2 - star.size.width / 2,
                                            y: top + (row - star.size.height) / 2), in: layer)
            }
            // Fade the strip in and out at both ends.
            layer.blendMode = .destinationOut
            let fade = min(80, width * 0.08)
            for (from, to) in [(pad - pad, pad + fade), (pad + width + pad, pad + width - fade)] {
                let rect = CGRect(x: min(from, to), y: 0, width: abs(to - from), height: top + row + pad + bulbs * 2)
                layer.fill(Path(rect), with: .linearGradient(Gradient(colors: [.black, .clear]), startPoint: CGPoint(x: from, y: 0), endPoint: CGPoint(x: to, y: 0)))
            }
        }
        if style.chaseLights {
            drawBulbs(ctx, y: pad + bulbs / 2, direction: 1)
            drawBulbs(ctx, y: top + row + 3 + bulbs / 2, direction: -1)
        }
    }

    private func head(_ items: [(line: Int, x: CGFloat, block: GlyphBlock)]) -> CGFloat {
        guard let first = items.first else { return 0 }
        let lines = track.lines, speed: CGFloat = 70
        if time < lines[first.line].start { return first.x - CGFloat(lines[first.line].start - time) * speed }
        for (k, item) in items.enumerated() {
            let line = lines[item.line]
            if time <= line.end {
                let timing = KaraokeTiming(time: time, start: line.start, end: line.end, words: line.words)
                let glyphs = item.block.glyphs
                guard !glyphs.isEmpty else { return item.x }
                var sung: CGFloat = 0
                for g in glyphs { sung += g.rect.width * CGFloat(timing.fraction(character: g.character, glyph: g.index, of: glyphs.count)) }
                return item.x + sung
            }
            if k + 1 < items.count, time < lines[items[k + 1].line].start {
                let next = items[k + 1]
                let p = CGFloat((time - line.end) / max(0.01, lines[next.line].start - line.end))
                return item.x + item.block.size.width + (next.x - item.x - item.block.size.width) * p
            }
        }
        let last = items[items.count - 1]
        return last.x + last.block.size.width + CGFloat(time - lines[last.line].end) * speed
    }

    /// Theatre marquee bulbs chasing along the strip: warm filament light, never rainbow.
    private func drawBulbs(_ ctx: GraphicsContext, y: CGFloat, direction: Int) {
        let spacing: CGFloat = 19, radius: CGFloat = 3.6
        let count = Int((width + pad) / spacing)
        let phase = Int(clock * 6 * style.speed) * direction
        let glow = Color(hex: style.glowHex)
        let bulbs = (0..<max(1, count)).map { k in
            (lit: ((k + phase) % 3 + 3) % 3 == 0, centre: CGPoint(x: pad / 2 + CGFloat(k) * spacing + spacing / 2, y: y))
        }
        // Every lit bulb's halo in one blurred layer (one blur per row, not one per bulb).
        var halos = ctx
        halos.addFilter(.blur(radius: 5))
        halos.drawLayer { layer in
            for bulb in bulbs where bulb.lit {
                layer.fill(Path(ellipseIn: CGRect(x: bulb.centre.x - radius - 4, y: bulb.centre.y - radius - 4, width: radius * 2 + 8, height: radius * 2 + 8)),
                           with: .color(glow.opacity(0.75)))
            }
        }
        for (lit, centre) in bulbs {
            let rect = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            if lit {
                ctx.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [.white, Color(hex: "FFE7B0"), glow]),
                                                                      center: centre, startRadius: 0, endRadius: radius))
            } else {
                ctx.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [Color(hex: "8A6631"), Color(hex: "4A3418")]),
                                                                      center: centre, startRadius: 0, endRadius: radius))
            }
        }
    }
}
