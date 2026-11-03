import Foundation

/// What a provider is asked to search for.
struct LyricsSearchRequest: Sendable, Equatable {
    var title: String
    var artist: String
    var duration: Double?
    /// Manual search: the user's text, sent as-is.
    var freeText: String?
    /// Second attempt: use the provider's free-text route where it has one.
    var broad = false

    var keywords: String { freeText ?? [title, artist].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// One search result before matching.
struct LyricsSearchHit: Sendable {
    var source: LyricsSource
    var remoteID: String
    var title: String
    var artists: [String]
    var album: String?
    var duration: Double?
    /// Alternative names of the title (translations).
    var aliases: [String] = []
    /// Extra descriptor text that may carry version tags (NetEase alias, QQ subtitle).
    var descriptors: [String] = []
    /// Position in the provider's own ranking, 0 first.
    var rank: Int
    var extra: [String: String] = [:]
    var providerScore: Double?
    /// LRCLIB returns lyric bodies together with search results.
    var embedded: Lyrics?
    /// Expectation that fetched lyrics are synced / word-timed (0…1), used before fetching.
    var syncedHint: Double = 0.7
    var wordHint: Double = 0

    var artistDisplay: String { artists.joined(separator: " / ") }

    var placeholderCandidate: LyricsCandidate {
        LyricsCandidate(id: "\(source.rawValue):\(remoteID)", source: source, remoteID: remoteID, title: title,
                        artist: artistDisplay, album: album, duration: duration, tier: .loose, score: 0, note: "", extra: extra)
    }
}

protocol LyricsProvider: Sendable {
    var source: LyricsSource { get }
    func search(_ request: LyricsSearchRequest, http: LyricsHTTP) async throws -> [LyricsSearchHit]
    func lyrics(for candidate: LyricsCandidate, http: LyricsHTTP) async throws -> Lyrics
}

private func hint(_ candidate: LyricsCandidate) -> LyricsTitleHint {
    LyricsTitleHint(title: candidate.title, artist: candidate.artist)
}

/// A usable duration in seconds (anything above a day is nonsense).
private func positive(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value > 0, value < 86_400 else { return nil }
    return value
}

private func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}

// MARK: - NetEase Cloud Music

struct NetEaseLyricsProvider: LyricsProvider {
    let source = LyricsSource.netEase
    private let headers = ["Referer": "https://music.163.com/"]

    func search(_ request: LyricsSearchRequest, http: LyricsHTTP) async throws -> [LyricsSearchHit] {
        let url = LyricsHTTP.url("https://music.163.com/api/search/get",
                                 [("s", request.keywords), ("type", "1"), ("limit", "30"), ("offset", "0")])
        let response = try LyricsHTTP.decode(SearchResponse.self, from: try await http.get(url, source: source, headers: headers))
        try await check(response.code, http: http)
        return (response.result?.songs ?? []).enumerated().compactMap { index, song in
            guard song.id > 0, let name = nonEmpty(song.name) else { return nil }
            var aliases = song.transNames ?? []
            var descriptors: [String] = []
            for alias in song.alias ?? [] where !alias.isEmpty {
                if SongText.isDescriptor(alias) { descriptors.append(alias) } else { aliases.append(alias) }
            }
            return LyricsSearchHit(source: source, remoteID: String(song.id), title: name,
                               artists: (song.artists ?? []).compactMap { nonEmpty($0.name) }, album: nonEmpty(song.album?.name),
                               duration: positive(song.duration.map { $0 / 1000 }), aliases: aliases, descriptors: descriptors, rank: index)
        }
    }

    func lyrics(for candidate: LyricsCandidate, http: LyricsHTTP) async throws -> Lyrics {
        let url = LyricsHTTP.url("https://music.163.com/api/song/lyric",
                                 [("id", candidate.remoteID), ("lv", "-1"), ("kv", "-1"), ("tv", "-1")])
        let response = try LyricsHTTP.decode(LyricResponse.self, from: try await http.get(url, source: source, headers: headers))
        try await check(response.code, http: http)
        if response.nolyric == true || response.pureMusic == true {
            let parsed = LyricsParser.parseLRC(response.lrc?.lyric ?? "", hint: hint(candidate))
            return Lyrics(candidate: candidate, lines: [], plainText: nil, credits: parsed.credits, instrumental: true)
        }
        guard let body = nonEmpty(response.lrc?.lyric) else { throw LyricsLookupError.noLyrics }
        let parsed = LyricsParser.parseLRC(body, translation: response.tlyric?.lyric, hint: hint(candidate))
        return Lyrics(candidate: candidate, lines: parsed.lines, plainText: parsed.plainText, credits: parsed.credits,
                      instrumental: parsed.instrumental)
    }

    private func check(_ code: Int?, http: LyricsHTTP) async throws {
        guard let code, code != 200 else { return }
        if code == -460 || code == -462 || code == 405 {
            // Anti-abuse responses arrive with HTTP 200; back off like a 429.
            await http.limiter.block(source, for: 60, now: http.now())
            throw LyricsLookupError.rateLimited(60)
        }
        throw LyricsLookupError.invalidResponse
    }

    private struct SearchResponse: Decodable {
        struct Result: Decodable { var songs: [Song]? }
        var code: Int?
        var result: Result?
    }

    private struct Song: Decodable {
        struct Named: Decodable { var name: String? }
        var id: Int64
        var name: String?
        var artists: [Named]?
        var album: Named?
        var duration: Double?
        var alias: [String]?
        var transNames: [String]?
    }

    private struct LyricResponse: Decodable {
        struct Body: Decodable { var lyric: String? }
        var code: Int?
        var lrc: Body?
        var tlyric: Body?
        var nolyric: Bool?
        var uncollected: Bool?
        var pureMusic: Bool?
    }
}

// MARK: - QQ Music

struct QQMusicLyricsProvider: LyricsProvider {
    let source = LyricsSource.qqMusic

    func search(_ request: LyricsSearchRequest, http: LyricsHTTP) async throws -> [LyricsSearchHit] {
        let url = LyricsHTTP.url("https://c.y.qq.com/soso/fcgi-bin/client_search_cp",
                                 [("w", request.keywords), ("format", "json"), ("p", "1"), ("n", "20"), ("cr", "1"), ("new_json", "1")])
        let data = try await http.get(url, source: source, headers: ["Referer": "https://y.qq.com/"])
        let response = try LyricsHTTP.decode(SearchResponse.self, from: data)
        guard (response.code ?? 0) == 0 else { throw LyricsLookupError.invalidResponse }
        return (response.data?.song?.list ?? []).enumerated().compactMap { index, song in
            guard let mid = nonEmpty(song.mid), let title = nonEmpty(song.title) ?? nonEmpty(song.name) else { return nil }
            return LyricsSearchHit(source: source, remoteID: mid, title: title,
                               artists: (song.singer ?? []).compactMap { nonEmpty($0.name) }, album: nonEmpty(song.album?.name),
                               duration: positive(song.interval), descriptors: [song.subtitle].compactMap(nonEmpty), rank: index)
        }
    }

    func lyrics(for candidate: LyricsCandidate, http: LyricsHTTP) async throws -> Lyrics {
        let url = LyricsHTTP.url("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg",
                                 [("songmid", candidate.remoteID), ("format", "json"), ("nobase64", "1"), ("g_tk", "5381")])
        let data = try await http.get(url, source: source, headers: ["Referer": "https://y.qq.com/portal/player.html"])
        let response = try LyricsHTTP.decode(LyricResponse.self, from: data)
        let code = response.retcode ?? response.code ?? 0
        guard code == 0, let raw = nonEmpty(response.lyric) else {
            if code == 0 || code == -1901 { throw LyricsLookupError.noLyrics }
            throw LyricsLookupError.invalidResponse
        }
        let body = Self.text(raw)
        let translation = nonEmpty(response.trans).map(Self.text)
        let parsed = LyricsParser.parseLRC(body, translation: translation, hint: hint(candidate))
        return Lyrics(candidate: candidate, lines: parsed.lines, plainText: parsed.plainText, credits: parsed.credits,
                      instrumental: parsed.instrumental)
    }

    /// Lyrics arrive HTML-escaped, and base64 when the server ignores `nobase64`.
    static func text(_ raw: String) -> String {
        if !raw.contains("["), let data = Data(base64Encoded: raw, options: .ignoreUnknownCharacters),
           let decoded = String(data: data, encoding: .utf8), decoded.contains("[") {
            return LyricsParser.decodeEntities(decoded)
        }
        return LyricsParser.decodeEntities(raw)
    }

    private struct SearchResponse: Decodable {
        struct Body: Decodable {
            struct Songs: Decodable { var list: [Song]? }
            var song: Songs?
        }
        var code: Int?
        var data: Body?
    }

    private struct Song: Decodable {
        struct Named: Decodable { var name: String? }
        var mid: String?
        var title: String?
        var name: String?
        var subtitle: String?
        var interval: Double?
        var singer: [Named]?
        var album: Named?
    }

    private struct LyricResponse: Decodable {
        var retcode: Int?
        var code: Int?
        var lyric: String?
        var trans: String?
    }
}

// MARK: - Kugou

struct KugouLyricsProvider: LyricsProvider {
    let source = LyricsSource.kugou

    func search(_ request: LyricsSearchRequest, http: LyricsHTTP) async throws -> [LyricsSearchHit] {
        let keyword = request.freeText ?? (request.artist.isEmpty ? request.title : "\(request.artist) - \(request.title)")
        var items = [("ver", "1"), ("man", "yes"), ("client", "pc"), ("keyword", keyword)]
        if let duration = positive(request.duration) { items.append(("duration", String(Int((duration * 1000).rounded())))) }
        items.append(("hash", ""))
        let data = try await http.get(LyricsHTTP.url("https://lyrics.kugou.com/search", items), source: source)
        let response = try LyricsHTTP.decode(SearchResponse.self, from: data)
        if let status = response.status, status != 200 { throw LyricsLookupError.invalidResponse }
        return (response.candidates ?? []).enumerated().compactMap { index, item in
            guard let id = nonEmpty(item.id?.value), let key = nonEmpty(item.accesskey), let song = nonEmpty(item.song) else { return nil }
            return LyricsSearchHit(source: source, remoteID: id, title: song, artists: [item.singer].compactMap(nonEmpty), album: nil,
                               duration: positive(item.duration.map { $0 / 1000 }), rank: index, extra: ["accesskey": key],
                               providerScore: item.score, syncedHint: 1, wordHint: 0.9)
        }
    }

    func lyrics(for candidate: LyricsCandidate, http: LyricsHTTP) async throws -> Lyrics {
        guard let key = candidate.extra["accesskey"], !key.isEmpty else { throw LyricsLookupError.invalidResponse }
        do {
            let download = try await self.download(candidate.remoteID, key: key, format: "krc", http: http)
            let text: String
            if download.fmt?.lowercased() == "lrc" {
                text = try Self.base64Text(download.content)
                return make(candidate, LyricsParser.parseLRC(text, hint: hint(candidate)))
            }
            text = try LyricsParser.decodeKRC(base64: download.content ?? "")
            let parsed = LyricsParser.parseKRC(text, hint: hint(candidate))
            if parsed.hasContent { return make(candidate, parsed) }
        } catch is CancellationError {
            throw CancellationError()
        } catch LyricsLookupError.rateLimited(let seconds) {
            throw LyricsLookupError.rateLimited(seconds)
        } catch {
            // Fall back to plain LRC below.
        }
        let download = try await self.download(candidate.remoteID, key: key, format: "lrc", http: http)
        return make(candidate, LyricsParser.parseLRC(try Self.base64Text(download.content), hint: hint(candidate)))
    }

    private func make(_ candidate: LyricsCandidate, _ parsed: ParsedLyrics) -> Lyrics {
        Lyrics(candidate: candidate, lines: parsed.lines, plainText: parsed.plainText, credits: parsed.credits, instrumental: parsed.instrumental)
    }

    private func download(_ id: String, key: String, format: String, http: LyricsHTTP) async throws -> Download {
        let url = LyricsHTTP.url("https://lyrics.kugou.com/download",
                                 [("ver", "1"), ("client", "pc"), ("id", id), ("accesskey", key), ("fmt", format), ("charset", "utf8")])
        let response = try LyricsHTTP.decode(Download.self, from: try await http.get(url, source: source))
        guard (response.status ?? 200) == 200, nonEmpty(response.content) != nil else { throw LyricsLookupError.noLyrics }
        return response
    }

    private static func base64Text(_ content: String?) throws -> String {
        guard let content, let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else {
            throw LyricsLookupError.decodeFailed
        }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    private struct SearchResponse: Decodable {
        var status: Int?
        var candidates: [Item]?
    }

    private struct Item: Decodable {
        var id: LyricsLenientString?
        var accesskey: String?
        var singer: String?
        var song: String?
        var duration: Double?
        var score: Double?
    }

    private struct Download: Decodable {
        var status: Int?
        var content: String?
        var fmt: String?
    }
}

// MARK: - LRCLIB

struct LRCLIBLyricsProvider: LyricsProvider {
    let source = LyricsSource.lrclib

    func search(_ request: LyricsSearchRequest, http: LyricsHTTP) async throws -> [LyricsSearchHit] {
        let items: [(String, String)]
        if let text = request.freeText {
            items = [("q", text)]
        } else if request.artist.isEmpty || request.broad {
            items = [("q", request.keywords)]
        } else {
            items = [("track_name", request.title), ("artist_name", request.artist)]
        }
        let data = try await http.get(LyricsHTTP.url("https://lrclib.net/api/search", items), source: source)
        let records = try LyricsHTTP.decode([Record].self, from: data)
        return records.enumerated().compactMap { index, record in
            guard record.id > 0, let title = nonEmpty(record.trackName) else { return nil }
            var hit = LyricsSearchHit(source: source, remoteID: String(record.id), title: title,
                                  artists: [record.artistName].compactMap(nonEmpty), album: nonEmpty(record.albumName),
                                  duration: positive(record.duration), rank: index)
            let lyrics = Self.lyrics(record, candidate: hit.placeholderCandidate)
            hit.embedded = lyrics
            hit.syncedHint = lyrics.isSynced ? 1 : 0
            return hit
        }
    }

    func lyrics(for candidate: LyricsCandidate, http: LyricsHTTP) async throws -> Lyrics {
        let data = try await http.get(LyricsHTTP.url("https://lrclib.net/api/get/\(candidate.remoteID)", []), source: source)
        let record = try LyricsHTTP.decode(Record.self, from: data)
        return Self.lyrics(record, candidate: candidate)
    }

    static func lyrics(_ record: Record, candidate: LyricsCandidate) -> Lyrics {
        let hint = LyricsTitleHint(title: candidate.title, artist: candidate.artist)
        let synced = nonEmpty(record.syncedLyrics).map { LyricsParser.parseLRC($0, hint: hint) }
        let plain = nonEmpty(record.plainLyrics).map { LyricsParser.parsePlain($0, hint: hint) }
        if let synced, !synced.lines.isEmpty {
            return Lyrics(candidate: candidate, lines: synced.lines, plainText: plain?.plainText ?? synced.plainText,
                          credits: synced.credits.isEmpty ? (plain?.credits ?? []) : synced.credits, instrumental: false)
        }
        if let plain, let text = plain.plainText, !text.isEmpty {
            return Lyrics(candidate: candidate, lines: [], plainText: text, credits: plain.credits, instrumental: false)
        }
        let instrumental = record.instrumental == true || synced?.instrumental == true || plain?.instrumental == true
        return Lyrics(candidate: candidate, lines: [], plainText: nil, credits: synced?.credits ?? plain?.credits ?? [], instrumental: instrumental)
    }

    struct Record: Decodable {
        var id: Int64
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }
}
