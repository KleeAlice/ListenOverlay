import AppKit
import CoreText
import SwiftUI

/// One glyph, positioned in its block (top-left origin, y down).
struct LaidGlyph {
    let path: Path
    /// Advance box: x, line top, advance width, ascent + descent.
    let rect: CGRect
    let index: Int
    /// UTF-16 offset of the glyph's first character.
    let character: Int
    let font: CTFont
    let glyph: CGGlyph
    /// Baseline origin in block coordinates.
    let origin: CGPoint
    /// Effective point size after any shrink-to-fit.
    let size: CGFloat
}

/// A line of lyrics typeset once with Core Text; drawing it is just filling paths.
final class GlyphBlock: @unchecked Sendable {
    let glyphs: [LaidGlyph]
    let size: CGSize
    let lineRects: [CGRect]
    let em: CGFloat

    init(glyphs: [LaidGlyph], size: CGSize, lineRects: [CGRect], em: CGFloat) {
        self.glyphs = glyphs; self.size = size; self.lineRects = lineRects; self.em = em
    }

    static let empty = GlyphBlock(glyphs: [], size: .zero, lineRects: [], em: 20)
}

enum GlyphLayout {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: GlyphBlock] = [:]

    /// Typesets `text`, wrapping into at most `maxLines` balanced lines and
    /// shrinking (down to 60 %) when it still does not fit `maxWidth`.
    static func block(_ text: String, font: NSFont, kern: CGFloat, maxWidth: CGFloat, maxLines: Int = 2,
                      alignment: LyricAlignment = .center, cached: Bool = true) -> GlyphBlock {
        let key = "\(text)\u{1}\(font.fontName)\u{1}\(font.pointSize)\u{1}\(kern)\u{1}\(maxWidth.isFinite && maxWidth < 1e6 ? Int(maxWidth) : -1)\u{1}\(maxLines)\u{1}\(alignment.rawValue)"
        if cached {
            lock.lock(); let hit = cache[key]; lock.unlock()
            if let hit { return hit }
        }
        let value = make(text, font: font, kern: kern, maxWidth: maxWidth, maxLines: maxLines, alignment: alignment)
        if cached {
            lock.lock()
            if cache.count > 400 { cache.removeAll(keepingCapacity: true) }
            cache[key] = value
            lock.unlock()
        }
        return value
    }

    private static func make(_ text: String, font: NSFont, kern: CGFloat, maxWidth: CGFloat, maxLines: Int, alignment: LyricAlignment) -> GlyphBlock {
        let clean = text.replacingOccurrences(of: "\n", with: " ")
        guard !clean.isEmpty else { return .empty }
        let string = NSAttributedString(string: clean, attributes: [.font: font, .kern: kern])
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let length = string.length
        let full = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: length))
        let fullWidth = CGFloat(CTLineGetTypographicBounds(full, nil, nil, nil))

        // Split into balanced lines only when needed.
        var ranges: [CFRange] = []
        if fullWidth <= maxWidth || maxLines <= 1 {
            ranges = [CFRange(location: 0, length: length)]
        } else {
            let lines = min(maxLines, Int(ceil(fullWidth / maxWidth)))
            let target = min(maxWidth, fullWidth / CGFloat(lines) * 1.06 + font.pointSize)
            var start = 0
            while start < length && ranges.count < maxLines {
                let remaining = ranges.count == maxLines - 1
                let count = remaining ? length - start : max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(target)))
                ranges.append(CFRange(location: start, length: count))
                start += count
            }
        }

        var glyphs: [LaidGlyph] = []
        var lineRects: [CGRect] = []
        var lines: [(CTLine, CGFloat, CGFloat, CGFloat)] = []
        for range in ranges {
            let line = CTTypesetterCreateLine(typesetter, range)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            lines.append((line, width, ascent, descent))
        }
        let blockWidth = lines.map(\.1).max() ?? 0
        var y: CGFloat = 0
        for (line, width, ascent, descent) in lines {
            let x = (blockWidth - width) * (alignment == .leading ? 0 : alignment == .center ? 0.5 : 1)
            let baseline = y + ascent
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let anyFont = attributes[kCTFontAttributeName as String] else { continue }
                let runFont = anyFont as! CTFont
                var ids = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &ids)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                for k in 0..<count {
                    let origin = CGPoint(x: x + positions[k].x, y: baseline)
                    var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: origin.x, ty: origin.y)
                    let path = CTFontCreatePathForGlyph(runFont, ids[k], &transform).map(Path.init) ?? Path()
                    let rect = CGRect(x: origin.x, y: y, width: max(0, advances[k].width), height: ascent + descent)
                    guard rect.width > 0.01 || !path.isEmpty else { continue }
                    glyphs.append(LaidGlyph(path: path, rect: rect, index: glyphs.count, character: indices[k], font: runFont, glyph: ids[k],
                                            origin: origin, size: CTFontGetSize(runFont)))
                }
            }
            lineRects.append(CGRect(x: x, y: y, width: width, height: ascent + descent))
            y += (ascent + descent) * 1.12
        }
        var size = CGSize(width: blockWidth, height: max(0, y - (lines.last.map { ($0.2 + $0.3) * 0.12 } ?? 0)))
        let em = font.pointSize * 1.2
        // Still too wide: shrink the whole block.
        if size.width > maxWidth, maxWidth > 0 {
            let scale = max(0.6, maxWidth / size.width)
            let t = CGAffineTransform(scaleX: scale, y: scale)
            glyphs = glyphs.map { LaidGlyph(path: $0.path.applying(t), rect: $0.rect.applying(t), index: $0.index, character: $0.character,
                                            font: $0.font, glyph: $0.glyph, origin: $0.origin.applying(t), size: $0.size * scale) }
            lineRects = lineRects.map { $0.applying(t) }
            size = CGSize(width: size.width * scale, height: size.height * scale)
            return GlyphBlock(glyphs: glyphs, size: size, lineRects: lineRects, em: em * scale)
        }
        return GlyphBlock(glyphs: glyphs, size: size, lineRects: lineRects, em: em)
    }
}

/// Glyph images rendered once by Core Text and reused across lines and frames,
/// so animating text never re-tessellates outlines.
final class GlyphSprites: @unchecked Sendable {
    static let shared = GlyphSprites()
    struct Sprite {
        let image: Image
        /// Relative to the glyph's baseline origin (top-left coordinates).
        let bounds: CGRect
    }
    private struct Key: Hashable {
        let font: String
        let glyph: CGGlyph
        let size: Int
        let outline: Int
        let dots: Int
        let scale: Int
    }
    private let lock = NSLock()
    private var cache: [Key: Sprite?] = [:]
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// White glyph (or glyph plus stroke of `outline` points); nil for blank glyphs.
    /// With `dots`, the glyph's font pixels (12 per em) as round lamps of that radius in pixels instead.
    func sprite(_ glyph: LaidGlyph, outline: CGFloat = 0, dots: CGFloat = 0, scale: CGFloat) -> Sprite? {
        let key = Key(font: CTFontCopyPostScriptName(glyph.font) as String, glyph: glyph.glyph, size: Int((glyph.size * 100).rounded()),
                      outline: Int((outline * 100).rounded()), dots: Int((dots * 100).rounded()), scale: Int((scale * 10).rounded()))
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let made = make(glyph, outline: outline, dots: dots, scale: scale)
        lock.lock()
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = made
        lock.unlock()
        return made
    }

    private func make(_ g: LaidGlyph, outline: CGFloat, dots: CGFloat, scale: CGFloat) -> Sprite? {
        let font = abs(CTFontGetSize(g.font) - g.size) < 0.01 ? g.font : CTFontCreateCopyWithAttributes(g.font, g.size, nil, nil)
        var glyph = g.glyph
        let box = CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, nil, 1)
        guard !box.isNull, box.width > 0.01, box.height > 0.01 else { return nil }
        let unit = g.size / 12
        let pad = dots > 0 ? unit * dots + 2 : outline + 2
        let rect = box.insetBy(dx: -pad, dy: -pad).integral
        let width = Int(ceil(rect.width * scale)), height = Int(ceil(rect.height * scale))
        guard width > 0, height > 0, width < 4096, height < 4096,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: Self.space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        if dots > 0 {
            // One lamp at the centre of every font pixel the glyph covers.
            guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { return nil }
            let r = unit * dots
            for j in Int(floor(box.minY / unit))..<Int(ceil(box.maxY / unit)) {
                for i in Int(floor(box.minX / unit))..<Int(ceil(box.maxX / unit)) {
                    let centre = CGPoint(x: (CGFloat(i) + 0.5) * unit, y: (CGFloat(j) + 0.5) * unit)
                    if path.contains(centre) { ctx.fillEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)) }
                }
            }
        } else if outline > 0, let path = CTFontCreatePathForGlyph(font, glyph, nil) {
            ctx.addPath(path)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(outline * 2); ctx.setLineJoin(.round); ctx.setLineCap(.round)
            ctx.drawPath(using: .fillStroke)
        } else {
            var position = CGPoint.zero
            CTFontDrawGlyphs(font, &glyph, &position, 1, ctx)
        }
        guard let image = ctx.makeImage() else { return nil }
        return Sprite(image: Image(decorative: image, scale: scale), bounds: CGRect(x: rect.minX, y: -rect.maxY, width: rect.width, height: rect.height))
    }
}
