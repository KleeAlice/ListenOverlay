import AppKit
import SwiftUI

/// How a line takes part in the current moment of the song.
enum LyricRole: Equatable {
    /// The line being sung (karaoke, entrance, particles).
    case active
    /// Waiting to be sung (KTV second row, next line, ticker ahead).
    case upcoming
    /// Already sung (ticker behind, finished KTV row, outgoing line).
    case sung
    /// Translation, titles and messages.
    case plain
}

/// Deterministic hash noise in 0..<1; particles and flicker need no stored state.
@inline(__always) func lyricNoise(_ a: Int, _ b: Int = 0) -> Double {
    var x = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663 &+ 0x2545F491))
    x ^= x >> 33; x &*= 0xff51_afd7_ed55_8ccd; x ^= x >> 33; x &*= 0xc4ce_b9fe_1a85_ec53; x ^= x >> 33
    return Double(x % 1_000_003) / 1_000_003
}

extension HexColor {
    static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double) {
        let v = UInt32(hex, radix: 16) ?? 0xFFFFFF
        return (Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
    }
    /// Colour at `position` along a looping palette (smooth blend between neighbours).
    static func loop(_ hexes: [String], at position: Double, towardWhite: Double = 0) -> Color {
        guard !hexes.isEmpty else { return .white }
        let count = Double(hexes.count)
        let p = (position.truncatingRemainder(dividingBy: count) + count).truncatingRemainder(dividingBy: count)
        let i = Int(p), f = p - Double(i)
        let a = rgb(hexes[i % hexes.count]), b = rgb(hexes[(i + 1) % hexes.count])
        func c(_ x: Double, _ y: Double) -> Double { let v = x + (y - x) * f; return v + (1 - v) * towardWhite }
        return Color(.sRGB, red: c(a.r, b.r), green: c(a.g, b.g), blue: c(a.b, b.b), opacity: 1)
    }
}

/// Paints one typeset line with every lyric effect. Unsung text is always a
/// solid colour; effects only add colour and light where the song has reached.
struct GlyphPainter {
    var style: LyricStyle
    var role: LyricRole
    /// Wall-clock seconds for ambient animation.
    var clock: Double
    /// Seconds since this line appeared (entrance).
    var age: Double = 10
    var karaoke: KaraokeTiming?
    /// 0 = in place, 1 = gone (outgoing line).
    var exit: Double = 0
    var dim: Double = 1
    var seed: Int = 0

    private struct GlyphState {
        var offset = CGSize.zero
        var scale: CGFloat = 1
        var rotation = Angle.zero
        var opacity = 1.0
        var blur: CGFloat = 0
        /// Sung fraction 0…1 (karaoke sweep position inside the glyph).
        var fraction = 0.0
        var visible = true
    }

    private enum Part { case all, sung, unsung }

    private enum Look { case unsung, sung }
    /// Which parts of the line get which look. Unsung = solid 未唱颜色; sung = the fill.
    private var segments: [(part: Part, look: Look)] {
        switch role {
        case .upcoming: return [(.all, .unsung)]
        case .sung: return [(.all, .sung)]
        case .plain: return [(.all, litLook ? .sung : .unsung)]
        case .active:
            if !style.karaoke { return [(.all, style.fill == .solid ? .unsung : .sung)] }
            return [(.unsung, .unsung), (.sung, .sung)]
        }
    }
    /// Neon styles keep messages and translations lit.
    private var litLook: Bool { style.glowOnSung && style.glow >= 0.8 }
    /// Pixel font shown as an LED matrix: one round lamp per font pixel.
    private var led: Bool { style.pixelGrid && style.typeface == .pixel }
    /// Lamp radii in font pixels: the lit lamp, its dark housing, and its white-hot centre.
    private enum Lamp { static let lit: CGFloat = 0.42, housing: CGFloat = 0.74, core: CGFloat = 0.2 }
    private var motionScale: Double { role == .active ? 1 : role == .plain ? 0.35 : 0.6 }
    private static let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2

    func draw(_ block: GlyphBlock, at origin: CGPoint, in context: GraphicsContext) {
        let glyphs = block.glyphs
        guard !glyphs.isEmpty else { return }
        var ctx = context
        ctx.translateBy(x: origin.x, y: origin.y)
        let bounds = CGRect(origin: .zero, size: block.size)
        let em = block.em
        let states = glyphs.map { state(for: $0, count: glyphs.count, em: em) }
        // A sign switches off where it hangs before the next one lights; other lines slide up and away.
        let switchOff = style.entrance == .pixel
        ctx.opacity *= dim * (switchOff ? max(0, 1 - exit * 3) : pow(1 - exit, 1.6))
        if exit > 0, !switchOff { ctx.translateBy(x: 0, y: -CGFloat(exit) * em * 1.05) }

        if style.backing > 0.01 { drawBacking(ctx, glyphs, states, em: em) }
        if style.shadow, !led { drawShadow(ctx, glyphs, states, em: em) }
        if style.glow > 0.01 { drawGlow(ctx, glyphs, states, bounds: bounds, em: em) }
        if style.outline > 0.01, !led { drawOutline(ctx, glyphs, states, em: em) }
        if style.rgbSplit { drawSplit(ctx, glyphs, states, em: em) }
        drawFill(ctx, glyphs, states, bounds: bounds, em: em)
        if led, style.coreWhite > 0.01 { drawLampCores(ctx, glyphs, states) }
        if role == .active { drawExtras(ctx, glyphs, states, em: em) }
    }

    /// Glitch styles tear for a moment every couple of seconds instead of jittering constantly.
    private var burst: Bool {
        let slot = Int(clock / 2.3)
        let start = Double(slot) * 2.3 + lyricNoise(slot, 41) * 1.6
        return clock >= start && clock < start + 0.16
    }

    // MARK: Per-glyph animation

    private func state(for glyph: LaidGlyph, count: Int, em: CGFloat) -> GlyphState {
        var s = GlyphState()
        let i = glyph.index, speed = style.speed, m = motionScale
        switch role {
        case .active: s.fraction = karaoke?.fraction(character: glyph.character, glyph: i, of: count) ?? 0
        case .sung: s.fraction = 1
        case .upcoming: s.fraction = 0
        case .plain: s.fraction = litLook ? 1 : 0
        }
        if !style.karaoke, role == .active { s.fraction = 0 }

        if exit == 0, role != .sung {
            let a = age
            switch style.entrance {
            case .none, .scramble: break
            case .fade:
                s.opacity *= ease(a / 0.28)
            case .rise:
                let e = easeOutCubic(a / 0.34)
                s.offset.height += (1 - e) * em * 0.35; s.opacity *= ease(a / 0.22)
            case .pop:
                let local = clamp((a - Double(i) * 0.02) / 0.34)
                s.scale *= 0.55 + 0.45 * easeOutBack(local); s.opacity *= clamp(local * 3)
            case .ink:
                let local = clamp((a - Double(i) * 0.035) / 0.42), e = easeOutCubic(local)
                s.blur = (1 - e) * em * 0.16; s.scale *= 1.1 - 0.1 * e; s.opacity *= clamp(local * 1.8)
            case .typewriter:
                if role == .active, let karaoke {
                    s.visible = karaoke.fraction(character: glyph.character, glyph: i, of: count) > 0.001
                    // Each key strikes: lands slightly large and high, then settles.
                    let since = karaoke.time - karaoke.onset(character: glyph.character, glyph: i, of: count)
                    if s.visible, since < 0.11 {
                        let e = easeOutCubic(since / 0.11)
                        s.scale *= 1.32 - 0.32 * e; s.offset.height -= (1 - e) * em * 0.07
                    }
                }
            case .pixel:
                // Neon ignition: each character catches with a couple of flickers.
                let on = 0.1 + lyricNoise(i, seed) * 0.26
                if a < on { s.visible = false }
                else if a < on + 0.12 { s.opacity *= lyricNoise(i, Int(a * 60)) > 0.45 ? 1 : 0.25 }
            }
        }

        switch style.motion {
        case .none: break
        case .float:
            s.offset.height += sin(clock * 1.7 * speed) * em * 0.03 * m
        case .wave:
            s.offset.height += sin(clock * 2.6 * speed + Double(i) * 0.5) * em * 0.05 * m
        case .bounce:
            if role == .active, s.fraction > 0, s.fraction < 1 {
                let p = sin(Double.pi * s.fraction)
                s.offset.height -= p * em * 0.34; s.scale *= 1 + 0.16 * p
            }
        case .jitter:
            if burst { s.offset.width += (lyricNoise(i, Int(clock * 40)) - 0.5) * em * 0.22 }
        case .pulse:
            s.scale *= 1 + 0.03 * sin(clock * 2 * .pi * 0.8 * speed) * m
        case .shimmer:
            s.offset.height += sin(clock * 8 + Double(i) * 1.9) * em * 0.012 * m
        }

        // A neon tube now and then stutters for a frame or two.
        if style.flicker, role != .plain, s.fraction > 0, lyricNoise(i &+ seed, Int(clock * 12)) < 0.012 { s.opacity *= 0.5 }
        return s
    }

    // MARK: Drawing one glyph

    private func place(_ glyph: LaidGlyph, _ s: GlyphState, _ c: inout GraphicsContext) {
        c.translateBy(x: s.offset.width, y: s.offset.height)
        if s.scale != 1 || s.rotation != .zero {
            let centre = CGPoint(x: glyph.rect.midX, y: glyph.rect.midY)
            c.translateBy(x: centre.x, y: centre.y)
            if s.rotation != .zero { c.rotate(by: s.rotation) }
            if s.scale != 1 { c.scaleBy(x: s.scale, y: s.scale) }
            c.translateBy(x: -centre.x, y: -centre.y)
        }
    }

    private func clipPart(_ glyph: LaidGlyph, _ s: GlyphState, _ part: Part, _ c: inout GraphicsContext) -> Bool {
        if part == .sung && s.fraction <= 0 { return false }
        if part == .unsung && s.fraction >= 1 { return false }
        if part != .all, s.fraction > 0, s.fraction < 1 {
            let pad = glyph.rect.height
            let split = glyph.rect.minX + glyph.rect.width * CGFloat(s.fraction)
            let rect = part == .sung
                ? CGRect(x: glyph.rect.minX - pad, y: glyph.rect.minY - pad, width: split - glyph.rect.minX + pad, height: glyph.rect.height + pad * 2)
                : CGRect(x: split, y: glyph.rect.minY - pad, width: glyph.rect.maxX - split + pad, height: glyph.rect.height + pad * 2)
            c.clip(to: Path(rect))
        }
        return true
    }

    /// Draws one glyph from its cached white image (tint comes from the enclosing layer).
    /// In LED mode the image is the glyph's lamps (`lamp` radius, lit size by default).
    private func drawGlyph(_ glyph: LaidGlyph, _ s: GlyphState, part: Part, opacity: Double = 1, nudge: CGSize = .zero,
                           blur: Bool = true, outline: CGFloat = 0, lamp: CGFloat = Lamp.lit, in ctx: GraphicsContext) {
        guard s.visible, s.opacity * opacity > 0.004 else { return }
        var c = ctx
        c.opacity *= s.opacity * opacity
        place(glyph, s, &c)
        if nudge != .zero { c.translateBy(x: nudge.width, y: nudge.height) }
        guard clipPart(glyph, s, part, &c) else { return }
        if blur, s.blur > 0.3 { c.addFilter(.blur(radius: s.blur)) }
        if let sprite = GlyphSprites.shared.sprite(glyph, outline: led ? 0 : outline, dots: led ? lamp : 0, scale: Self.scale) {
            c.draw(sprite.image, in: CGRect(x: glyph.origin.x + sprite.bounds.minX, y: glyph.origin.y + sprite.bounds.minY,
                                            width: sprite.bounds.width, height: sprite.bounds.height))
        } else if !glyph.path.isEmpty {
            if outline > 0 { c.stroke(glyph.path, with: .color(.white), style: StrokeStyle(lineWidth: outline * 2, lineJoin: .round)) }
            c.fill(glyph.path, with: .color(.white))
        }
    }

    /// Runs `body` inside one layer tinted by `colour` (one filter for many glyphs).
    private func tinted(_ ctx: GraphicsContext, _ colour: Color, _ body: (inout GraphicsContext) -> Void) {
        var c = ctx
        c.addFilter(.colorMultiply(colour))
        c.drawLayer { layer in body(&layer) }
    }

    // MARK: Passes

    /// Soft dark halo: light text stays readable on light wallpapers, and glow reads as light.
    /// LED text gets a crisp dark housing behind its lamps instead, like the face of a sign.
    private func drawBacking(_ ctx: GraphicsContext, _ glyphs: [LaidGlyph], _ states: [GlyphState], em: CGFloat) {
        if led {
            var c = ctx
            c.opacity *= min(1, style.backing)
            tinted(c, Color(hex: "08060E")) { layer in
                for (g, s) in zip(glyphs, states) { drawGlyph(g, s, part: .all, blur: false, lamp: Lamp.housing, in: layer) }
            }
            return
        }
        var c = ctx
        c.addFilter(.blur(radius: max(3, em * 0.22)))
        c.opacity *= min(1, style.backing)
        c.addFilter(.colorMultiply(Color(hex: style.preset == .guofeng ? "1C1008" : "05030C")))
        let parts = segments.filter { !(style.glowOnSung && $0.look == .unsung) }.map(\.part)
        c.drawLayer { layer in
            for part in parts {
                for (g, s) in zip(glyphs, states) { drawGlyph(g, s, part: part, blur: false, outline: max(1.5, em * 0.06), in: layer) }
                // Second pass doubles the core of the halo without widening it.
                for (g, s) in zip(glyphs, states) { drawGlyph(g, s, part: part, opacity: 0.6, blur: false, in: layer) }
            }
        }
    }

    private func drawShadow(_ ctx: GraphicsContext, _ glyphs: [LaidGlyph], _ states: [GlyphState], em: CGFloat) {
        let darkText = HexColor.luminance(style.baseHex) < 0.45
        var c = ctx
        c.addFilter(.blur(radius: max(1.5, em * 0.07)))
        c.translateBy(x: 0, y: max(1, em * 0.035))
        c.opacity *= darkText ? 0.75 : 0.6
        c.addFilter(.colorMultiply(darkText ? .white : .black))
        c.drawLayer { layer in
            for (g, s) in zip(glyphs, states) { drawGlyph(g, s, part: .all, blur: false, in: layer) }
        }
    }

    private func drawGlow(_ ctx: GraphicsContext, _ glyphs: [LaidGlyph], _ states: [GlyphState], bounds: CGRect, em: CGFloat) {
        let strength = style.glow * (role == .plain ? 0.5 : role == .upcoming ? 0.4 : 1)
        let lit = segments.filter { !(style.glowOnSung && $0.look == .unsung) }
        guard !lit.isEmpty else { return }
        // Above 0.75: tube bloom plus a wide haze ("光污染"). Bright colours only, layered over the backing.
        let layers: [(radius: CGFloat, alpha: Double)] = led
            ? [(0.035, 1), (0.1, 0.85), (0.26, 0.58), (0.6, 0.32)]
            : strength > 0.75 ? [(0.05, 1), (0.13, 0.85), (0.32, 0.6), (0.75, 0.4), (1.5, 0.26)]
            : strength > 0.35 ? [(0.07, 0.9), (0.2, 0.6), (0.48, 0.35)] : [(0.09, 0.8), (0.28, 0.45)]
        // Flames: each character's glow flickers on its own.
        let glowStates = style.fill != .fire ? states : zip(glyphs, states).map { g, s in
            var s = s
            s.opacity *= 0.62 + 0.38 * (0.5 + 0.5 * sin(clock * (5.5 + lyricNoise(g.index, 9) * 4) + lyricNoise(g.index, 4) * 6))
            return s
        }
        for layer in layers {
            var c = ctx
            c.addFilter(.blur(radius: max(1, layer.radius * em)))
            if strength > 0.6 { c.blendMode = .plusLighter }
            let alpha = min(1, strength * layer.alpha * 1.15)
            c.drawLayer { content in
                for segment in lit { paint(content, glyphs, states: glowStates, part: segment.part, look: segment.look, bounds: bounds, em: em, glow: alpha) }
            }
        }
        // White-hot tubes bloom white where the song has reached.
        if !led, style.coreWhite > 0.3, strength > 0.6, let sung = segments.first(where: { $0.look == .sung }) {
            var c = ctx
            c.addFilter(.blur(radius: max(1, em * 0.1)))
            c.blendMode = .plusLighter
            c.opacity *= 0.55 * style.coreWhite
            c.drawLayer { content in
                for (g, s) in zip(glyphs, states) { drawGlyph(g, s, part: sung.part, in: content) }
            }
        }
    }

    /// Chromatic fringe: cyan to the left, magenta to the right of sung text; in a burst
    /// (and as a line arrives) the whole line tears into offset slices.
    private func drawSplit(_ ctx: GraphicsContext, _ glyphs: [LaidGlyph], _ states: [GlyphState], em: CGFloat) {
        let arriving = role == .active && age < 0.35
        let tearing = burst || arriving
        let parts = tearing ? [Part.all] : segments.filter { $0.look == .sung }.map(\.part)
        guard !parts.isEmpty else { return }
        let d = tearing ? em * (arriving ? 0.1 * (1 - age / 0.35) + 0.03 : 0.07) : max(1.2, em * 0.05)
        let tick = Int(clock * 40)
        for (colour, dx) in [(Color(hex: "FF2E88"), d), (Color(hex: "22E8FF"), -d)] {
            tinted(ctx, colour) { layer in
                for part in parts {
                    for (g, s) in zip(glyphs, states) {
                        let slice = tearing ? (lyricNoise(g.index, tick) - 0.5) * em * 0.2 : 0
                        drawGlyph(g, s, part: part, nudge: CGSize(width: dx + slice, height: 0), in: layer)
                    }
                }
            }
        }
    }

    private func drawOutline(_ ctx: GraphicsContext, _ glyphs: [LaidGlyph], _ states: [GlyphState], em: CGFloat) {
        let width = CGFloat(style.outline) * em / 43
        for segment in segments {
            let hex = segment.look == .sung ? style.sungOutlineHex ?? style.outlineHex : style.outlineHex
            tinted(ctx, Color(hex: hex)) { layer in
                for (g, s) in zip(glyphs, states) { drawGlyph(g, s, part: segment.part, outline: width, in: layer) }
            }
        }
    }

    private func drawFill(_ ctx: GraphicsContext, _ glyphs: [LaidGlyph], _ states: [GlyphState], bounds: CGRect, em: CGFloat) {
        for segment in segments {
            paint(ctx, glyphs, states: states, part: segment.part, look: segment.look, bounds: bounds, em: em, glow: nil)
        }
    }

    /// Lit LED lamps burn white at the centre and keep their colour at the rim.
    private func drawLampCores(_ ctx: GraphicsContext, _ glyphs: [LaidGlyph], _ states: [GlyphState]) {
        guard let sung = segments.first(where: { $0.look == .sung }), let unit = glyphs.first.map({ $0.size / 12 }) else { return }
        var c = ctx
        c.blendMode = .plusLighter
        c.opacity *= style.coreWhite
        c.addFilter(.blur(radius: unit * 0.16))
        c.drawLayer { layer in
            for (g, s) in zip(glyphs, states) { drawGlyph(g, s, part: sung.part, blur: false, lamp: Lamp.core, in: layer) }
        }
    }

    // MARK: Paint

    private enum Paint {
        case solid(Color)
        case gradient(GraphicsContext.Shading, sheen: GraphicsContext.Shading?)
        case perGlyph((LaidGlyph) -> Color)
    }

    private func paint(_ ctx: GraphicsContext, _ glyphs: [LaidGlyph], states: [GlyphState], part: Part, look: Look,
                       bounds: CGRect, em: CGFloat, glow: Double?) {
        let paint = look == .sung ? paintSung(bounds: bounds, em: em, glow: glow != nil)
            : style.colorUnsung ? paintFill(bounds: bounds, em: em, glow: glow != nil) : paintUnsung(glow: glow != nil)
        let alpha = glow ?? 1
        // Unlit lamps of a coloured sign: same colours at low power.
        let shade = look == .unsung && style.colorUnsung && glow == nil ? 0.42 : 0
        switch paint {
        case .solid(let colour):
            tinted(ctx, colour) { layer in
                for (g, s) in zip(glyphs, states) { drawGlyph(g, s, part: part, opacity: alpha, in: layer) }
                if shade > 0 { layer.blendMode = .sourceAtop; layer.fill(Path(bounds.insetBy(dx: -em, dy: -em)), with: .color(.black.opacity(shade))) }
            }
        case .perGlyph(let colour):
            // One layer per visual row, coloured by a stepped gradient: a colour per glyph, one filter per row.
            let rows = Dictionary(grouping: Array(zip(glyphs, states)), by: { Int($0.0.rect.minY.rounded()) })
            for row in rows.values {
                let sorted = row.sorted { $0.0.rect.minX < $1.0.rect.minX }
                guard let first = sorted.first, let last = sorted.last else { continue }
                let minX = first.0.rect.minX - em, maxX = last.0.rect.maxX + em, span = max(1, maxX - minX)
                var stops: [Gradient.Stop] = []
                for (g, _) in sorted {
                    let c = colour(g)
                    stops.append(.init(color: c, location: (g.rect.minX - minX) / span))
                    stops.append(.init(color: c, location: (g.rect.maxX - minX) / span))
                }
                let area = Path(CGRect(x: minX, y: first.0.rect.minY - em, width: span, height: first.0.rect.height + em * 2))
                ctx.drawLayer { layer in
                    for (g, s) in row { drawGlyph(g, s, part: part, opacity: alpha, in: layer) }
                    layer.blendMode = .sourceAtop
                    layer.fill(area, with: .linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: minX, y: 0), endPoint: CGPoint(x: maxX, y: 0)))
                    if shade > 0 { layer.fill(area, with: .color(.black.opacity(shade))) }
                }
            }
        case .gradient(let shading, let sheen):
            let area = Path(bounds.insetBy(dx: -em, dy: -em))
            ctx.drawLayer { layer in
                for (g, s) in zip(glyphs, states) { drawGlyph(g, s, part: part, opacity: alpha, in: layer) }
                layer.blendMode = .sourceAtop
                layer.fill(area, with: shading)
                if let sheen { layer.fill(area, with: sheen) }
                if shade > 0 { layer.fill(area, with: .color(.black.opacity(shade))) }
            }
        }
    }

    private func paintUnsung(glow: Bool) -> Paint {
        .solid(Color(hex: glow ? style.glowHex : style.baseHex))
    }

    private func paintSung(bounds: CGRect, em: CGFloat, glow: Bool) -> Paint {
        let base = paintFill(bounds: bounds, em: em, glow: glow)
        guard !glow, !led, style.coreWhite > 0.01 else { return base }
        // White-hot core for lit tubes.
        switch base {
        case .gradient(let shading, _):
            let white = GraphicsContext.Shading.color(.white.opacity(style.coreWhite * 0.8))
            return .gradient(shading, sheen: white)
        case .perGlyph, .solid: return base
        }
    }

    private func paintFill(bounds: CGRect, em: CGFloat, glow: Bool) -> Paint {
        switch style.fill {
        case .solid:
            return .solid(Color(hex: glow ? style.glowHex : style.sungHex))
        case .gradient:
            if glow { return .solid(Color(hex: style.glowHex)) }
            let stops = style.gradientHexes.isEmpty ? [style.sungHex, style.baseHex] : style.gradientHexes
            return .gradient(.linearGradient(Gradient(colors: stops.map { Color(hex: $0) }),
                                             startPoint: CGPoint(x: bounds.midX, y: bounds.minY), endPoint: CGPoint(x: bounds.midX, y: bounds.maxY)), sheen: nil)
        case .flow:
            var hexes = style.gradientHexes.isEmpty ? ["FF5E7E", "FFD93D", "4DD8FF", "8F7CFF"] : style.gradientHexes
            if hexes.first != hexes.last { hexes.append(hexes[0]) }
            // One full cycle of the palette every 6 em, repeated across the whole line.
            let span = em * 6
            let repeats = Int(ceil((bounds.width + span) / span)) + 1
            let colours = [Color(hex: hexes[0])] + (0..<repeats).flatMap { _ in hexes.dropFirst().map { Color(hex: $0) } }
            let phase = (clock * style.speed * 0.25).truncatingRemainder(dividingBy: 1)
            let start = bounds.minX - span + CGFloat(phase) * span
            let shading = GraphicsContext.Shading.linearGradient(Gradient(colors: colours), startPoint: CGPoint(x: start, y: bounds.midY),
                                                                 endPoint: CGPoint(x: start + span * CGFloat(repeats), y: bounds.midY))
            // Gloss: a soft white highlight on the upper half.
            let gloss = GraphicsContext.Shading.linearGradient(Gradient(stops: [.init(color: .white.opacity(0.28), location: 0),
                                                                               .init(color: .white.opacity(0), location: 0.55)]),
                                                               startPoint: CGPoint(x: 0, y: bounds.minY), endPoint: CGPoint(x: 0, y: bounds.maxY))
            return .gradient(shading, sheen: glow || led ? nil : gloss)
        case .hue:
            let palette = style.gradientHexes.isEmpty ? ["FF3FD8", "B866FF", "3FE0FF", "3DFFA8", "FFE24A", "FF8A3D"] : style.gradientHexes
            let drift = clock * style.speed * 0.9
            let white = glow || led ? 0 : style.coreWhite
            return .perGlyph { g in HexColor.loop(palette, at: Double(g.index) * 0.55 - drift, towardWhite: white) }
        case .fire:
            if glow { return .solid(Color(hex: style.glowHex)) }
            let flick = sin(clock * 7.3) * 0.04 + sin(clock * 12.1) * 0.025
            let stops: [Gradient.Stop] = [.init(color: Color(hex: "B3200A"), location: 0), .init(color: Color(hex: "F2541B"), location: 0.3 + flick),
                                          .init(color: Color(hex: "FF9A2E"), location: 0.58 + flick), .init(color: Color(hex: "FFD65A"), location: 0.82),
                                          .init(color: Color(hex: "FFF5D2"), location: 1)]
            return .gradient(.linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: bounds.midX, y: bounds.minY),
                                             endPoint: CGPoint(x: bounds.midX, y: bounds.maxY)), sheen: nil)
        case .chrome:
            if glow { return .solid(Color(hex: style.glowHex)) }
            let stops: [Gradient.Stop] = [.init(color: .white, location: 0.12), .init(color: Color(hex: "BFD3EC"), location: 0.5),
                                          .init(color: Color(hex: "26303D"), location: 0.53), .init(color: Color(hex: "5B6675"), location: 0.6),
                                          .init(color: Color(hex: "D9C7B0"), location: 0.84), .init(color: .white, location: 0.97)]
            let shading = GraphicsContext.Shading.linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: bounds.midX, y: bounds.minY),
                                                                 endPoint: CGPoint(x: bounds.midX, y: bounds.maxY))
            return .gradient(shading, sheen: sheen(bounds: bounds, opacity: 0.85))
        }
    }

    /// A diagonal highlight band sweeping across the text.
    private func sheen(bounds: CGRect, opacity: Double) -> GraphicsContext.Shading {
        let period = 3.2 / max(0.25, style.speed)
        let phase = clock.truncatingRemainder(dividingBy: period) / period
        let band = max(40, bounds.height * 1.4)
        let x = bounds.minX - band + CGFloat(phase) * (bounds.width + band * 2)
        return .linearGradient(Gradient(stops: [.init(color: .clear, location: 0), .init(color: .white.opacity(opacity), location: 0.5),
                                                .init(color: .clear, location: 1)]),
                               startPoint: CGPoint(x: x - band / 2, y: bounds.minY), endPoint: CGPoint(x: x + band / 2, y: bounds.maxY))
    }

    // MARK: Extras: caret, ornaments, sparkles, embers

    private func drawExtras(_ ctx: GraphicsContext, _ glyphs: [LaidGlyph], _ states: [GlyphState], em: CGFloat) {
        let pairs = Array(zip(glyphs, states))
        if style.entrance == .typewriter {
            let anchor = pairs.last { $0.1.visible }?.0.rect ?? glyphs[0].rect.offsetBy(dx: -glyphs[0].rect.width, dy: 0)
            if clock.truncatingRemainder(dividingBy: 1) < 0.55 || states.contains(where: { $0.fraction > 0 && $0.fraction < 1 }) {
                let caret = CGRect(x: anchor.maxX + em * 0.06, y: anchor.minY + em * 0.1, width: max(2, em * 0.07), height: anchor.height * 0.8)
                ctx.fill(Path(roundedRect: caret, cornerRadius: 1), with: .color(Color(hex: style.glowHex)))
            }
        }
        if style.ornament.line { drawBrushLine(ctx, pairs, em: em) }
        if style.ornament.seal { drawSeal(ctx, pairs, em: em) }
        switch style.particles {
        case .sparkles: drawSparkles(ctx, pairs, em: em)
        case .embers: drawEmbers(ctx, pairs, em: em)
        case .none: break
        }
    }

    /// Where the karaoke sweep has reached on its row (nil before singing starts).
    private func head(_ pairs: [(LaidGlyph, GlyphState)]) -> (x: CGFloat, glyph: LaidGlyph)? {
        if let partial = pairs.first(where: { $0.1.fraction > 0 && $0.1.fraction < 1 }) {
            return (partial.0.rect.minX + partial.0.rect.width * CGFloat(partial.1.fraction), partial.0)
        }
        guard let last = pairs.last(where: { $0.1.fraction >= 1 }) else { return nil }
        return (last.0.rect.maxX, last.0)
    }

    /// A tapered gold stroke under the sung words (描金).
    private func drawBrushLine(_ ctx: GraphicsContext, _ pairs: [(LaidGlyph, GlyphState)], em: CGFloat) {
        guard let head = head(pairs), let first = pairs.first(where: { $0.0.rect.minY == head.glyph.rect.minY })?.0 else { return }
        let x0 = first.rect.minX + em * 0.05, x1 = head.x
        guard x1 - x0 > em * 0.2 else { return }
        let y = head.glyph.origin.y + em * 0.2
        let thickness = em * 0.05
        var stroke = Path()
        stroke.move(to: CGPoint(x: x0, y: y + thickness * 0.2))
        stroke.addQuadCurve(to: CGPoint(x: x1, y: y - thickness * 0.1), control: CGPoint(x: (x0 + x1) / 2, y: y - thickness * 1.6))
        stroke.addQuadCurve(to: CGPoint(x: x0, y: y + thickness * 0.2), control: CGPoint(x: (x0 + x1) / 2, y: y + thickness * 0.9))
        var c = ctx
        c.addFilter(.shadow(color: Color(hex: "FFD98A").opacity(0.6), radius: em * 0.08))
        c.fill(stroke, with: .linearGradient(Gradient(colors: [Color(hex: "F6DB94"), Color(hex: "D9A64A"), Color(hex: "F6DB94").opacity(0.6)]),
                                             startPoint: CGPoint(x: x0, y: y), endPoint: CGPoint(x: x1, y: y)))
    }

    /// A red seal stamped beside the line once it has been sung.
    private func drawSeal(_ ctx: GraphicsContext, _ pairs: [(LaidGlyph, GlyphState)], em: CGFloat) {
        guard let karaoke, let last = pairs.last?.0, karaoke.time > karaoke.end else { return }
        let p = min(1, (karaoke.time - karaoke.end) / 0.22)
        let side = em * 0.6
        let centre = CGPoint(x: last.rect.maxX + side * 0.85, y: last.rect.midY - em * 0.04)
        var c = ctx
        c.opacity *= p
        c.translateBy(x: centre.x, y: centre.y)
        c.rotate(by: .degrees(-7))
        c.scaleBy(x: 1.45 - 0.45 * easeOutCubic(p), y: 1.45 - 0.45 * easeOutCubic(p))
        let rect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
        c.fill(Path(roundedRect: rect, cornerRadius: side * 0.12), with: .color(Color(hex: "C2342A")))
        c.stroke(Path(roundedRect: rect.insetBy(dx: side * 0.09, dy: side * 0.09), cornerRadius: side * 0.06),
                 with: .color(Color(hex: "FBE9DF").opacity(0.75)), lineWidth: max(0.8, side * 0.035))
        let mark = c.resolve(Text("听").font(.custom("STKaitiSC-Black", size: side * 0.6)).foregroundColor(Color(hex: "FBEFE6")))
        c.draw(mark, at: CGPoint(x: 0, y: side * 0.02), anchor: .center)
    }

    /// Glints that bloom and fade where the words have been sung; each stays put for its short life.
    private func drawSparkles(_ ctx: GraphicsContext, _ pairs: [(LaidGlyph, GlyphState)], em: CGFloat) {
        let lit = pairs.filter { $0.1.fraction > 0.35 && $0.1.visible }
        guard !lit.isEmpty else { return }
        var c = ctx
        c.blendMode = .plusLighter
        let count = min(6, 2 + lit.count / 2)
        for k in 0..<count {
            let t = clock / 0.9 + Double(k) / Double(count)
            let slot = Int(floor(t)), phase = t - floor(t)
            let g = lit[Int(lyricNoise(slot, k) * Double(lit.count)) % lit.count].0
            let point = CGPoint(x: g.rect.minX + g.rect.width * (0.05 + 0.9 * lyricNoise(slot, k + 13)),
                                y: g.rect.minY + g.rect.height * (0.08 + 0.55 * lyricNoise(slot, k + 29)))
            let bloom = sin(Double.pi * phase)
            star(c, at: point, size: em * (0.08 + 0.07 * lyricNoise(slot, k + 5)) * bloom,
                 colour: k % 3 == 0 ? Color(hex: style.glowHex) : .white, opacity: bloom)
        }
    }

    private func star(_ ctx: GraphicsContext, at p: CGPoint, size: CGFloat, colour: Color, opacity: Double) {
        var path = Path()
        path.move(to: CGPoint(x: p.x, y: p.y - size))
        path.addQuadCurve(to: CGPoint(x: p.x + size, y: p.y), control: p)
        path.addQuadCurve(to: CGPoint(x: p.x, y: p.y + size), control: p)
        path.addQuadCurve(to: CGPoint(x: p.x - size, y: p.y), control: p)
        path.addQuadCurve(to: CGPoint(x: p.x, y: p.y - size), control: p)
        var c = ctx
        c.opacity *= opacity
        c.addFilter(.shadow(color: colour, radius: size * 0.9))
        c.fill(path, with: .color(colour))
    }

    /// Sparks rising off burning characters: hot white-yellow, cooling to orange as they fade.
    private func drawEmbers(_ ctx: GraphicsContext, _ pairs: [(LaidGlyph, GlyphState)], em: CGFloat) {
        var c = ctx
        c.blendMode = .plusLighter
        for (g, s) in pairs where s.fraction > 0.5 && lyricNoise(g.index, 77) < 0.7 {
            let rate = 0.55 + lyricNoise(g.index, 11) * 0.4
            let phase = (clock * rate + lyricNoise(g.index, 3)).truncatingRemainder(dividingBy: 1)
            let x = g.rect.midX + (lyricNoise(g.index, 5) - 0.5) * g.rect.width * 0.7 + sin(phase * 5 + Double(g.index)) * em * 0.08
            let y = g.rect.minY + g.rect.height * 0.2 - phase * em * 0.95
            let r = em * 0.038 * (1 - phase * 0.65)
            var spark = c
            spark.opacity *= phase < 0.12 ? phase / 0.12 : 1 - (phase - 0.12) / 0.88
            spark.addFilter(.shadow(color: Color(hex: "FF6A00"), radius: r * 2.6))
            spark.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                       with: .color(Color(hex: phase < 0.45 ? "FFF1B8" : "FFAA45")))
        }
    }

    // MARK: Easing

    private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private func ease(_ x: Double) -> Double { let t = clamp(x); return t * t * (3 - 2 * t) }
    private func easeOutCubic(_ x: Double) -> Double { let t = 1 - clamp(x); return 1 - t * t * t }
    private func easeOutBack(_ x: Double) -> Double {
        let t = clamp(x) - 1, c = 1.7
        return 1 + (c + 1) * t * t * t + c * t * t
    }
}
