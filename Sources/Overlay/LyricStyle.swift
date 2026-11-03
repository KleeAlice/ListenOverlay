import AppKit
import CoreText
import SwiftUI

enum LyricTypeface: String, Codable, CaseIterable, Identifiable {
    case system, rounded, yuanti, songti, kaiti, xingkai, weibei, libian, handwriting, pixel, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "苹方"
        case .rounded: return "圆润"
        case .yuanti: return "圆体"
        case .songti: return "宋体"
        case .kaiti: return "楷体"
        case .xingkai: return "行楷"
        case .weibei: return "魏碑"
        case .libian: return "隶书"
        case .handwriting: return "手写"
        case .pixel: return "像素"
        case .mono: return "等宽"
        }
    }
    /// System fonts that macOS installs on demand (Font Book "downloadable").
    var downloadableFamily: String? {
        switch self {
        case .yuanti: return "Yuanti SC"
        case .songti: return "Songti SC"
        case .kaiti: return "Kaiti SC"
        case .xingkai: return "Xingkai SC"
        case .weibei: return "Weibei SC"
        case .libian: return "Libian SC"
        case .handwriting: return "HanziPen SC"
        default: return nil
        }
    }
    /// Brush and display faces draw Latin poorly; English lines use the system font instead.
    var isDecorativeCJK: Bool { [.kaiti, .xingkai, .weibei, .libian, .handwriting].contains(self) }
    private func postScriptName(_ weight: LyricWeight) -> String? {
        let heavy = weight.rank >= LyricWeight.bold.rank, black = weight.rank >= LyricWeight.heavy.rank
        switch self {
        case .yuanti: return heavy ? "STYuanti-SC-Bold" : weight.rank <= LyricWeight.regular.rank ? "STYuanti-SC-Light" : "STYuanti-SC-Regular"
        case .songti: return black ? "STSongti-SC-Black" : heavy ? "STSongti-SC-Bold" : "STSongti-SC-Regular"
        case .kaiti: return black ? "STKaitiSC-Black" : heavy ? "STKaitiSC-Bold" : "STKaitiSC-Regular"
        case .xingkai: return heavy ? "STXingkaiSC-Bold" : "STXingkaiSC-Light"
        case .weibei: return "WeibeiSC-Bold"
        case .libian: return "STLibianSC-Regular"
        case .handwriting: return heavy ? "HanziPenSC-W5" : "HanziPenSC-W3"
        case .pixel: return "Fusion-Pixel-12px-Prop-zh-Hans-Regular"
        case .system, .rounded, .mono: return nil
        }
    }
    /// Pixel glyphs stay crisp only at whole multiples of their 12 px grid.
    func displaySize(_ size: Double) -> Double {
        guard self == .pixel else { return size }
        return max(24, (size / 12).rounded() * 12)
    }
    func font(size: Double, weight: LyricWeight) -> Font {
        let size = displaySize(size)
        if self == .pixel { _ = LyricFonts.registerBundled }
        if let name = postScriptName(weight), NSFont(name: name, size: CGFloat(size)) != nil {
            return .custom(name, size: size)
        }
        if let family = downloadableFamily { Task { @MainActor in FontProvisioner.shared.ensure(family) } }
        let design: Font.Design = self == .rounded ? .rounded : self == .mono ? .monospaced : self == .songti ? .serif : .default
        return .system(size: size, weight: weight.fontWeight, design: design)
    }
    func nsFont(size: Double, weight: LyricWeight) -> NSFont {
        let size = CGFloat(displaySize(size))
        if self == .pixel { _ = LyricFonts.registerBundled }
        if let name = postScriptName(weight), let font = NSFont(name: name, size: size) { return font }
        if let family = downloadableFamily { Task { @MainActor in FontProvisioner.shared.ensure(family) } }
        if self == .mono { return .monospacedSystemFont(ofSize: size, weight: weight.nsWeight) }
        let base = NSFont.systemFont(ofSize: size, weight: weight.nsWeight)
        let design: NSFontDescriptor.SystemDesign = self == .rounded ? .rounded : self == .songti ? .serif : .default
        return base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}

enum LyricWeight: String, Codable, CaseIterable, Identifiable {
    case light, regular, medium, semibold, bold, heavy, black
    var id: String { rawValue }
    var rank: Int { LyricWeight.allCases.firstIndex(of: self) ?? 0 }
    var title: String { ["细", "常规", "中等", "半粗", "粗", "特粗", "极粗"][rank] }
    var fontWeight: Font.Weight { [.light, .regular, .medium, .semibold, .bold, .heavy, .black][rank] }
    var nsWeight: NSFont.Weight { [.light, .regular, .medium, .semibold, .bold, .heavy, .black][rank] }
}

/// How sung text is coloured. Unsung text is always the solid 未唱颜色.
enum LyricFill: String, Codable, CaseIterable, Identifiable {
    case solid, gradient, flow, hue, fire, chrome
    var id: String { rawValue }
    var title: String {
        switch self {
        case .solid: return "纯色"
        case .gradient: return "渐变"
        case .flow: return "流动色带"
        case .hue: return "逐字彩色"
        case .fire: return "火焰"
        case .chrome: return "金属"
        }
    }
}

enum LyricMotion: String, Codable, CaseIterable, Identifiable {
    case none, float, wave, bounce, jitter, pulse, shimmer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "静止"
        case .float: return "悬浮"
        case .wave: return "波浪"
        case .bounce: return "逐字弹跳"
        case .jitter: return "故障闪动"
        case .pulse: return "呼吸"
        case .shimmer: return "热浪"
        }
    }
}

enum LyricEntrance: String, Codable, CaseIterable, Identifiable {
    case none, fade, rise, pop, ink, typewriter, scramble, pixel
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "直接切换"
        case .fade: return "淡入"
        case .rise: return "上浮"
        case .pop: return "弹出"
        case .ink: return "墨迹晕开"
        case .typewriter: return "打字机"
        case .scramble: return "乱码解码"
        case .pixel: return "霓虹点亮"
        }
    }
}

enum LyricParticles: String, Codable, CaseIterable, Identifiable {
    case none, sparkles, embers
    var id: String { rawValue }
    var title: String { self == .none ? "无" : self == .sparkles ? "唱处星光" : "火星" }
}

/// Small finishing touches drawn with the active line.
enum LyricOrnament: String, Codable, CaseIterable, Identifiable {
    case none, brushLine, seal, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "无"
        case .brushLine: return "描金下划线"
        case .seal: return "唱完盖章"
        case .both: return "下划线和印章"
        }
    }
    var line: Bool { self == .brushLine || self == .both }
    var seal: Bool { self == .seal || self == .both }
}

enum LyricLayout: String, Codable, CaseIterable, Identifiable {
    case stack, ktv, ticker
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stack: return "居中双行"
        case .ktv: return "KTV 交错"
        case .ticker: return "跑马灯滚动"
        }
    }
}

enum LyricSecondary: String, Codable, CaseIterable, Identifiable {
    case auto, next, translation, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "翻译优先"
        case .next: return "下一句"
        case .translation: return "仅翻译"
        case .none: return "单行"
        }
    }
}

enum LyricAlignment: String, Codable, CaseIterable, Identifiable {
    case leading, center, trailing
    var id: String { rawValue }
    var title: String { self == .leading ? "左" : self == .center ? "中" : "右" }
    var horizontal: HorizontalAlignment { self == .leading ? .leading : self == .center ? .center : .trailing }
    var text: TextAlignment { self == .leading ? .leading : self == .center ? .center : .trailing }
}

struct LyricStyle: Codable, Equatable {
    var preset: LyricPreset = .clean
    var typeface: LyricTypeface = .system
    var weight: LyricWeight = .bold
    var fontSize: Double = 34
    var letterSpacing: Double = 0.5
    var opacity: Double = 1
    var fill: LyricFill = .solid
    /// 未唱颜色 (always solid and opaque, so text never turns muddy over a wallpaper).
    var baseHex = "FFFFFF"
    /// 已唱颜色 for solid fills.
    var sungHex = "8BE9FF"
    /// Colours for gradient, flow and per-character fills.
    var gradientHexes: [String] = []
    /// Lit glyphs fade toward white at their core, like a neon tube (0…1).
    var coreWhite: Double = 0
    /// Unsung text also wears the fill colours, dimmed (a coloured sign at low power until sung).
    var colorUnsung = false
    var glow: Double = 0.2
    var glowHex = "8BE9FF"
    /// Glow only where the song has reached (neon "lighting up").
    var glowOnSung = false
    var outline: Double = 0
    var outlineHex = "0B1220"
    var sungOutlineHex: String?
    var shadow = true
    /// Soft dark halo behind the words: keeps light text readable on light wallpapers (0…1).
    var backing: Double = 0
    var motion: LyricMotion = .none
    var entrance: LyricEntrance = .rise
    var karaoke = true
    var particles: LyricParticles = .none
    var ornament: LyricOrnament = .none
    var flicker = false
    /// Pixel font drawn as an LED matrix: a round lamp per font pixel on a dark housing.
    var pixelGrid = false
    var rgbSplit = false
    var chaseLights = false
    var layout: LyricLayout = .stack
    var secondary: LyricSecondary = .auto
    var alignment: LyricAlignment = .center
    var speed: Double = 1

    static let preferenceKey = "lyricStyle.v3"

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LyricStyle()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        preset = v(.preset, d.preset); typeface = v(.typeface, d.typeface); weight = v(.weight, d.weight)
        fontSize = min(72, max(16, v(.fontSize, d.fontSize))); letterSpacing = min(8, max(0, v(.letterSpacing, d.letterSpacing)))
        opacity = min(1, max(0, v(.opacity, d.opacity))); fill = v(.fill, d.fill)
        baseHex = v(.baseHex, d.baseHex); sungHex = v(.sungHex, d.sungHex); gradientHexes = v(.gradientHexes, d.gradientHexes)
        coreWhite = min(1, max(0, v(.coreWhite, d.coreWhite)))
        colorUnsung = v(.colorUnsung, d.colorUnsung)
        glow = min(1, max(0, v(.glow, d.glow))); glowHex = v(.glowHex, d.glowHex); glowOnSung = v(.glowOnSung, d.glowOnSung)
        outline = min(6, max(0, v(.outline, d.outline))); outlineHex = v(.outlineHex, d.outlineHex)
        sungOutlineHex = v(.sungOutlineHex, d.sungOutlineHex); shadow = v(.shadow, d.shadow)
        backing = min(1, max(0, v(.backing, d.backing)))
        motion = v(.motion, d.motion); entrance = v(.entrance, d.entrance); karaoke = v(.karaoke, d.karaoke)
        particles = v(.particles, d.particles); ornament = v(.ornament, d.ornament); flicker = v(.flicker, d.flicker)
        pixelGrid = v(.pixelGrid, d.pixelGrid); rgbSplit = v(.rgbSplit, d.rgbSplit); chaseLights = v(.chaseLights, d.chaseLights)
        layout = v(.layout, d.layout); secondary = v(.secondary, d.secondary); alignment = v(.alignment, d.alignment)
        speed = min(3, max(0.25, v(.speed, d.speed)))
        let colours = [baseHex, sungHex, glowHex, outlineHex] + gradientHexes + [sungOutlineHex].compactMap { $0 }
        guard colours.allSatisfy(HexColor.isValid) else { self = LyricStyle(); return }
    }

    static func load(from defaults: UserDefaults = .standard) -> LyricStyle {
        guard let data = defaults.data(forKey: preferenceKey), data.count < 16_384,
              let value = try? JSONDecoder().decode(LyricStyle.self, from: data) else { return LyricPreset.clean.style }
        return value
    }
    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.preferenceKey) }
    }

    var isModified: Bool { self != preset.style.with(fontSize: fontSize, opacity: opacity) }
    func with(fontSize: Double, opacity: Double) -> LyricStyle {
        var copy = self; copy.fontSize = fontSize; copy.opacity = opacity; return copy
    }
    var font: Font { typeface.font(size: fontSize, weight: weight) }
    var secondarySize: Double { typeface == .pixel ? max(24, typeface.displaySize(fontSize) - 12) : (fontSize * 0.6).rounded() }
    /// Room for glow, outline and motion around the glyphs.
    var effectPadding: CGFloat {
        CGFloat(10 + glow * 34 + backing * 10 + outline * 2 + (motion == .bounce ? fontSize * 0.35 : 0) + (ornament == .none ? 0 : fontSize * 0.2))
    }
}

enum LyricPreset: String, Codable, CaseIterable, Identifiable {
    case clean, ktv, jelly, rainbow, neonPixel, neonSign, guofeng, marquee, glitch, typewriter, aurora, fire, chrome, stardust
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clean: return "清透"
        case .ktv: return "卡拉 OK"
        case .jelly: return "果冻弹跳"
        case .rainbow: return "七彩流光"
        case .neonPixel: return "霓虹像素"
        case .neonSign: return "霓虹灯牌"
        case .guofeng: return "古风墨韵"
        case .marquee: return "跑马灯"
        case .glitch: return "赛博故障"
        case .typewriter: return "打字机"
        case .aurora: return "极光"
        case .fire: return "烈焰"
        case .chrome: return "液态金属"
        case .stardust: return "星尘"
        }
    }
    var detail: String {
        switch self {
        case .clean: return "白字柔光，逐字染色，最易读"
        case .ktv: return "左右交错双行，经典描边逐字填色"
        case .jelly: return "唱到的字会 Q 弹跳起"
        case .rainbow: return "唱过的字铺上七彩色带，色带持续流动"
        case .neonPixel: return "LED 点阵灯珠，七彩流动，唱到哪里灯珠全亮"
        case .neonSign: return "灯管式霓虹，唱到哪里亮到哪里"
        case .guofeng: return "楷书宣纸色，唱过鎏金，描金线，唱完盖章"
        case .marquee: return "琥珀色字幕随歌声滚动，灯泡追逐闪烁"
        case .glitch: return "乱码解码入场，不时出现信号撕裂"
        case .typewriter: return "跟着演唱逐字敲出，字落下有键击感"
        case .aurora: return "极光色带缓缓流过，字随波起伏"
        case .fire: return "唱过的字燃起火焰，火星向上飘散"
        case .chrome: return "镜面金属质感，高光循环扫过"
        case .stardust: return "宋体白字，唱到哪里星光闪到哪里"
        }
    }
    var badges: [String] {
        switch self {
        case .clean: return ["逐字", "易读"]
        case .ktv: return ["逐字", "描边"]
        case .jelly: return ["弹跳"]
        case .rainbow: return ["七彩", "流动"]
        case .neonPixel: return ["七彩", "强发光", "像素"]
        case .neonSign: return ["霓虹", "点亮"]
        case .guofeng: return ["楷书", "印章"]
        case .marquee: return ["滚动", "灯泡"]
        case .glitch: return ["故障", "解码"]
        case .typewriter: return ["逐字出现"]
        case .aurora: return ["流动", "波浪"]
        case .fire: return ["火焰", "粒子"]
        case .chrome: return ["高光"]
        case .stardust: return ["星光"]
        }
    }

    var style: LyricStyle {
        var s = LyricStyle()
        s.preset = self
        switch self {
        case .clean:
            s.typeface = .system; s.weight = .bold; s.baseHex = "FFFFFF"; s.sungHex = "8BE9FF"; s.glow = 0.18; s.glowHex = "8BE9FF"
            s.entrance = .rise
        case .ktv:
            s.typeface = .yuanti; s.weight = .heavy; s.fontSize = 36; s.baseHex = "FFFFFF"; s.sungHex = "2F9BFF"
            s.outline = 3; s.outlineHex = "12357F"; s.sungOutlineHex = "FFFFFF"; s.glow = 0; s.layout = .ktv
            s.entrance = .fade; s.secondary = .next
        case .jelly:
            s.typeface = .yuanti; s.weight = .heavy; s.fontSize = 36; s.baseHex = "FFFFFF"; s.sungHex = "FF5FA2"
            s.outline = 2.5; s.outlineHex = "FF5FA2"; s.sungOutlineHex = "FFFFFF"; s.motion = .bounce; s.entrance = .pop; s.glow = 0.15; s.glowHex = "FF8CC6"
        case .rainbow:
            s.typeface = .yuanti; s.weight = .heavy; s.fontSize = 38; s.fill = .flow
            s.gradientHexes = ["FF4D6D", "FF9233", "FFD60A", "3DDC84", "22C7FF", "6E6BFF", "D45CFF"]
            s.baseHex = "FFFFFF"; s.outline = 2.6; s.outlineHex = "2A1B4A"; s.sungOutlineHex = "FFFFFF"
            s.glow = 0.4; s.glowHex = "FFFFFF"; s.glowOnSung = true; s.entrance = .pop; s.speed = 0.8
        case .neonPixel:
            s.typeface = .pixel; s.weight = .regular; s.fontSize = 36; s.letterSpacing = 0; s.pixelGrid = true; s.fill = .flow
            s.gradientHexes = ["FF2E9A", "B04BFF", "3D7BFF", "21E6FF", "3DFFB5", "FFE53D", "FF8A2B"]
            s.colorUnsung = true; s.coreWhite = 0.85; s.glow = 0.9; s.glowHex = "FF2E9A"; s.glowOnSung = true
            s.backing = 0.9; s.shadow = false; s.flicker = true; s.entrance = .pixel; s.speed = 0.9
        case .neonSign:
            s.typeface = .rounded; s.weight = .semibold; s.fontSize = 38; s.letterSpacing = 1.5
            s.baseHex = "8E78A8"; s.outline = 1.8; s.outlineHex = "1A1024"; s.sungHex = "FFF2FB"; s.sungOutlineHex = "FF3DBE"
            s.glow = 0.9; s.glowHex = "FF3DBE"; s.glowOnSung = true; s.shadow = false; s.flicker = true; s.entrance = .pixel
        case .guofeng:
            s.typeface = .kaiti; s.weight = .bold; s.fontSize = 38; s.letterSpacing = 4; s.baseHex = "EFE8DA"
            s.fill = .gradient; s.gradientHexes = ["FFE6A3", "EDB348", "C9862A"]; s.sungHex = "E7AE4A"
            s.outline = 1.2; s.outlineHex = "2B1A0E"; s.sungOutlineHex = "3A1F0B"
            s.glow = 0.16; s.glowHex = "FFD98A"; s.glowOnSung = true; s.backing = 0.2
            s.entrance = .ink; s.ornament = .both
        case .marquee:
            s.typeface = .system; s.weight = .heavy; s.fontSize = 34; s.layout = .ticker; s.chaseLights = true
            s.baseHex = "FFC56B"; s.sungHex = "FFF6E2"; s.glow = 0.5; s.glowHex = "FFAE3D"
            s.outline = 2; s.outlineHex = "2B1704"; s.backing = 0.2; s.entrance = .none; s.secondary = .none; s.shadow = false
        case .glitch:
            s.typeface = .mono; s.weight = .bold; s.fontSize = 32; s.baseHex = "AAB7CA"; s.sungHex = "FFFFFF"
            s.outline = 1.2; s.outlineHex = "070B12"; s.glow = 0.15; s.glowHex = "22E8FF"; s.glowOnSung = true
            s.rgbSplit = true; s.motion = .jitter; s.entrance = .scramble
        case .typewriter:
            s.typeface = .mono; s.weight = .semibold; s.fontSize = 30; s.baseHex = "F6F1E6"; s.sungHex = "F6F1E6"
            s.outline = 1; s.outlineHex = "17120B"; s.glowHex = "FFB547"
            s.entrance = .typewriter; s.glow = 0; s.letterSpacing = 1
        case .aurora:
            s.typeface = .rounded; s.weight = .bold; s.fontSize = 36; s.fill = .flow
            s.gradientHexes = ["35F2B5", "2FD2FF", "6F86FF", "B56BFF", "FF6FD8"]; s.baseHex = "FFFFFF"
            s.outline = 2; s.outlineHex = "0F2140"; s.sungOutlineHex = "0F2140"
            s.glow = 0.45; s.glowHex = "35F2B5"; s.glowOnSung = true; s.motion = .wave; s.entrance = .fade; s.speed = 0.6
        case .fire:
            s.typeface = .system; s.weight = .black; s.fontSize = 38; s.fill = .fire; s.baseHex = "FFE9D6"
            s.outline = 2; s.outlineHex = "2B0A05"; s.sungOutlineHex = "3A0D06"
            s.glow = 0.6; s.glowHex = "FF7A1A"; s.glowOnSung = true; s.particles = .embers; s.motion = .shimmer; s.entrance = .rise
        case .chrome:
            s.typeface = .system; s.weight = .black; s.fontSize = 38; s.fill = .chrome; s.baseHex = "8E9AAB"
            s.outline = 1.6; s.outlineHex = "121820"; s.sungOutlineHex = "121820"
            s.glow = 0.12; s.glowHex = "FFFFFF"; s.glowOnSung = true; s.entrance = .pop
        case .stardust:
            s.typeface = .songti; s.weight = .bold; s.fontSize = 36; s.baseHex = "B7B0DA"; s.sungHex = "FFFFFF"
            s.outline = 0.9; s.outlineHex = "1A1535"; s.glow = 0.5; s.glowHex = "B9A8FF"; s.glowOnSung = true; s.particles = .sparkles
            s.entrance = .fade; s.letterSpacing = 2
        }
        return s
    }
}

enum LyricFonts {
    static let registerBundled: Void = {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Fonts/fusion-pixel.otf")
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Fonts/fusion-pixel.otf")
        if let url = [bundled, development].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}

/// Asks macOS to fetch its on-demand Chinese fonts (楷体、行楷、魏碑…) the first time a style needs them.
@MainActor final class FontProvisioner: ObservableObject {
    static let shared = FontProvisioner()
    @Published private(set) var generation = 0
    @Published private(set) var downloading = Set<String>()
    private var requested = Set<String>()

    func ensure(_ family: String) {
        guard !requested.contains(family), NSFontManager.shared.availableMembers(ofFontFamily: family) == nil else { return }
        requested.insert(family); downloading.insert(family)
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler([descriptor] as CFArray, nil) { state, _ in
            if state == .didFinish || state == .didFailWithError {
                Task { @MainActor in
                    FontProvisioner.shared.downloading.remove(family)
                    FontProvisioner.shared.generation += 1
                }
            }
            return true
        }
    }
}
