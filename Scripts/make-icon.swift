import AppKit

// Renders Resources/AppIcon.icns: a night-sky tile with a glowing gradient waveform,
// half "sung" (bright) and half waiting, like the desktop lyrics.
// Usage: xcrun swift Scripts/make-icon.swift <out.iconset>
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let s = CGFloat(pixels) / 1024
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(tile); ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let sky = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.10, green: 0.08, blue: 0.20, alpha: 1),
                                                      CGColor(srgbRed: 0.04, green: 0.05, blue: 0.08, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let brand = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.49, green: 0.91, blue: 1.0, alpha: 1),
                                                        CGColor(srgbRed: 0.71, green: 0.55, blue: 1.0, alpha: 1),
                                                        CGColor(srgbRed: 1.0, green: 0.48, blue: 0.77, alpha: 1)] as CFArray, locations: [0, 0.55, 1])!
    let heights: [CGFloat] = [170, 300, 470, 360, 560, 400, 250, 150]
    let bars = CGMutablePath()
    for (index, height) in heights.enumerated() {
        let x = 222 + CGFloat(index) * 76
        bars.addPath(CGPath(roundedRect: CGRect(x: x, y: 512 - height / 2, width: 42, height: height), cornerWidth: 21, cornerHeight: 21, transform: nil))
    }
    // Glow.
    for (blur, alpha) in [(70.0, 0.55), (26.0, 0.8)] {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: blur, color: CGColor(srgbRed: 0.6, green: 0.6, blue: 1.0, alpha: alpha))
        ctx.addPath(bars); ctx.setFillColor(CGColor(srgbRed: 0.6, green: 0.62, blue: 1, alpha: 0.35)); ctx.fillPath()
        ctx.restoreGState()
    }
    // Sung half: gradient; waiting half: dim.
    ctx.saveGState()
    ctx.addPath(bars); ctx.clip()
    ctx.drawLinearGradient(brand, start: CGPoint(x: 222, y: 0), end: CGPoint(x: 802, y: 0), options: [])
    ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.06, blue: 0.1, alpha: 0.55))
    ctx.fill(CGRect(x: 600, y: 0, width: 400, height: 1024))
    ctx.restoreGState()
    ctx.restoreGState()
    ctx.addPath(tile); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.09)); ctx.setLineWidth(3); ctx.strokePath()
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: folder.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: folder.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote \(folder.path)")
