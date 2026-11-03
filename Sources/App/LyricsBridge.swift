import Foundation

extension SongQuery {
    init(_ track: TrackObservation) {
        self.init(title: track.title, artist: track.artist, album: track.album, duration: track.duration,
                  netEaseID: track.netEaseID, preferredSource: track.source == .netEase ? .netEase : nil)
    }
}

extension StageTrack {
    /// Display lines for fetched lyrics. Word pieces are converted one by one so
    /// their offsets still add up to the converted line.
    static func make(lyrics: Lyrics, title: String, artist: String, duration: Double?, simplified: Bool) -> StageTrack {
        let id = lyrics.candidate.id
        func text(_ value: String) -> String { ChineseDisplay.text(value, simplified: simplified) }
        if lyrics.instrumental && lyrics.lines.allSatisfy(\.text.isEmpty) {
            return StageTrack(id: id, title: text(title), artist: text(artist), lines: [], timing: .none, message: "纯音乐，请欣赏")
        }
        if lyrics.lines.isEmpty {
            let plain = text(lyrics.plainText ?? "")
            if let duration, !plain.isEmpty { return .estimated(id: id, title: text(title), artist: text(artist), text: plain, duration: duration) }
            return StageTrack(id: id, title: text(title), artist: text(artist), lines: [], timing: .none,
                              message: plain.isEmpty ? "暂未找到歌词" : plain.components(separatedBy: .newlines).first)
        }
        let raw = lyrics.lines.map { line -> (start: Double, end: Double?, text: String, translation: String?, words: [(start: Double, end: Double, text: String)]) in
            let words = (line.words ?? []).map { (start: $0.start, end: $0.end, text: text($0.text)) }
            let joined = words.map(\.text).joined()
            let converted = text(line.text)
            return (line.start, line.end, words.isEmpty || joined != converted ? converted : joined,
                    line.translation.map(text), words.isEmpty || joined != converted ? [] : words)
        }
        return .make(id: id, title: text(title), artist: text(artist), lines: raw, timing: .synced)
    }

    static func message(_ text: String, title: String = "", artist: String = "", id: String = "message") -> StageTrack {
        StageTrack(id: id, title: title, artist: artist, lines: [], timing: .none, message: text)
    }
}

extension MatchTier {
    var symbol: String {
        switch self {
        case .exact: return "checkmark.seal.fill"
        case .strong: return "checkmark.circle.fill"
        case .version: return "music.note.list"
        case .loose: return "questionmark.circle"
        }
    }
}
