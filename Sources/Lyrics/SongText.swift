import Foundation

/// A compiled pattern. NSRegularExpression is immutable and documented thread-safe.
final class LyricsPattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = true) {
        // Patterns are compile-time constants; an invalid one is a programming error caught by the tests.
        regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    func matches(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    func firstRange(in text: String) -> Range<String.Index>? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return Range(match.range, in: text)
    }

    func replacing(in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

enum SongText {
    // MARK: - Public surface

    /// Traditional→Simplified, case/width/diacritic folded, letters and digits only.
    static func normalized(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        var scalars = String.UnicodeScalarView()
        for scalar in fold(s).unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// The title without version tags, bracketed descriptors or feat. credits.
    static func baseTitle(_ title: String) -> String { titleParts(title).base }

    /// Version descriptors found in the title's brackets/dash suffix and (for a safe subset) the album:
    /// "live", "remix", "dj", "tempo", "acoustic", "piano", "instrumental", "cover", "demo", "medley",
    /// "remaster", "edit", "short", "variant", "cantonese", "mandarin", "english", "japanese", "korean", "chinese".
    static func versionTags(_ title: String, album: String?) -> Set<String> {
        let parts = titleParts(title)
        var tags = Set<String>()
        for descriptor in parts.descriptors { tags.formUnion(descriptorTags(descriptor)) }
        if parts.isMedley { tags.insert("medley") }
        if let album = album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            tags.formUnion(descriptorTags(album, forAlbum: true))
        }
        return tags
    }

    /// Splits credits on / & , 、 ; feat. ft. x 和 …; a bracketed alias such as 「周杰伦 (Jay Chou)」 yields both names.
    static func artists(_ s: String) -> [String] {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        func add(_ value: String) {
            let trimmed = value.trimmingCharacters(in: artistTrim)
            if !trimmed.isEmpty, !result.contains(trimmed) { result.append(trimmed) }
        }
        let separated = Patterns.artistWords.replacing(in: text, with: "/")
        for part in separated.split(whereSeparator: { artistSeparators.contains($0) }) {
            let (outside, segments) = splitBrackets(String(part))
            for piece in splitConjunction(collapse(outside)) { add(piece) }
            for segment in segments {
                let cleaned = Patterns.featHead.replacing(in: segment, with: "")
                for piece in cleaned.split(whereSeparator: { artistSeparators.contains($0) }) {
                    for name in splitConjunction(collapse(String(piece))) { add(name) }
                }
            }
        }
        if result.isEmpty { add(text) }
        return result
    }

    // MARK: - Folding helpers

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Simplified, lower-cased, width- and diacritic-folded; punctuation and spacing are kept.
    static func fold(_ s: String) -> String {
        simplified(s).folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: posix)
    }

    static func simplified(_ s: String) -> String {
        guard containsHan(s) else { return s }
        return s.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? s
    }

    static func containsHan(_ s: String) -> Bool { s.unicodeScalars.contains(where: isHan) }

    static func containsCJK(_ s: String) -> Bool { s.unicodeScalars.contains(where: isCJK) }

    static func isHan(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }

    static func isCJK(_ u: Unicode.Scalar) -> Bool {
        if isHan(u) { return true }
        switch u.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: return true
        default: return false
        }
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Titles

    struct TitleParts: Sendable, Equatable {
        var base: String
        var aliases: [String]
        var descriptors: [String]
        var isMedley: Bool
    }

    static let openers: Set<Character> = ["(", "（", "[", "【", "〔", "［", "{", "｛", "〖", "﹙"]
    static let closers: Set<Character> = [")", "）", "]", "】", "〕", "］", "}", "｝", "〗", "﹚"]
    private static let spacedDashes = [" - ", " – ", " — ", " ~ ", "－", "～", " -", "- "]
    private static let anyDashes = [" - ", " – ", " — ", "－", "—", "–", "-"]

    /// Top-level bracket segments are removed from the outside text; mismatched pairs are tolerated.
    static func splitBrackets(_ text: String) -> (outside: String, segments: [String]) {
        var outside = ""
        var segments: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if openers.contains(character) {
                if depth > 0 { current.append(character) } else { current = "" }
                depth += 1
            } else if closers.contains(character) {
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0 {
                    segments.append(current)
                    outside.append(" ")
                } else {
                    current.append(character)
                }
            } else if depth > 0 {
                current.append(character)
            } else {
                outside.append(character)
            }
        }
        if depth > 0 { segments.append(current) }
        return (outside, segments)
    }

    static func titleParts(_ title: String) -> TitleParts {
        let trimmed = collapse(title)
        let split = splitBrackets(trimmed)
        let outside = collapse(split.outside)
        var aliases: [String] = []
        var descriptors: [String] = []
        for raw in split.segments {
            let segment = collapse(raw)
            guard !segment.isEmpty else { continue }
            if isDescriptor(segment) {
                descriptors.append(segment)
            } else if scriptsDiffer(outside, segment) {
                aliases.append(segment)
            } else {
                descriptors.append(segment)
            }
        }
        var base = outside
        func cutTail(_ pattern: LyricsPattern) {
            guard let range = pattern.firstRange(in: base), range.lowerBound > base.startIndex else { return }
            descriptors.append(collapse(String(base[range])))
            base = collapse(String(base[..<range.lowerBound]))
        }
        cutTail(Patterns.featTail)
        cutTail(Patterns.coverTail)
        while let range = lastRange(of: spacedDashes, in: base) {
            let prefix = collapse(String(base[..<range.lowerBound]))
            let suffix = collapse(String(base[range.upperBound...]))
            guard !prefix.isEmpty, !suffix.isEmpty else { break }
            if isDescriptor(suffix) {
                descriptors.append(suffix)
                base = prefix
                continue
            }
            if prefix.count <= 3, prefix.allSatisfy(\.isNumber) {
                base = suffix
                continue
            }
            if scriptsDiffer(prefix, suffix) {
                // Bilingual name: 「最長的電影 - The Longest Movie」.
                aliases.append(suffix)
                base = prefix
            }
            break
        }
        cutTail(Patterns.versionTail)
        cutTail(Patterns.versionTailTight)
        if let range = Patterns.trackNumber.firstRange(in: base), range.upperBound < base.endIndex {
            base = collapse(String(base[range.upperBound...]))
        }
        if base.isEmpty {
            base = collapse(String(trimmed.filter { !openers.contains($0) && !closers.contains($0) }))
        }
        return TitleParts(base: base, aliases: aliases, descriptors: descriptors, isMedley: isMedleyBase(base))
    }

    /// Normalized base title plus bilingual aliases (「最长的电影 (The Longest Movie)」 → both names).
    static func titleNames(_ title: String, extra: [String] = []) -> Set<String> {
        let parts = titleParts(title)
        var names = Set<String>()
        for name in [parts.base] + parts.aliases + extra {
            let key = normalized(name)
            if !key.isEmpty { names.insert(key) }
        }
        if names.isEmpty {
            let key = normalized(title)
            if !key.isEmpty { names.insert(key) }
        }
        return names
    }

    /// Strips 「歌手 - 」 prefixes, 「 - 歌手」 suffixes and track numbers that some catalogs put into titles.
    static func cleanedCandidateTitle(_ title: String, artist: String) -> String {
        var text = collapse(title)
        let keys = Set(artistKeys(artist).map(\.key))
        if !keys.isEmpty {
            if let range = firstRange(of: anyDashes, in: text) {
                let prefix = String(text[..<range.lowerBound]), suffix = collapse(String(text[range.upperBound...]))
                if keys.contains(normalized(prefix)), !suffix.isEmpty { text = suffix }
            }
            if let range = lastRange(of: anyDashes, in: text) {
                let prefix = collapse(String(text[..<range.lowerBound])), suffix = String(text[range.upperBound...])
                if keys.contains(normalized(suffix)), !prefix.isEmpty { text = prefix }
            }
        }
        if let range = Patterns.trackNumber.firstRange(in: text), range.upperBound < text.endIndex {
            text = collapse(String(text[range.upperBound...]))
        }
        return text
    }

    static func isDescriptor(_ text: String) -> Bool {
        if !descriptorTags(text).isEmpty { return true }
        return Patterns.descriptor.matches(fold(text))
    }

    private static func isMedleyBase(_ base: String) -> Bool {
        let parts = base.split(whereSeparator: { $0 == "+" || $0 == "＋" }).map { collapse(String($0)) }
        return parts.count >= 2 && parts.allSatisfy { $0.count >= 2 }
    }

    private enum Script { case latin, cjk }

    private static func dominantScript(_ s: String) -> Script? {
        var latin = 0, cjk = 0
        for scalar in s.unicodeScalars {
            if isCJK(scalar) { cjk += 1 } else if scalar.properties.isAlphabetic, scalar.value < 0x0250 { latin += 1 }
        }
        if latin == 0 && cjk == 0 { return nil }
        return cjk >= latin ? .cjk : .latin
    }

    private static func scriptsDiffer(_ a: String, _ b: String) -> Bool {
        guard let first = dominantScript(a), let second = dominantScript(b) else { return false }
        return first != second
    }

    private static func firstRange(of separators: [String], in text: String) -> Range<String.Index>? {
        separators.compactMap { text.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
    }

    private static func lastRange(of separators: [String], in text: String) -> Range<String.Index>? {
        separators.compactMap { text.range(of: $0, options: .backwards) }.max { $0.lowerBound < $1.lowerBound }
    }

    // MARK: - Version tags and classes

    static let neutralTags: Set<String> = ["remaster", "edit", "short"]
    static let languageTags = ["cantonese", "mandarin", "english", "japanese", "korean", "chinese"]
    private static let albumTags: Set<String> = ["live", "instrumental", "cover", "remix", "dj", "acoustic", "demo"]

    /// Tags found in one descriptor (a bracketed segment, dash suffix, album name …).
    static func descriptorTags(_ raw: String, forAlbum: Bool = false) -> Set<String> {
        var text = fold(raw)
        guard !text.isEmpty else { return [] }
        text = Patterns.neutralVersion.replacing(in: text, with: " ")
        var tags = Set<String>()
        for rule in Patterns.tagRules where !forAlbum || albumTags.contains(rule.tag) {
            if forAlbum && rule.weak { continue }
            if rule.pattern.matches(text) { tags.insert(rule.tag) }
        }
        if !forAlbum, tags.subtracting(neutralTags).isEmpty, Patterns.variant.matches(text) { tags.insert("variant") }
        return tags
    }

    /// Recordings in the same class share a timeline closely enough for synced display.
    static func versionClass(_ tags: Set<String>) -> String {
        if tags.contains("instrumental") { return "instrumental" }
        if tags.contains("medley") { return "medley" }
        if tags.contains("cover") { return "cover" }
        if tags.contains("live") { return "live" }
        if !tags.isDisjoint(with: ["remix", "dj", "tempo"]) { return "remix" }
        if !tags.isDisjoint(with: ["acoustic", "piano"]) { return "acoustic" }
        if tags.contains("demo") { return "demo" }
        for language in languageTags where tags.contains(language) { return "lang:" + language }
        if tags.contains("variant") { return "variant" }
        return "studio"
    }

    static func versionClassLabel(_ versionClass: String) -> String {
        switch versionClass {
        case "live": return "现场版"
        case "remix": return "Remix/DJ 版"
        case "acoustic": return "原声/钢琴版"
        case "cover": return "翻唱版"
        case "demo": return "Demo 版"
        case "variant": return "其他版本"
        case "studio": return "录音室版"
        case "instrumental": return "伴奏"
        case "medley": return "串烧"
        default: return versionClass.hasPrefix("lang:") ? "其他语言版本" : "其他版本"
        }
    }

    // MARK: - Artists

    struct ArtistKey: Sendable, Hashable {
        var key: String
        var tokens: [String]
        var cjk: Bool
    }

    enum ArtistMatch: Int, Comparable, Sendable {
        case none, contains, equal
        static func < (lhs: ArtistMatch, rhs: ArtistMatch) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private static let artistSeparators: Set<Character> = ["/", "／", "&", "＆", ",", "，", "、", ";", "；", "|", "｜", "+", "＋"]
    private static let artistTrim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—~～"))
    /// Placeholder credits that say nothing about who sings.
    static let genericArtists: Set<String> = ["群星", "华语群星", "日韩群星", "欧美群星", "港台群星", "内地群星", "韩国群星", "日本群星",
                                              "variousartists", "various", "va", "未知", "未知歌手", "未知艺人", "unknown",
                                              "unknownartist", "佚名", "无名氏", "群星合唱"]

    private static func splitConjunction(_ s: String) -> [String] {
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace }),
              s.contains(where: { $0 == "和" || $0 == "与" || $0 == "與" }),
              s.unicodeScalars.allSatisfy(isCJK) else { return [s] }
        let parts = s.split(whereSeparator: { $0 == "和" || $0 == "与" || $0 == "與" }).map(String.init)
        return parts.count >= 2 && parts.allSatisfy({ $0.count >= 2 }) ? parts : [s]
    }

    /// Words split on punctuation and at Latin/CJK boundaries, folded.
    static func tokens(_ s: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        var currentCJK: Bool?
        for scalar in fold(s).unicodeScalars {
            guard CharacterSet.alphanumerics.contains(scalar) else {
                if !current.isEmpty { result.append(String(current)); current = String.UnicodeScalarView() }
                currentCJK = nil
                continue
            }
            let cjk = isCJK(scalar)
            if let previous = currentCJK, previous != cjk, !current.isEmpty {
                result.append(String(current))
                current = String.UnicodeScalarView()
            }
            current.append(scalar)
            currentCJK = cjk
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }

    static func artistKeys(_ s: String) -> [ArtistKey] {
        var keys: [ArtistKey] = []
        var seen = Set<String>()
        for name in artists(s) + [s] {
            let key = normalized(name)
            guard !key.isEmpty, !genericArtists.contains(key), seen.insert(key).inserted else { continue }
            keys.append(ArtistKey(key: key, tokens: tokens(name), cjk: containsCJK(key)))
        }
        return keys
    }

    static func artistKeys(_ names: [String]) -> [ArtistKey] {
        var keys: [ArtistKey] = []
        var seen = Set<String>()
        for name in names {
            for key in artistKeys(name) where seen.insert(key.key).inserted { keys.append(key) }
        }
        if names.count > 1 {
            for key in artistKeys(names.joined(separator: "/")) where seen.insert(key.key).inserted { keys.append(key) }
        }
        return keys
    }

    /// Equal when any normalized name is identical; contains for 「G.E.M.邓紫棋」 vs 「邓紫棋」 or 「Jay」 vs 「Jay Chou」.
    static func artistMatch(_ a: [ArtistKey], _ b: [ArtistKey]) -> ArtistMatch {
        var best = ArtistMatch.none
        for x in a {
            for y in b {
                if x.key == y.key { return .equal }
                let (short, long) = x.key.count <= y.key.count ? (x, y) : (y, x)
                guard short.key.count >= 2 else { continue }
                if short.cjk, long.key.contains(short.key) { best = .contains; continue }
                if !short.tokens.isEmpty, short.tokens.count < long.tokens.count,
                   containsRun(long.tokens, short.tokens), short.key.count >= 3 || short.cjk {
                    best = .contains
                }
            }
        }
        return best
    }

    /// One credit written in CJK and the other only in Latin letters (a romanized or translated name).
    static func scriptsDifferForArtists(_ a: String, _ b: String) -> Bool {
        let first = normalized(a), second = normalized(b)
        guard !first.isEmpty, !second.isEmpty, !genericArtists.contains(first), !genericArtists.contains(second) else { return false }
        return containsCJK(first) != containsCJK(second)
    }

    private static func containsRun(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }

    // MARK: - Similarity

    /// 1 for identical normalized strings; containment of a ≥ 4 character name counts as 0.85.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let first = Array(a), second = Array(b)
        var score = 1 - Double(levenshtein(first, second)) / Double(max(first.count, second.count))
        let (short, long) = first.count <= second.count ? (a, b) : (b, a)
        if short.count >= 4, long.contains(short) { score = max(score, 0.85) }
        return score
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: - Patterns

    struct TagRule: Sendable {
        var tag: String
        var pattern: LyricsPattern
        /// Weak rules are too ambiguous for album names (e.g. 「Beat It」).
        var weak: Bool = false
    }

    enum Patterns {
        static let artistWords = LyricsPattern(#"\s+(?:feat\.?|ft\.?|featuring|vs\.?|x|×)\s+"#)
        static let featHead = LyricsPattern(#"^\s*(?:feat\.?|ft\.?|featuring|with)\s+"#)
        static let featTail = LyricsPattern(#"\s+(?:feat\.?|ft\.|featuring)\s+.+$"#)
        static let coverTail = LyricsPattern(#"\s*(?:cover|翻唱|翻自|cos)\s*[:：].*$"#)
        static let versionTail = LyricsPattern(#"\s+(?:\S{1,10}版|remix|remastered(?:\s+\d{4})?|\d{4}\s+remaster(?:ed)?|instrumental|karaoke|acoustic(?:\s+version)?|live\s+version|sped\s+up|slowed(?:\s*(?:\+|&|and)?\s*reverb(?:ed)?)?|nightcore|radio\s+edit|extended\s+mix|original\s+mix)$"#)
        static let versionTailTight = LyricsPattern(#"(?:现场版|伴奏版|伴奏|dj版|live版|纯音乐版|女声版|男声版|钢琴版|吉他版|翻唱版)$"#)
        static let trackNumber = LyricsPattern(#"^\s*\d{1,3}\s*[.．、]\s*(?=\D)"#)
        static let neutralVersion = LyricsPattern(#"single\s*version|album\s*version|original\s*version|radio\s*version|full\s*version|studio\s*version|main\s*version|original\s*mix|(?<![a-z])original(?![a-z])|原版|原唱版|完整版|正式版|录音室版|单曲版|专辑版|官方版"#)
        static let variant = LyricsPattern(#"版|(?<![a-z])ver(?:sion)?\.?(?![a-z])"#)
        static let descriptor = LyricsPattern(#"feat|(?<![a-z])ft\.?(?![a-z])|featuring|(?<![a-z])prod|(?<![a-z])from(?![a-z])|theme|(?<![a-z])ost(?![a-z])|soundtrack|主题|插曲|片头|片尾|电影|电视剧|剧集|动画|动漫|游戏|广告|宣传曲|推广曲|应援曲|《|》|原唱|翻自|翻唱|version|(?<![a-z])ver\.?(?![a-z])|edit|remaster|版|bonus|explicit|(?<![a-z])clean(?![a-z])|(?<![a-z])mono(?![a-z])|stereo|单曲|(?<![a-z])single(?![a-z])|原声|配乐|纪念|周年|anniversary|(?<![a-z])mv(?![a-z])|(?<![a-z])tv(?![a-z])|节目|抖音|快手|热歌|合唱|独唱|对唱|(?<![a-z])with(?![a-z])|和声|伴唱"#)
        static let tagRules: [TagRule] = [
            TagRule(tag: "instrumental", pattern: LyricsPattern(#"instrumental|伴奏|karaoke|卡拉ok|(?<![a-z])ktv(?![a-z])|off\s*vocal|纯音乐|轻音乐|backing\s*track|消音|无人声|music\s*box|八音盒"#)),
            TagRule(tag: "instrumental", pattern: LyricsPattern(#"(?<![a-z])inst\.?(?![a-z])|(?<![a-z])beats?(?![a-z])|(?<![a-z])bgm(?![a-z])"#), weak: true),
            TagRule(tag: "medley", pattern: LyricsPattern(#"medley|mash\s*-?\s*up|串烧|联唱|组曲|串联"#)),
            TagRule(tag: "cover", pattern: LyricsPattern(#"cover|翻唱|翻自|原唱(?!版)|(?<![a-z])cos(?![a-z])|网友|改编|女声|男声|女生版|男生版|童声|女版|男版|originally\s+performed|in\s+the\s+style\s+of|made\s+famous\s+by|tribute|致敬"#)),
            TagRule(tag: "live", pattern: LyricsPattern(#"(?<![a-z])live(?![a-z])|现场|演唱会|音乐会|巡演|巡回|concert|(?<![a-z])tour(?![a-z])|音乐节|第\s*\d+\s*期|unplugged"#)),
            TagRule(tag: "remix", pattern: LyricsPattern(#"remix|re-mix|(?<![a-z])mix(?![a-z])|混音|重混|bootleg|rework|电音|(?<![a-z])edm(?![a-z])|抖音"#)),
            TagRule(tag: "dj", pattern: LyricsPattern(#"(?<![a-z])dj"#)),
            TagRule(tag: "tempo", pattern: LyricsPattern(#"(?<![\d.])[0-2](?:\.\d{1,2})?\s*[x×](?![a-z])|倍速|加速|减速|慢速|降速|升调|降调|变调|sped\s*up|speed\s*up|slowed|nightcore|reverb"#)),
            TagRule(tag: "acoustic", pattern: LyricsPattern(#"acoustic|unplugged|不插电|弹唱|清唱|a\s*cappella|acapella|吉他|guitar"#)),
            TagRule(tag: "piano", pattern: LyricsPattern(#"piano|钢琴"#)),
            TagRule(tag: "demo", pattern: LyricsPattern(#"(?<![a-z])demo(?![a-z])|小样|试听版|未发行"#)),
            TagRule(tag: "remaster", pattern: LyricsPattern(#"remaster|重制|修复|hi\s*-?\s*res|无损|24\s*bit|(?<![a-z])dsd(?![a-z])|(?<![a-z])flac(?![a-z])"#)),
            TagRule(tag: "short", pattern: LyricsPattern(#"片段|铃声|剪辑|短版|tv\s*size|tv\s*ver|short\s*ver|cut\s*ver|preview"#)),
            TagRule(tag: "edit", pattern: LyricsPattern(#"radio\s*edit|(?<![a-z])edit(?![a-z])|(?<![a-z])clean(?![a-z])|explicit"#)),
            TagRule(tag: "cantonese", pattern: LyricsPattern(#"粤语"#)),
            TagRule(tag: "mandarin", pattern: LyricsPattern(#"国语版|普通话版|华语版"#)),
            TagRule(tag: "english", pattern: LyricsPattern(#"英文版|英语版|english\s*ver"#)),
            TagRule(tag: "japanese", pattern: LyricsPattern(#"日文版|日语版|japanese\s*ver"#)),
            TagRule(tag: "korean", pattern: LyricsPattern(#"韩文版|韩语版|korean\s*ver"#)),
            TagRule(tag: "chinese", pattern: LyricsPattern(#"中文版|chinese\s*ver"#)),
        ]
    }
}
