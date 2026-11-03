import AppKit
import SwiftUI

/// Renders every lyric preset at chosen song times into a contact sheet PNG.
/// Usage: style-snapshot <out.png> [time] [width]
@main struct StyleSnapshot {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        let output = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "styles.png")
        let time = arguments.count > 2 ? Double(arguments[2]) ?? 1.6 : 1.6
        let width = CGFloat(arguments.count > 3 ? Double(arguments[3]) ?? 560 : 560)
        let only = arguments.count > 4 ? arguments[4].split(separator: ",").compactMap { LyricPreset(rawValue: String($0)) } : LyricPreset.allCases
        let sheet = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(only.enumerated()), id: \.offset) { index, preset in
                HStack(alignment: .center, spacing: 0) {
                    Text(preset.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                        .frame(width: 90, alignment: .leading).padding(.leading, 12)
                    LyricStageFrame(track: .demo, time: time, clock: 1000 + time, style: preset.style, width: width)
                }
                .background(index % 2 == 0
                    ? LinearGradient(colors: [Color(hex: "1C2733"), Color(hex: "3D5A73")], startPoint: .leading, endPoint: .trailing)
                    : LinearGradient(colors: [Color(hex: "6E7F8F"), Color(hex: "C9B9A3")], startPoint: .leading, endPoint: .trailing))
            }
        }
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 1.5
        guard let image = renderer.cgImage else { print("FAIL: render"); exit(1) }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { print("FAIL: encode"); exit(1) }
        try! png.write(to: output)
        print("wrote \(output.path) \(image.width)x\(image.height)")
    }
}
