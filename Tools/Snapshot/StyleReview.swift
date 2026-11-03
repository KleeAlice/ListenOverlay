import AppKit
import SwiftUI

/// Design review: each lyric preset at real size (2× pixels) over a dark, a colourful and a light
/// macOS wallpaper, plus a filmstrip of consecutive frames across a line change to judge motion.
/// Usage: style-review <out dir> [preset,preset…|all|sheet] [time]   ("sheet": all presets per wallpaper)
/// Build: xcrun swiftc -swift-version 5 -O -target arm64-apple-macos26.0 Sources/Support/ColorHex.swift \
///   Sources/Overlay/{GlyphLayout,GlyphPainter,LyricStageView,LyricTimeline,LyricStyle}.swift Tools/Snapshot/StyleReview.swift -o .build/snap/style-review
@main struct StyleReview {
    static let wallpapers = ["/System/Library/Desktop Pictures/Big Sur Graphic Dark.heic", "/System/Library/Desktop Pictures/Sonoma.heic",
                             "/System/Library/Desktop Pictures/iMac Silver.heic"]

    @MainActor static func main() {
        let arguments = CommandLine.arguments
        let folder = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "review")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let presets = arguments.count > 2 && arguments[2] != "all"
            ? arguments[2].split(separator: ",").compactMap { LyricPreset(rawValue: String($0)) } : LyricPreset.allCases
        let time = arguments.count > 3 ? Double(arguments[3]) ?? 1.7 : 1.7
        let images = wallpapers.compactMap { path -> NSImage? in
            NSImage(contentsOfFile: path) ?? NSImage(contentsOfFile: path.replacingOccurrences(of: "Desktop Pictures/", with: "Desktop Pictures/.thumbnails/"))
        }
        let width: CGFloat = 760
        if arguments.count > 2 && arguments[2] == "sheet" {
            // Every preset over one wallpaper, stacked, for side-by-side review.
            for (index, image) in images.enumerated() {
                let sheet = VStack(spacing: 0) {
                    ForEach(LyricPreset.allCases) { preset in
                        let size = LyricStageMetrics.size(preset.style, width: width)
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: size.width, height: size.height).offset(y: [CGFloat(-160), 120, 40][index % 3]).clipped()
                            LyricStageFrame(track: .demo, time: time, clock: 1000 + time, style: preset.style, width: width)
                            Text(preset.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.55)).padding(6)
                        }
                        .frame(width: size.width, height: size.height)
                    }
                }
                save(sheet, to: folder.appendingPathComponent("sheet-\(index).png"), scale: 1)
            }
            print("wrote sheets to \(folder.path)")
            return
        }
        for preset in presets {
            let style = preset.style
            let size = LyricStageMetrics.size(style, width: width)
            let stills = VStack(spacing: 0) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    ZStack {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .offset(y: [CGFloat(-160), 120, 40][index % 3])
                            .clipped()
                        LyricStageFrame(track: .demo, time: time, clock: 1000 + time, style: style, width: width)
                    }
                    .frame(width: size.width, height: size.height)
                }
            }
            save(stills, to: folder.appendingPathComponent("\(preset.rawValue)-stills.png"))
            // Motion: eight frames, 1/15 s apart, across a line change and mid-line.
            let film = VStack(spacing: 2) {
                ForEach([4.30, 4.37, 4.44, 4.51, 4.58, 4.70, 5.6, 5.67], id: \.self) { t in
                    ZStack {
                        Color(hex: "151922")
                        LyricStageFrame(track: .demo, time: t, clock: 1000 + t, style: style, width: width)
                    }
                    .frame(width: size.width, height: size.height)
                }
            }
            save(film, to: folder.appendingPathComponent("\(preset.rawValue)-film.png"), scale: 1)
        }
        print("wrote \(presets.count) presets to \(folder.path)")
    }

    @MainActor static func save<V: View>(_ view: V, to url: URL, scale: CGFloat = 2) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { print("FAIL \(url.lastPathComponent)"); return }
        try? png.write(to: url)
    }
}
