import Foundation

/// A word inside a line; `range` is in UTF-16 offsets of the line text.
struct StageWord: Equatable, Sendable {
    var start: Double
    var end: Double
    var range: Range<Int>
}

struct StageLine: Equatable, Sendable {
    var start: Double
    /// When singing of this line ends (word timing, or an estimate).
    var end: Double
    var text: String
    var translation: String?
    var words: [StageWord] = []
    var isGap: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Everything the desktop lyrics need for one song, independent of where the lyrics came from.
struct StageTrack: Equatable, Sendable {
    enum Timing: Equatable, Sendable { case synced, estimated, none }
    var id: String
    var title: String
    var artist: String
    var lines: [StageLine]
    var timing: Timing
    /// Shown instead of lyrics when there are no lines (纯音乐、正在查找…).
    var message: String?

    static let empty = StageTrack(id: "empty", title: "", artist: "", lines: [], timing: .none, message: nil)

    /// Builds lines with sensible ends; words are given as text pieces with absolute times.
    static func make(id: String, title: String, artist: String,
                     lines raw: [(start: Double, end: Double?, text: String, translation: String?, words: [(start: Double, end: Double, text: String)])],
                     timing: Timing, message: String? = nil) -> StageTrack {
        let sorted = raw.sorted { $0.start < $1.start }
        var lines: [StageLine] = []
        for (index, item) in sorted.enumerated() {
            let next = index + 1 < sorted.count ? sorted[index + 1].start : nil
            var words: [StageWord] = []
            var cursor = 0
            let utf16 = (item.text as NSString).length
            if !item.words.isEmpty, item.words.map(\.text).joined() == item.text {
                for word in item.words {
                    let length = (word.text as NSString).length
                    words.append(StageWord(start: word.start, end: max(word.start + 0.05, word.end), range: cursor..<(cursor + length)))
                    cursor += length
                }
            }
            let end = item.end ?? words.last?.end ?? estimatedEnd(start: item.start, next: next, length: utf16)
            lines.append(StageLine(start: item.start, end: max(item.start + 0.2, min(end, next.map { max(item.start + 0.2, $0) } ?? end)),
                                   text: item.text, translation: item.translation, words: words))
        }
        return StageTrack(id: id, title: title, artist: artist, lines: lines, timing: timing, message: message)
    }

    /// Typical singing pace without word timing: long lines get more time, gaps do not.
    static func estimatedEnd(start: Double, next: Double?, length: Int) -> Double {
        let singing = max(1.4, Double(length) * 0.42 + 0.8)
        guard let next else { return start + singing }
        return start + min(max(0.3, next - start - 0.12), singing)
    }

    /// Plain-text lyrics spread over the song so they still scroll (marked 估算).
    static func estimated(id: String, title: String, artist: String, text: String, duration: Double) -> StageTrack {
        let rows = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !rows.isEmpty, duration > 20 else {
            return StageTrack(id: id, title: title, artist: artist, lines: [], timing: .none, message: rows.first)
        }
        let intro = min(18, duration * 0.08), outro = min(15, duration * 0.06)
        let weights = rows.map { Double(max(4, ($0 as NSString).length)) }
        let total = weights.reduce(0, +)
        var cursor = intro
        let span = max(10, duration - intro - outro)
        let raw = zip(rows, weights).map { row, weight -> (start: Double, end: Double?, text: String, translation: String?, words: [(start: Double, end: Double, text: String)]) in
            defer { cursor += span * weight / total }
            return (cursor, nil, row, nil, [])
        }
        return make(id: id, title: title, artist: artist, lines: raw, timing: .estimated)
    }

    func index(at time: Double) -> Int? {
        guard let first = lines.first, time >= first.start else { return nil }
        var lower = 0, upper = lines.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lines[middle].start <= time { lower = middle + 1 } else { upper = middle }
        }
        return lower - 1
    }
}

/// Song position extrapolated from the last observation.
struct Playhead: Equatable, Sendable {
    var position: Double
    var date: Date
    var rate: Double
    static let stopped = Playhead(position: 0, date: .distantPast, rate: 0)
    func position(at now: Date) -> Double { max(0, position + max(0, now.timeIntervalSince(date)) * rate) }
    var isPlaying: Bool { rate > 0 }
}

/// Karaoke timing for one line, evaluated per glyph by the renderer.
struct KaraokeTiming: Equatable {
    var time: Double
    var start: Double
    var end: Double
    var words: [StageWord]

    var lineFraction: Double { end > start ? min(1, max(0, (time - start) / (end - start))) : (time >= start ? 1 : 0) }

    /// Sung fraction (0…1) of a glyph: word timing uses its UTF-16 offset, line timing its glyph order.
    func fraction(character: Int, glyph: Int, of count: Int) -> Double {
        if !words.isEmpty {
            if let word = words.first(where: { $0.range.contains(character) }) {
                let local = word.end > word.start ? min(1, max(0, (time - word.start) / (word.end - word.start))) : (time >= word.start ? 1 : 0)
                return min(1, max(0, local * Double(word.range.count) - Double(character - word.range.lowerBound)))
            }
            if let last = words.last, character >= last.range.upperBound { return time >= last.end ? 1 : 0 }
            if let first = words.first, character < first.range.lowerBound { return time >= first.start ? 1 : 0 }
        }
        return min(1, max(0, lineFraction * Double(max(1, count)) - Double(glyph)))
    }

    /// Song time at which a glyph starts to be sung.
    func onset(character: Int, glyph: Int, of count: Int) -> Double {
        if let word = words.first(where: { $0.range.contains(character) }) {
            return word.start + (word.end - word.start) * Double(character - word.range.lowerBound) / Double(max(1, word.range.count))
        }
        return start + (end - start) * Double(glyph) / Double(max(1, count))
    }
}

/// What the stage shows at one instant.
struct StageFrame: Equatable {
    var index: Int?
    var age: Double
    var previous: Int?
    var exit: Double
    /// Seconds until the next line during an intro or a long gap (KTV-style dots).
    var countdown: Double?
    var resting: Bool

    /// Lines switch a little early so the eye is ready; karaoke fill stays exact.
    static let lead = 0.12

    static func at(_ time: Double, in track: StageTrack) -> StageFrame {
        let lines = track.lines
        guard !lines.isEmpty else { return StageFrame(index: nil, age: 0, previous: nil, exit: 1, countdown: nil, resting: true) }
        var index = track.index(at: time + lead)
        // Empty lines are instrumental breaks: keep the last sung line, dimmed.
        var resting = false
        if let current = index, lines[current].isGap {
            resting = true
            index = lines[..<current].lastIndex { !$0.isGap }
        }
        let nextStart = lines.first { $0.start > time + lead && !$0.isGap }?.start
        var countdown: Double?
        if let index {
            let line = lines[index]
            if time > line.end + 1.2, let nextStart, nextStart - line.end > 4 { resting = true }
            if resting, let nextStart, nextStart - time <= 3 { countdown = max(0, nextStart - time) }
        } else if let nextStart, nextStart - time <= 3 {
            countdown = max(0, nextStart - time)
        }
        let start = index.map { lines[$0].start } ?? 0
        let age = max(0, time + lead - start)
        let previous = index.flatMap { current in lines[..<current].lastIndex { !$0.isGap } }
        return StageFrame(index: index, age: age, previous: previous, exit: min(1, age / 0.32), countdown: countdown, resting: resting)
    }
}

extension StageTrack {
    /// Looping sample used by style previews and the gallery.
    static let demo: StageTrack = {
        let rows: [(Double, String, String?)] = [
            (0.4, "听见每一句歌词跳动", "Every lyric comes alive"),
            (4.4, "七彩的光在桌面流淌", "Colours flowing across the desk"),
            (8.4, "让旋律成为你的风景", "Let the melody be your view")
        ]
        let raw = rows.map { start, text, translation -> (start: Double, end: Double?, text: String, translation: String?, words: [(start: Double, end: Double, text: String)]) in
            let characters = text.map(String.init)
            let step = 2.9 / Double(characters.count)
            let words = characters.enumerated().map { (start + Double($0.offset) * step, start + Double($0.offset + 1) * step, $0.element) }
            return (start, start + 2.9, text, translation, words)
        }
        return make(id: "demo", title: "听见", artist: "桌面歌词", lines: raw, timing: .synced)
    }()
    static let demoLength = 12.4
}
