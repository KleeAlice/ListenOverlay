import Foundation

enum ListenMode: String, Codable, CaseIterable, Identifiable {
    case lyrics, auto, captions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lyrics: return "歌词"
        case .auto: return "歌词 + 字幕"
        case .captions: return "实时字幕"
        }
    }
    var detail: String {
        switch self {
        case .lyrics: return "跟随播放器显示歌词，不录制声音"
        case .auto: return "有歌时显示歌词，其余时间把 Mac 的声音转成字幕"
        case .captions: return "把 Mac 正在播放的声音实时转成中英文字幕"
        }
    }
}

enum OverlayPlacement: String, Codable, CaseIterable, Identifiable {
    case top, bottom, custom
    var id: String { rawValue }
    var title: String { self == .top ? "屏幕上方" : self == .bottom ? "屏幕下方" : "自由位置" }
}

enum MiniPlayerStyle: String, Codable, CaseIterable, Identifiable {
    case capsule, vinyl, glass, album, minimal, hidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .capsule: return "胶囊"
        case .vinyl: return "黑胶唱片"
        case .glass: return "玻璃卡片"
        case .album: return "专辑氛围"
        case .minimal: return "极简细线"
        case .hidden: return "隐藏"
        }
    }
    var detail: String {
        switch self {
        case .capsule: return "封面随播放旋转，进度环绕封面"
        case .vinyl: return "唱片转动、唱臂落下，暂停即停"
        case .glass: return "原生液态玻璃，信息最完整"
        case .album: return "封面虚化成流动的背景色"
        case .minimal: return "一行歌名加一条进度线"
        case .hidden: return "只显示歌词"
        }
    }
}

struct OverlaySettings: Codable, Equatable {
    var visible = true
    /// Click-through: lyrics never take the mouse (hover still shows the unlock badge).
    var locked = false
    var placement: OverlayPlacement = .top
    /// Lyric column width as a share of the screen's visible width.
    var widthFraction = 0.6
    var customX: Double?
    var customY: Double?
    var miniPlayer: MiniPlayerStyle = .capsule
    var hideWhenPaused = false
    var hideWhenNoLyrics = false
    var showToolbarOnHover = true
    /// Animation frame rate: 20 省电, 30 标准, 60 流畅.
    var frameRate = 30

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OverlaySettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        visible = v(.visible, d.visible); locked = v(.locked, d.locked); placement = v(.placement, d.placement)
        widthFraction = min(0.95, max(0.3, v(.widthFraction, d.widthFraction)))
        customX = v(.customX, d.customX); customY = v(.customY, d.customY)
        miniPlayer = v(.miniPlayer, d.miniPlayer); hideWhenPaused = v(.hideWhenPaused, d.hideWhenPaused)
        hideWhenNoLyrics = v(.hideWhenNoLyrics, d.hideWhenNoLyrics); showToolbarOnHover = v(.showToolbarOnHover, d.showToolbarOnHover)
        frameRate = [20, 30, 60].contains(v(.frameRate, d.frameRate)) ? v(.frameRate, d.frameRate) : d.frameRate
    }
}

struct SourceSettings: Codable, Equatable {
    var mode: ListenMode = .lyrics
    var followNetEase = true
    /// Identify songs from the Mac's sound when no player reports them (QQ 音乐 and others).
    var listenToIdentify = false
    var captionLanguage = "auto"
    var simplifiedChinese = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SourceSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        mode = v(.mode, d.mode); followNetEase = v(.followNetEase, d.followNetEase)
        listenToIdentify = v(.listenToIdentify, d.listenToIdentify); captionLanguage = v(.captionLanguage, d.captionLanguage)
        simplifiedChinese = v(.simplifiedChinese, d.simplifiedChinese)
    }
}

enum SettingsStore {
    static func load<T: Codable>(_ type: T.Type, key: String, fallback: T, defaults: UserDefaults = .standard) -> T {
        guard let data = defaults.data(forKey: key), data.count < 65_536,
              let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return value
    }
    static func save<T: Codable>(_ value: T, key: String, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
