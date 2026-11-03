import Compression
import Foundation

/// The song a lyric body claims to belong to; used to recognise its 「歌名 - 歌手」 header line.
struct LyricsTitleHint: Sendable {
    var title: String
    var artist: String
}

struct ParsedLyrics: Sendable {
    var lines: [LyricLine]
    var credits: [String]
    var plainText: String?
    var instrumental: Bool
    var tags: [String: String]

    var hasContent: Bool { instrumental || !lines.isEmpty || !(plainText ?? "").isEmpty }
}

enum LyricsParser {
    // MARK: - Entry points

    /// LRC with optional translation LRC (merged by timestamp within 0.1 s).
    static func parseLRC(_ text: String, translation: String? = nil, hint: LyricsTitleHint? = nil) -> ParsedLyrics {
        let main = scanLRC(text)
        guard !main.entries.isEmpty else {
            let plain = main.untimed.joined(separator: "\n")
            var parsed = parsePlain(plain, hint: hint)
            parsed.credits = main.jsonCredits + parsed.credits
            parsed.tags = main.tags
            return parsed
        }
        var entries = main.entries
        applyOffset(&entries, tags: main.tags)
        var translations: [(time: Double, text: String)] = []
        if let translation, !translation.isEmpty {
            let scanned = scanLRC(translation)
            var translated = scanned.entries
            applyOffset(&translated, tags: scanned.tags)
            translations = translated.compactMap { entry in
                let value = entry.text.trimmingCharacters(in: .whitespaces)
                return isUsableTranslation(value) ? (entry.time, value) : nil
            }
        }
        return finish(entries, tags: main.tags, hint: hint, extraCredits: main.jsonCredits, translations: translations)
    }

    /// Untimed text. Leading credits and a 「歌名 - 歌手」 header are moved to `credits`.
    static func parsePlain(_ text: String, hint: LyricsTitleHint? = nil) -> ParsedLyrics {
        var entries: [Entry] = []
        var credits: [String] = []
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("{"), line.hasSuffix("}") {
                if let credit = jsonCredit(line) { credits.append(credit) }
                continue
            }
            // Section headers such as [Chorus] / [Verse 1] are not sung.
            if line.hasPrefix("["), line.hasSuffix("]"), line.count <= 32, !line.dropFirst().contains("[") { continue }
            entries.append(Entry(time: Double(index), text: line, order: index))
        }
        credits += extractCredits(&entries, hint: hint, tags: [:])
        var rows: [String] = []
        for entry in entries {
            if entry.text.isEmpty {
                if let last = rows.last, !last.isEmpty { rows.append("") }
            } else {
                rows.append(entry.text)
            }
        }
        while rows.last?.isEmpty == true { rows.removeLast() }
        let texts = rows.filter { !$0.isEmpty }
        if !texts.isEmpty, texts.allSatisfy(isInstrumentalMarker) {
            return ParsedLyrics(lines: [], credits: credits, plainText: nil, instrumental: true, tags: [:])
        }
        if texts.isEmpty || texts.allSatisfy(isPlaceholder) {
            return ParsedLyrics(lines: [], credits: credits, plainText: nil, instrumental: false, tags: [:])
        }
        return ParsedLyrics(lines: [], credits: credits, plainText: rows.joined(separator: "\n"), instrumental: false, tags: [:])
    }

    /// Decoded KRC text: `[startMs,durMs]<offsetMs,durMs,0>字…`, translations from the `[language:]` tag.
    static func parseKRC(_ text: String, hint: LyricsTitleHint? = nil) -> ParsedLyrics {
        var tags: [String: String] = [:]
        var entries: [Entry] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let inside = line[line.index(after: line.startIndex)..<close]
            if let (start, duration) = krcLineTiming(inside) {
                let body = line[line.index(after: close)...]
                let words = krcWords(body, lineStart: start)
                if words.isEmpty {
                    entries.append(Entry(time: start, text: body.trimmingCharacters(in: .whitespaces), end: start + duration, order: entries.count))
                    continue
                }
                let (lineText, cleanedWords) = tidyWords(words)
                entries.append(Entry(time: start, text: lineText, words: cleanedWords.isEmpty ? nil : cleanedWords,
                                     end: start + duration, order: entries.count))
            } else if let (key, value) = tag(inside) {
                tags[key] = value
            }
        }
        if let encoded = tags["language"], let translations = krcTranslations(encoded) {
            for index in entries.indices where index < translations.count {
                let value = translations[index].trimmingCharacters(in: .whitespaces)
                if isUsableTranslation(value), value != entries[index].text { entries[index].translation = value }
            }
        }
        applyOffset(&entries, tags: tags)
        return finish(entries, tags: tags, hint: hint, extraCredits: [], translations: [])
    }

    // MARK: - KRC decoding

    private static let krcKey: [UInt8] = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105]

    /// base64 → drop "krc1" → XOR with the 16-byte key → zlib → UTF-8.
    static func decodeKRC(base64: String) throws -> String {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), data.count > 6 else {
            throw LyricsLookupError.decodeFailed
        }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x6B, bytes[1] == 0x72, bytes[2] == 0x63, bytes[3] == 0x31 else { throw LyricsLookupError.decodeFailed }
        var payload = Array(bytes[4...])
        for index in payload.indices { payload[index] ^= krcKey[index & 15] }
        // RFC 1950 header: CM = 8 (deflate) and the check bits; COMPRESSION_ZLIB expects raw DEFLATE.
        guard payload.count > 2, payload[0] & 0x0F == 8, (UInt16(payload[0]) << 8 | UInt16(payload[1])) % 31 == 0 else {
            throw LyricsLookupError.decodeFailed
        }
        let inflated = try inflate(payload[2...], limit: 8 << 20)
        var text = String(decoding: inflated, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    static func inflate(_ input: ArraySlice<UInt8>, limit: Int) throws -> [UInt8] {
        guard !input.isEmpty else { throw LyricsLookupError.decodeFailed }
        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        stream.initialize(to: compression_stream(dst_ptr: buffer, dst_size: 0, src_ptr: UnsafePointer(buffer), src_size: 0, state: nil))
        defer { stream.deinitialize(count: 1); stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw LyricsLookupError.decodeFailed
        }
        defer { compression_stream_destroy(stream) }
        var output: [UInt8] = []
        try input.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { throw LyricsLookupError.decodeFailed }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = source.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                output.append(contentsOf: UnsafeBufferPointer(start: buffer, count: produced))
                guard output.count <= limit else { throw LyricsLookupError.tooLarge }
                if status == COMPRESSION_STATUS_END { return }
                guard status == COMPRESSION_STATUS_OK else { throw LyricsLookupError.decodeFailed }
                if produced == 0 && stream.pointee.src_size == 0 {
                    // Truncated stream: keep what was decoded if anything.
                    if output.isEmpty { throw LyricsLookupError.decodeFailed }
                    return
                }
            }
        }
        return output
    }

    private static func krcLineTiming(_ inside: Substring) -> (Double, Double)? {
        let parts = inside.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]), let duration = Int(parts[1]), start >= 0, duration >= 0 else { return nil }
        return (Double(start) / 1000, Double(duration) / 1000)
    }

    private static func krcWords(_ body: Substring, lineStart: Double) -> [LyricWord] {
        var words: [LyricWord] = []
        var index = body.startIndex
        var pending: (start: Double, end: Double)?
        var text = ""
        func flush() {
            if let timing = pending, !text.isEmpty { words.append(LyricWord(start: timing.start, end: timing.end, text: text)) }
            text = ""
        }
        while index < body.endIndex {
            if body[index] == "<", let close = body[index...].firstIndex(of: ">") {
                let parts = body[body.index(after: index)..<close].split(separator: ",", omittingEmptySubsequences: false)
                if parts.count >= 2, let offset = Int(parts[0]), let duration = Int(parts[1]) {
                    flush()
                    let start = lineStart + Double(offset) / 1000
                    pending = (start, start + Double(max(0, duration)) / 1000)
                    index = body.index(after: close)
                    continue
                }
            }
            text.append(body[index])
            index = body.index(after: index)
        }
        flush()
        return words
    }

    private static func krcTranslations(_ encoded: String) -> [String]? {
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let payload = try? JSONDecoder().decode(KRCLanguage.self, from: data) else { return nil }
        guard let item = payload.content?.first(where: { $0.type == 1 }), let rows = item.lyricContent else { return nil }
        return rows.map { $0.joined() }
    }

    private struct KRCLanguage: Decodable {
        struct Item: Decodable {
            var type: Int?
            var lyricContent: [[String]]?
        }
        var content: [Item]?
    }

    // MARK: - HTML entities (QQ Music)

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";"),
               let decoded = entity(text[text.index(after: index)..<semicolon]) {
                result.append(decoded)
                index = text.index(after: semicolon)
                continue
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    private static func entity(_ name: Substring) -> String? {
        switch name {
        case "apos": return "'"
        case "quot": return "\""
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "nbsp": return " "
        default: break
        }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") { value = UInt32(digits.dropFirst(), radix: 16) } else { value = UInt32(digits) }
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }

    // MARK: - LRC scanning

    struct Entry {
        var time: Double
        var text: String
        var words: [LyricWord]?
        var end: Double?
        var translation: String?
        var order: Int
        /// Enhanced LRC: a closing `<mm:ss.xx>` after the last word.
        var trailingWordEnd: Double?
    }

    private struct Scan {
        var entries: [Entry] = []
        var tags: [String: String] = [:]
        var untimed: [String] = []
        var jsonCredits: [String] = []
    }

    private static func scanLRC(_ text: String) -> Scan {
        var scan = Scan()
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            guard !line.isEmpty else { continue }
            if line.hasPrefix("{") {
                if let credit = jsonCredit(line) { scan.jsonCredits.append(credit) }
                continue
            }
            var stamps: [Double] = []
            var rest = Substring(line)
            var isTag = false
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let inside = rest[rest.index(after: rest.startIndex)..<close]
                if let time = timestamp(inside) {
                    stamps.append(time)
                    rest = rest[rest.index(after: close)...]
                } else {
                    if stamps.isEmpty, let (key, value) = tag(inside) {
                        scan.tags[key] = value
                        isTag = true
                    }
                    break
                }
            }
            if isTag { continue }
            guard !stamps.isEmpty else {
                if !line.hasPrefix("[") { scan.untimed.append(line) }
                continue
            }
            let body = String(rest)
            let inline = inlineWords(body)
            for stamp in stamps {
                var entry = Entry(time: stamp, text: inline.text, order: scan.entries.count)
                if stamps.count == 1, !inline.words.isEmpty {
                    entry.words = inline.words
                    entry.trailingWordEnd = inline.trailingEnd
                }
                scan.entries.append(entry)
            }
        }
        return scan
    }

    /// `mm:ss`, `mm:ss.x…`, `mm:ss:xx`, `h:mm:ss.xx`.
    static func timestamp<S: StringProtocol>(_ raw: S) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ":" || $0 == ".") }) else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        func fraction(_ digits: Substring) -> Double? {
            guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy(\.isNumber) else { return nil }
            return Double("0." + digits)
        }
        if parts.count == 2 {
            guard let minutes = Int(parts[0]), parts[0].count <= 4, let seconds = Double(parts[1]) else { return nil }
            return Double(minutes) * 60 + seconds
        }
        if !parts[2].contains("."), parts[2].count <= 3 {
            guard let minutes = Int(parts[0]), let seconds = Int(parts[1]), let fractional = fraction(parts[2]) else { return nil }
            return Double(minutes) * 60 + Double(seconds) + fractional
        }
        guard let hours = Int(parts[0]), let minutes = Int(parts[1]), let seconds = Double(parts[2]) else { return nil }
        return Double(hours) * 3600 + Double(minutes) * 60 + seconds
    }

    private static func tag(_ inside: Substring) -> (String, String)? {
        guard let colon = inside.firstIndex(of: ":") else { return nil }
        let key = inside[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.count <= 16, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "_" || $0 == "#") }) else { return nil }
        return (key.lowercased(), inside[inside.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// Enhanced LRC `<mm:ss.xx>` word stamps.
    private static func inlineWords(_ body: String) -> (text: String, words: [LyricWord], trailingEnd: Double?) {
        guard body.contains("<") else { return (body.trimmingCharacters(in: .whitespaces), [], nil) }
        var pieces: [(start: Double?, text: String)] = [(nil, "")]
        var index = body.startIndex
        var markers = 0
        while index < body.endIndex {
            if body[index] == "<", let close = body[index...].firstIndex(of: ">"),
               let time = timestamp(body[body.index(after: index)..<close]) {
                pieces.append((time, ""))
                markers += 1
                index = body.index(after: close)
                continue
            }
            pieces[pieces.count - 1].text.append(body[index])
            index = body.index(after: index)
        }
        guard markers > 0 else { return (body.trimmingCharacters(in: .whitespaces), [], nil) }
        var trailingEnd: Double?
        if let last = pieces.last, last.text.isEmpty, let start = last.start { trailingEnd = start }
        let prefix = pieces[0].text
        var words: [LyricWord] = []
        for piece in pieces.dropFirst() where !piece.text.isEmpty {
            if let start = piece.start { words.append(LyricWord(start: start, end: .nan, text: piece.text)) }
        }
        if !prefix.trimmingCharacters(in: .whitespaces).isEmpty {
            // Text before the first stamp starts with the line; its end is the first stamp.
            let firstStart = words.first?.start ?? trailingEnd ?? 0
            words.insert(LyricWord(start: .nan, end: firstStart, text: prefix), at: 0)
        }
        let (text, tidy) = tidyWords(words)
        return (text, tidy, trailingEnd)
    }

    /// Line text is exactly the joined words, without outer whitespace.
    private static func tidyWords(_ input: [LyricWord]) -> (String, [LyricWord]) {
        var words = input
        while let first = words.first {
            let trimmed = String(first.text.drop(while: { $0.isWhitespace }))
            if trimmed.isEmpty { words.removeFirst() } else { words[0].text = trimmed; break }
        }
        while let last = words.last {
            var text = last.text
            while text.last?.isWhitespace == true { text.removeLast() }
            if text.isEmpty { words.removeLast() } else { words[words.count - 1].text = text; break }
        }
        return (words.map(\.text).joined(), words)
    }

    static func jsonCredit(_ line: String) -> String? {
        struct Row: Decodable {
            struct Piece: Decodable { var tx: String? }
            var c: [Piece]?
        }
        guard let data = line.data(using: .utf8), let row = try? JSONDecoder().decode(Row.self, from: data) else { return nil }
        let text = (row.c ?? []).compactMap(\.tx).joined().trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func applyOffset(_ entries: inout [Entry], tags: [String: String]) {
        // [offset:+500] shows lyrics 0.5 s earlier.
        guard let raw = tags["offset"], let milliseconds = Double(raw.replacingOccurrences(of: "+", with: "")),
              milliseconds.isFinite, milliseconds != 0 else { return }
        let shift = milliseconds / 1000
        func moved(_ value: Double) -> Double { value.isNaN ? value : max(0, value - shift) }
        for index in entries.indices {
            entries[index].time = moved(entries[index].time)
            entries[index].end = entries[index].end.map(moved)
            entries[index].trailingWordEnd = entries[index].trailingWordEnd.map(moved)
            if let words = entries[index].words {
                entries[index].words = words.map { LyricWord(start: moved($0.start), end: moved($0.end), text: $0.text) }
            }
        }
    }

    // MARK: - Assembly

    private static func finish(_ input: [Entry], tags: [String: String], hint: LyricsTitleHint?, extraCredits: [String],
                               translations: [(time: Double, text: String)]) -> ParsedLyrics {
        var entries = input.filter { $0.time.isFinite }.sorted { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
        var credits: [String] = []
        for credit in extraCredits + extractCredits(&entries, hint: hint, tags: tags) where !credits.contains(credit) {
            credits.append(credit)
        }

        // Same timestamp: a repeat is dropped; a different text is a translation (bilingual LRC).
        var lines: [LyricLine] = []
        var trailingEnds: [Double?] = []
        for entry in entries {
            if let previous = lines.last, abs(previous.start - entry.time) < 0.001 {
                let text = entry.text
                if text.isEmpty || text == previous.text || text == previous.translation { continue }
                if previous.text.isEmpty {
                    lines[lines.count - 1].text = text
                    lines[lines.count - 1].words = entry.words
                    trailingEnds[trailingEnds.count - 1] = entry.trailingWordEnd
                    continue
                }
                if let existing = previous.translation, !existing.isEmpty {
                    lines[lines.count - 1].translation = existing + " / " + text
                } else {
                    lines[lines.count - 1].translation = text
                }
                continue
            }
            lines.append(LyricLine(start: entry.time, end: entry.end, text: entry.text, translation: entry.translation, words: entry.words))
            trailingEnds.append(entry.trailingWordEnd)
        }

        if !translations.isEmpty {
            var cursor = 0
            let sorted = translations.sorted { $0.time < $1.time }
            for index in lines.indices where !lines[index].text.isEmpty {
                let start = lines[index].start
                while cursor < sorted.count, sorted[cursor].time < start - 0.1 { cursor += 1 }
                var best: (distance: Double, text: String)?
                var probe = cursor
                while probe < sorted.count, sorted[probe].time <= start + 0.1 {
                    let distance = abs(sorted[probe].time - start)
                    if distance < (best?.distance ?? .infinity) { best = (distance, sorted[probe].text) }
                    probe += 1
                }
                if let best, best.text != lines[index].text { lines[index].translation = best.text }
            }
        }

        // Collapse runs of gaps.
        var compact: [LyricLine] = []
        var compactTrailing: [Double?] = []
        for (line, trailing) in zip(lines, trailingEnds) {
            if line.text.isEmpty, let last = compact.last, last.text.isEmpty { continue }
            compact.append(line)
            compactTrailing.append(trailing)
        }
        lines = compact

        for index in lines.indices {
            let next = index + 1 < lines.count ? lines[index + 1].start : nil
            if var words = lines[index].words, !words.isEmpty {
                for w in words.indices {
                    if words[w].start.isNaN { words[w].start = lines[index].start }
                    if words[w].end.isNaN {
                        if w + 1 < words.count {
                            words[w].end = words[w + 1].start
                        } else if let trailing = compactTrailing[index] {
                            words[w].end = trailing
                        } else if let next {
                            words[w].end = next
                        } else {
                            words[w].end = words[w].start + 1
                        }
                    }
                    if words[w].end < words[w].start { words[w].end = words[w].start }
                }
                lines[index].words = words
                if lines[index].end == nil { lines[index].end = words.last?.end }
            }
            if lines[index].end == nil { lines[index].end = next }
        }

        let texts = lines.map(\.text).filter { !$0.isEmpty }
        if !texts.isEmpty, texts.allSatisfy(isInstrumentalMarker) {
            return ParsedLyrics(lines: [], credits: credits, plainText: nil, instrumental: true, tags: tags)
        }
        if texts.isEmpty || texts.allSatisfy(isPlaceholder) {
            return ParsedLyrics(lines: [], credits: credits, plainText: nil, instrumental: false, tags: tags)
        }
        return ParsedLyrics(lines: lines, credits: credits, plainText: texts.joined(separator: "\n"), instrumental: false, tags: tags)
    }

    // MARK: - Credits

    /// Moves leading credits / the 「歌名 - 歌手」 header and trailing credits / disclaimers out of the lyric.
    static func extractCredits(_ entries: inout [Entry], hint: LyricsTitleHint?, tags: [String: String]) -> [String] {
        var leading: [String] = []
        var removed = Set<Int>()
        var seen = 0
        for index in entries.indices {
            let text = entries[index].text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            guard seen < 40 else { break }
            if isCreditLine(text, strict: false) || (seen < 3 && isTitleLine(text, hint: hint, tags: tags)) {
                leading.append(text)
                removed.insert(index)
                seen += 1
                continue
            }
            break
        }
        var trailing: [String] = []
        var checked = 0
        for index in entries.indices.reversed() where !removed.contains(index) {
            let text = entries[index].text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            guard checked < 15 else { break }
            checked += 1
            if isCreditLine(text, strict: true) || isDisclaimer(text) {
                trailing.insert(text, at: 0)
                removed.insert(index)
                continue
            }
            break
        }
        guard !removed.isEmpty else { return [] }
        entries = entries.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        return leading + trailing
    }

    private static let creditKeywords: [String] = {
        let words = ["作词", "作曲", "编曲", "制作人", "制作", "监制", "出品", "发行", "混音", "缩混", "混缩", "录音", "母带", "和声", "合声", "和音",
                     "伴唱", "配唱", "吉他", "贝斯", "鼓", "键盘", "钢琴", "弦乐", "提琴", "管乐", "打击乐", "编程", "总监", "统筹", "企划", "策划",
                     "营销", "推广", "宣传", "版权", "原唱", "翻唱", "演唱", "歌手", "主唱", "填词", "谱曲", "改编", "编写", "编排", "工程", "助理",
                     "人声", "设计", "美术", "封面", "视觉", "摄影", "指导", "鸣谢", "感谢", "乐队", "乐手", "合成器", "采样", "口琴", "二胡", "琵琶",
                     "古筝", "笛", "唢呐", "手风琴", "萨克斯", "小号", "长号", "圆号", "竖琴", "管弦", "乐团", "指挥", "音效", "后期", "出版",
                     "词曲", "编配", "配器", "工作室", "厂牌", "经纪", "艺人", "出品人", "联合", "合作", "文案", "海报", "视频", "导演", "剪辑",
                     "声乐", "首席", "修音", "编辑", "演奏", "原曲", "词", "曲", "歌", "op", "sp", "isrc", "lrc", "lyrics", "lyricist", "lyric",
                     "words", "composer", "composed", "composition", "music", "arranger", "arranged", "arrangement", "producer", "produced",
                     "production", "co-producer", "executive", "mixing", "mixed", "mix", "mastering", "mastered", "master", "recording",
                     "recorded", "engineer", "engineered", "vocal", "vocals", "backing", "chorus", "guitar", "guitars", "bass", "drums", "drum",
                     "keyboard", "keyboards", "keys", "piano", "strings", "string", "programming", "programmed", "written", "writer", "writers",
                     "songwriter", "publisher", "published", "label", "a&r", "artwork", "director", "studio", "assistant", "editing", "edited",
                     "synth", "synthesizer", "percussion", "violin", "cello", "horn", "horns", "sax", "trumpet", "orchestra", "conductor", "by"]
        return words.sorted { $0.count > $1.count }
    }()
    private static let shortCreditKeywords: Set<String> = ["词", "曲", "歌", "op", "sp", "鼓", "笛", "by"]

    private static let creditBy = LyricsPattern(#"^(?:lyrics|music|words|composed|written|arranged|produced|mixed|mastered|recorded)(?:\s+and\s+\w+)?\s+by\s+\S"#)
    private static let disclaimer = LyricsPattern(#"未经.{0,20}许可|不得.{0,12}(?:翻唱|使用|翻录|商用)|版权所有|all\s+rights\s+reserved|^©|^℗|本歌曲来自|歌词贡献|歌词制作|lrc\s*(?:by|制作|编辑)|未经授权"#)

    static func isCreditLine(_ text: String, strict: Bool) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 160 else { return false }
        let folded = SongText.fold(trimmed)
        if creditBy.matches(folded) { return true }
        guard let colon = folded.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let label = folded[..<colon].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count <= 18,
              !label.contains(where: { "，。！？!?\"“”".contains($0) }) else { return false }
        let compact = label.filter { !$0.isWhitespace && !"/&、·-_|及和与()（）".contains($0) }
        guard !compact.isEmpty else { return false }
        if shortCreditKeywords.contains(compact) { return true }
        if strict {
            var rest = Substring(compact)
            while !rest.isEmpty {
                guard let keyword = creditKeywords.first(where: { rest.hasPrefix($0) }) else { return false }
                rest = rest.dropFirst(keyword.count)
            }
            return true
        }
        return creditKeywords.contains { $0.count >= 2 && compact.contains($0) }
    }

    static func isDisclaimer(_ text: String) -> Bool { disclaimer.matches(SongText.fold(text)) }

    /// 「晴天 - 周杰伦 (Jay Chou)」 / 「周杰伦-晴天」 near the top of a body.
    static func isTitleLine(_ text: String, hint: LyricsTitleHint?, tags: [String: String]) -> Bool {
        guard text.contains(where: { "-－—–~～".contains($0) }) else { return false }
        let key = SongText.normalized(text)
        guard !key.isEmpty else { return false }
        var titles: [String] = []
        if let hint { titles.append(hint.title) }
        if let title = tags["ti"], !title.isEmpty { titles.append(title) }
        let titleKeys = titles.flatMap { SongText.titleNames($0) }
        guard titleKeys.contains(where: { key.contains($0) }) else { return false }
        var artists: [String] = []
        if let hint { artists.append(hint.artist) }
        if let artist = tags["ar"], !artist.isEmpty { artists.append(artist) }
        let artistKeys = artists.flatMap { SongText.artists($0).map(SongText.normalized) }.filter { !$0.isEmpty }
        return artistKeys.contains { key.contains($0) }
    }

    // MARK: - Content markers

    private static let instrumentalMarker = LyricsPattern(#"^[\s\p{P}]*(?:此歌曲为没有填词的纯音乐|纯音乐|instrumental|inst\.?|轻音乐)[\s\p{P}]*(?:请欣赏|请您欣赏|敬请欣赏|请您欣赏)?[\s\p{P}]*$"#)
    private static let placeholder = LyricsPattern(#"暂无歌词|暂时没有歌词|歌词正在制作|该歌曲暂无|此歌曲暂无|没有歌词|无歌词|未找到歌词|暂未上传|歌词加载失败|no\s+lyrics|lyrics\s+not\s+(?:available|found)|^[\s\p{P}]*暂无[\s\p{P}]*$"#)

    static func isInstrumentalMarker(_ text: String) -> Bool {
        let folded = SongText.fold(text)
        return folded.count <= 40 && instrumentalMarker.matches(folded)
    }

    static func isPlaceholder(_ text: String) -> Bool {
        let folded = SongText.fold(text)
        return folded.count <= 40 && placeholder.matches(folded)
    }

    private static func isUsableTranslation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.contains { $0.isLetter || $0.isNumber }
    }
}
