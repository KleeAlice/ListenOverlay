import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Images for the README: every preset in a grid, and an animated GIF of the signature styles,
/// all on a neutral dark backdrop (no system wallpapers, so the images can be published).
/// Usage: readme-images <out dir>
/// Build: xcrun swiftc -swift-version 5 -O -target arm64-apple-macos26.0 Sources/Support/ColorHex.swift \
///   Sources/Overlay/{GlyphLayout,GlyphPainter,LyricStageView,LyricTimeline,LyricStyle}.swift Tools/Snapshot/ReadmeImages.swift -o .build/snap/readme-images
@main struct ReadmeImages {
    static let backdrop = LinearGradient(colors: [Color(hex: "171C29"), Color(hex: "262B40"), Color(hex: "33283F")],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)

    @MainActor static func main() {
        let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/images")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        grid(to: folder.appendingPathComponent("styles.png"))
        animation(to: folder.appendingPathComponent("demo.gif"))
    }

    /// All presets, two per row, each mid-line so the karaoke fill shows.
    @MainActor static func grid(to url: URL) {
        let width: CGFloat = 430
        let presets = LyricPreset.allCases
        let rows = stride(from: 0, to: presets.count, by: 2).map { Array(presets[$0..<min($0 + 2, presets.count)]) }
        let sheet = VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 18) {
                    ForEach(row) { preset in
                        VStack(alignment: .leading, spacing: 8) {
                            LyricStageFrame(track: .demo, time: 1.9, clock: 1001.9, style: preset.style, width: width)
                                .frame(width: width + 100, height: 190)
                                .background(Color(hex: "1D2232"))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            HStack(spacing: 8) {
                                Text(preset.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                Text(preset.detail).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                            .padding(.leading, 4)
                        }
                    }
                }
            }
        }
        .padding(22)
        .background(Color(hex: "0E1117"))
        save(sheet, to: url, scale: 1.5)
    }

    /// Four signature styles from one fully sung line, through the line change, to the next fully sung line
    /// (so the loop joins two lit lines instead of jumping mid-song).
    @MainActor static func animation(to url: URL) {
        let presets: [LyricPreset] = [.neonPixel, .neonSign, .rainbow, .guofeng]
        let width: CGFloat = 500, fps = 15.0
        let times = stride(from: 3.4, to: 7.4, by: 1 / fps).map { $0 }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, times.count, nil) else { return }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for t in times {
            let frame = VStack(spacing: 0) {
                ForEach(presets) { preset in
                    LyricStageFrame(track: .demo, time: t, clock: 1000 + t, style: preset.style, width: width)
                        .frame(width: width + 100, height: 150)
                }
            }
            .background(backdrop)
            let renderer = ImageRenderer(content: frame)
            renderer.scale = 1
            guard let image = renderer.cgImage else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
        }
        print(CGImageDestinationFinalize(destination) ? "wrote \(url.path)" : "FAIL \(url.lastPathComponent)")
    }

    @MainActor static func save<V: View>(_ view: V, to url: URL, scale: CGFloat) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("FAIL \(url.lastPathComponent)"); return
        }
        try? png.write(to: url)
        print("wrote \(url.path) \(image.width)x\(image.height)")
    }
}
