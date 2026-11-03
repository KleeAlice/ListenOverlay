import Foundation

/// The query, pre-normalized once per lookup.
struct LyricsMatchContext: Sendable {
    var query: SongQuery
    var full: String
    var names: Set<String>
    var tags: Set<String>
    var versionClass: String
    var artistKeys: [SongText.ArtistKey]
    var duration: Double?
    var albumKey: String?

    init(_ query: SongQuery) {
        self.query = query
        full = SongText.normalized(query.title)
        names = SongText.titleNames(query.title)
        tags = SongText.versionTags(query.title, album: query.album)
        versionClass = SongText.versionClass(tags)
        artistKeys = SongText.artistKeys(query.artist)
        if let duration = query.duration, duration.isFinite, duration > 0, duration < 86_400 { self.duration = duration } else { duration = nil }
        let album = query.album.map(SongText.normalized) ?? ""
        albumKey = album.isEmpty ? nil : album
    }
}

/// A plausible candidate with its metadata score kept apart from content bonuses.
struct LyricsEvaluatedHit: Sendable {
    var candidate: LyricsCandidate
    var metaScore: Double
    var syncedHint: Double
    var wordHint: Double
    /// Near-identical rows of one source collapse onto this key in the picker.
    var dedupeKey: String
}

enum LyricsMatcher {
    static let identityNote = "当前播放的同一首歌"

    static func reliability(_ source: LyricsSource) -> Double {
        switch source {
        case .netEase, .qqMusic, .kugou: return 0.03
        case .lrclib: return 0.015
        }
    }

    static func contentBonus(synced: Double, words: Double, translation: Double) -> Double {
        0.08 * synced + 0.04 * words + 0.02 * translation
    }

    /// The player's own NetEase song: exact by identity, whatever the metadata says.
    static func identity(for query: SongQuery, id: Int64) -> LyricsEvaluatedHit {
        let candidate = LyricsCandidate(id: "\(LyricsSource.netEase.rawValue):\(id)", source: .netEase, remoteID: String(id),
                                        title: query.title, artist: query.artist, album: query.album, duration: query.duration,
                                        tier: .exact, score: 1 + contentBonus(synced: 1, words: 0, translation: 0),
                                        note: identityNote, extra: [:])
        return LyricsEvaluatedHit(candidate: candidate, metaScore: 1, syncedHint: 1, wordHint: 0, dedupeKey: "identity:\(id)")
    }

    /// nil = 「明显不相符」.
    static func evaluate(_ hit: LyricsSearchHit, context q: LyricsMatchContext) -> LyricsEvaluatedHit? {
        if hit.source == .netEase, let id = q.query.netEaseID, hit.remoteID == String(id) {
            var identity = identity(for: q.query, id: id)
            identity.candidate.title = hit.title
            identity.candidate.artist = hit.artistDisplay
            identity.candidate.album = hit.album ?? q.query.album
            identity.candidate.duration = hit.duration ?? q.query.duration
            return identity
        }
        var artists = hit.artists
        var title = SongText.cleanedCandidateTitle(hit.title, artist: artists.joined(separator: "/"))
        var names = SongText.titleNames(title, extra: hit.aliases)
        var titleEqual = !q.names.isDisjoint(with: names)
        var swapped = false
        if !titleEqual, artists.count == 1 {
            // Some catalog rows have the title and the artist swapped.
            let swappedNames = SongText.titleNames(artists[0])
            if !q.names.isDisjoint(with: swappedNames),
               SongText.artistMatch(q.artistKeys, SongText.artistKeys(title)) != .none {
                swapped = true
                (title, artists) = (artists[0], [title])
                names = swappedNames
                titleEqual = true
            }
        }
        let titleSimilarity = titleEqual ? 1 : bestSimilarity(q.names, names)
        guard titleSimilarity >= 0.85 else { return nil }

        var tags = SongText.versionTags(title, album: hit.album)
        for descriptor in hit.descriptors { tags.formUnion(SongText.descriptorTags(descriptor)) }
        let versionClass = SongText.versionClass(tags)
        if versionClass == "instrumental" && q.versionClass != "instrumental" { return nil }
        if versionClass == "medley" && q.versionClass != "medley" { return nil }

        var delta: Double?
        var ratio: Double?
        if let expected = q.duration, let actual = hit.duration, actual.isFinite, actual > 0 {
            let r = actual / expected
            guard (0.6...1.6).contains(r) else { return nil }
            ratio = r
            delta = abs(actual - expected)
        }

        let artistKeys = SongText.artistKeys(artists)
        let artistMatch = SongText.artistMatch(q.artistKeys, artistKeys)
        let overlap = artistMatch != .none
        let full = SongText.normalized(title)
        let fullEqual = !full.isEmpty && full == q.full

        // An untagged row whose duration equals a tagged recording (or vice versa) is most likely that recording:
        // Kugou and LRCLIB often drop 「(Live)」 from titles.
        let bridgeable: Set<String> = ["live", "remix", "acoustic", "variant", "demo"]
        var sameClass = q.versionClass == versionClass
        var bridged = false
        if !sameClass, overlap, let delta, delta <= 2,
           (q.versionClass == "studio" && bridgeable.contains(versionClass)) || (versionClass == "studio" && bridgeable.contains(q.versionClass)) {
            sameClass = true
            bridged = true
        }
        // 「Jay Chou」 vs 「周杰伦」: a romanized or translated credit, not a different singer of the same script.
        let aliasCredit = !overlap && SongText.scriptsDifferForArtists(q.query.artist, artists.joined(separator: "/"))

        let seconds = delta.map { Int($0.rounded()) } ?? 0
        let tier: MatchTier
        var note: String
        if fullEqual, overlap, !bridged, q.tags.subtracting(SongText.neutralTags) == tags.subtracting(SongText.neutralTags),
           let delta, delta <= 2 {
            tier = .exact
            note = "标题、歌手、时长一致"
        } else if titleEqual, overlap, sameClass, delta.map({ $0 <= 5 }) ?? true {
            tier = .strong
            if bridged {
                let tagged = q.versionClass == "studio" ? versionClass : q.versionClass
                note = "\(SongText.versionClassLabel(tagged)) · 时长一致"
            } else if let delta, delta > 2 {
                note = "标题、歌手一致 · 时长相差 \(seconds) 秒"
            } else {
                note = "标题、歌手一致"
            }
        } else if titleEqual, overlap, !sameClass || (delta ?? 0) <= 25 {
            tier = .version
            note = versionNote(query: q.versionClass, candidate: versionClass, seconds: seconds)
        } else if titleEqual, aliasCredit, sameClass, let delta, delta <= 2 {
            tier = .version
            note = "歌手名不同（可能是译名或别名），时长一致"
        } else if overlap {
            tier = .loose
            note = titleEqual ? "时长相差 \(seconds) 秒，可能是其他版本" : "标题相近，仅供参考"
        } else if let ratio, (0.85...1.18).contains(ratio) {
            tier = .loose
            note = "同名歌曲 · 歌手为\(hit.artistDisplay.isEmpty ? "未知" : hit.artistDisplay)，仅供参考"
        } else if delta == nil, titleEqual, hit.rank < 3 {
            tier = .loose
            note = "同名歌曲 · 歌手不同，仅供参考"
        } else {
            return nil
        }

        var score = 0.30 * (fullEqual ? 1 : titleEqual ? 0.95 : titleSimilarity)
        score += 0.20 * (artistMatch == .equal ? 1 : artistMatch == .contains ? 0.85 : 0)
        score += 0.25 * (delta.map { max(0, 1 - $0 / 20) } ?? 0.4)
        if let expected = q.albumKey, let album = hit.album.map(SongText.normalized), !album.isEmpty {
            if album == expected {
                score += 0.05
            } else if min(album.count, expected.count) >= 2, album.contains(expected) || expected.contains(album) {
                score += 0.03
            }
        }
        score += reliability(hit.source)
        if q.query.preferredSource == hit.source { score += 0.1 }
        score += 0.02 * max(0, 1 - Double(hit.rank) / 10)
        if let providerScore = hit.providerScore, providerScore.isFinite { score += 0.02 * min(1, max(0, providerScore) / 100) }
        if swapped { score -= 0.05 }
        let meta = score

        let candidate = LyricsCandidate(id: "\(hit.source.rawValue):\(hit.remoteID)", source: hit.source, remoteID: hit.remoteID,
                                        title: hit.title, artist: hit.artistDisplay, album: hit.album, duration: hit.duration,
                                        tier: tier, score: meta + contentBonus(synced: hit.syncedHint, words: hit.wordHint, translation: 0),
                                        note: note, extra: hit.extra)
        let key = [hit.source.rawValue, SongText.normalized(SongText.baseTitle(title)), artistKeys.first?.key ?? "", versionClass,
                   hit.duration.map { String(Int($0.rounded())) } ?? "-"].joined(separator: "|")
        return LyricsEvaluatedHit(candidate: candidate, metaScore: meta, syncedHint: hit.syncedHint, wordHint: hit.wordHint, dedupeKey: key)
    }

    private static func versionNote(query: String, candidate: String, seconds: Int) -> String {
        if query == candidate { return "时长相差 \(seconds) 秒，可能是其他版本" }
        if query == "live", candidate == "studio" { return "现场版 · 使用录音室歌词，时间轴可能有偏差" }
        if candidate == "studio" { return "\(SongText.versionClassLabel(query)) · 使用原版歌词，时间轴可能有偏差" }
        return "使用\(SongText.versionClassLabel(candidate))歌词，时间轴可能有偏差"
    }

    static func bestSimilarity(_ first: Set<String>, _ second: Set<String>) -> Double {
        var best = 0.0
        for a in first {
            for b in second {
                best = max(best, SongText.similarity(a, b))
                if best >= 1 { return 1 }
            }
        }
        return best
    }

    /// Manual search: the user typed free text, so tiers say how much of it the row explains.
    static func evaluateManual(_ hit: LyricsSearchHit, text: String, duration: Double?, preferred: LyricsSource?) -> LyricsEvaluatedHit? {
        let typed = SongText.normalized(text)
        guard !typed.isEmpty else { return nil }
        let title = SongText.cleanedCandidateTitle(hit.title, artist: hit.artists.joined(separator: "/"))
        var tags = SongText.versionTags(title, album: hit.album)
        for descriptor in hit.descriptors { tags.formUnion(SongText.descriptorTags(descriptor)) }
        let versionClass = SongText.versionClass(tags)
        let typedTags = SongText.descriptorTags(text)
        if versionClass == "instrumental", !typedTags.contains("instrumental") { return nil }
        let names = SongText.titleNames(title, extra: hit.aliases)
        let titleIn = names.contains { $0.count >= 1 && (typed.contains($0) || $0.contains(typed)) }
        let artistIn = SongText.artistKeys(hit.artists).contains { $0.key.count >= 2 && typed.contains($0.key) }
        var delta: Double?
        var durationOff = false
        if let duration, duration > 0, let actual = hit.duration, actual > 0 {
            delta = abs(actual - duration)
            durationOff = !(0.6...1.6).contains(actual / duration)
        }
        var tier: MatchTier
        if titleIn && artistIn { tier = (delta ?? 99) <= 2 ? .exact : .strong } else if titleIn { tier = .version } else { tier = .loose }
        if durationOff { tier = .loose }
        var score = (titleIn ? 0.30 : 0.1) + (artistIn ? 0.20 : 0)
        score += 0.25 * (delta.map { max(0, 1 - $0 / 20) } ?? 0.4)
        score += reliability(hit.source) + (preferred == hit.source ? 0.06 : 0)
        score += 0.05 * max(0, 1 - Double(hit.rank) / 10)
        let meta = score
        var note = "手动搜索"
        if versionClass != "studio" { note += " · \(SongText.versionClassLabel(versionClass))" }
        if let delta, delta > 2 { note += " · 时长相差 \(Int(delta.rounded())) 秒" }
        let candidate = LyricsCandidate(id: "\(hit.source.rawValue):\(hit.remoteID)", source: hit.source, remoteID: hit.remoteID,
                                        title: hit.title, artist: hit.artistDisplay, album: hit.album, duration: hit.duration,
                                        tier: tier, score: meta + contentBonus(synced: hit.syncedHint, words: hit.wordHint, translation: 0),
                                        note: note, extra: hit.extra)
        let key = [hit.source.rawValue, SongText.normalized(SongText.baseTitle(title)), SongText.artistKeys(hit.artists).first?.key ?? "",
                   versionClass, hit.duration.map { String(Int($0.rounded())) } ?? "-"].joined(separator: "|")
        return LyricsEvaluatedHit(candidate: candidate, metaScore: meta, syncedHint: hit.syncedHint, wordHint: hit.wordHint, dedupeKey: key)
    }

    /// Content check after fetching: drops empty bodies and placeholders, rescoring with the real content.
    static func accept(_ lyrics: Lyrics, for hit: LyricsEvaluatedHit, duration: Double?) -> Lyrics? {
        var candidate = hit.candidate
        let hasText = !(lyrics.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if lyrics.isSynced {
            var bonus = contentBonus(synced: 1, words: lyrics.hasWordTiming ? 1 : 0, translation: lyrics.hasTranslation ? 1 : 0)
            if let duration, let last = lyrics.lines.last(where: { !$0.text.isEmpty }), last.start > duration + 10 {
                bonus -= 0.1   // timeline belongs to a longer recording
            }
            candidate.score = hit.metaScore + bonus
        } else if hasText {
            candidate.score = hit.metaScore
            candidate.note = joined(candidate.note, "仅文本，无时间轴")
        } else if lyrics.instrumental {
            guard candidate.tier <= .strong || candidate.note == identityNote else { return nil }
            candidate.score = hit.metaScore
            candidate.note = joined(candidate.note, "纯音乐")
        } else {
            return nil
        }
        var result = lyrics
        result.candidate = candidate
        return result
    }

    private static func joined(_ note: String, _ suffix: String) -> String {
        note.isEmpty ? suffix : note.hasSuffix(suffix) ? note : note + " · " + suffix
    }

    /// Synced first; plain text only when no synced result exists in the same or the next tier;
    /// 纯音乐 only when no lyric result is within one tier of it.
    static func effectiveRank(_ lyrics: Lyrics) -> Double {
        let tier = Double(lyrics.candidate.tier.rawValue)
        if lyrics.isSynced { return tier }
        if !(lyrics.plainText ?? "").isEmpty { return tier + 1.5 }
        return tier + 1.6
    }

    static func best(_ results: [Lyrics]) -> Lyrics? {
        results.min { a, b in
            let first = effectiveRank(a), second = effectiveRank(b)
            if first != second { return first < second }
            if a.candidate.score != b.candidate.score { return a.candidate.score > b.candidate.score }
            return a.candidate.id < b.candidate.id
        }
    }

    static func ordered(_ candidates: [LyricsCandidate]) -> [LyricsCandidate] {
        candidates.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.score != b.score { return a.score > b.score }
            return a.id < b.id
        }
    }
}
