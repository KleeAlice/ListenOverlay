import Foundation

/// One sung word or syllable. Times are absolute song seconds.
struct LyricWord: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

struct LyricLine: Codable, Equatable, Sendable {
    var start: Double
    /// From word timing, the KRC line duration or the next line's start.
    var end: Double?
    /// "" marks an instrumental gap.
    var text: String
    var translation: String?
    /// Word-level timing when available (Kugou KRC, enhanced LRC). When present,
    /// the word texts joined together equal `text` exactly.
    var words: [LyricWord]?
}

enum LyricsSource: String, Codable, CaseIterable, Sendable {
    case netEase, qqMusic, kugou, lrclib

    var displayName: String {
        switch self {
        case .netEase: return "网易云音乐"
        case .qqMusic: return "QQ 音乐"
        case .kugou: return "酷狗音乐"
        case .lrclib: return "LRCLIB"
        }
    }
}

/// Lower is better.
enum MatchTier: Int, Codable, Comparable, Sendable {
    case exact, strong, version, loose

    var label: String {
        switch self {
        case .exact: return "精确匹配"
        case .strong: return "匹配"
        case .version: return "相近版本"
        case .loose: return "同名歌曲"
        }
    }

    static func < (lhs: MatchTier, rhs: MatchTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct SongQuery: Codable, Hashable, Sendable {
    var title: String
    var artist: String
    var album: String?
    /// Seconds.
    var duration: Double?
    /// The NetEase player's own song ID when known.
    var netEaseID: Int64?
    /// The platform the user is playing on (NetEase → .netEase, QQ → .qqMusic).
    var preferredSource: LyricsSource?
}

struct LyricsCandidate: Identifiable, Codable, Hashable, Sendable {
    /// "<source>:<remoteID>"
    var id: String
    var source: LyricsSource
    var remoteID: String
    var title: String
    var artist: String
    var album: String?
    var duration: Double?
    var tier: MatchTier
    var score: Double
    /// Short Chinese reason, e.g. 「现场版 · 使用录音室歌词，时间轴可能有偏差」.
    var note: String
    /// Provider specifics, e.g. the Kugou access key.
    var extra: [String: String]
}

struct Lyrics: Codable, Sendable {
    var candidate: LyricsCandidate
    /// Synced lines; empty when only plain text exists.
    var lines: [LyricLine]
    var plainText: String?
    var credits: [String]
    var instrumental: Bool

    var isSynced: Bool { !lines.isEmpty }
    var hasWordTiming: Bool { lines.contains { $0.words?.isEmpty == false } }
    var hasTranslation: Bool { lines.contains { $0.translation?.isEmpty == false } }
}

struct LyricsLookup: Sendable {
    var query: SongQuery
    /// The user's choice first, otherwise the best automatic match.
    var lyrics: Lyrics?
    /// Every plausible candidate, best first (feeds the 「换一个版本」 picker).
    var candidates: [LyricsCandidate]
    var fromCache: Bool
    var userChosen: Bool
    /// Provider errors in Chinese, for diagnostics.
    var failures: [String]
}
