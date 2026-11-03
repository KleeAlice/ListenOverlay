import Foundation

final class NetEaseMusicMatcher {
    private let session: URLSession
    private static let cooldownLock = NSLock()
    private static var retryDate = Date.distantPast

    init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: Self.sessionConfiguration())
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }

    /// Only a fingerprint is transmitted. This undocumented endpoint is used by
    /// NetEase's official browser extension (v1.0.4); it may change independently.
    /// A result is only a candidate: MusicConfirmation must verify another sample.
    func recognize(fingerprint: NetEaseFingerprint) async throws -> MusicMatch? {
        try Task.checkCancellation()
        let allowedAt = Self.cooldownLock.withLock { Self.retryDate }
        guard Date() >= allowedAt else { throw MusicMatcherError.rateLimited(until: allowedAt) }
        guard fingerprint.duration.isFinite, (3...12.1).contains(fingerprint.duration),
              fingerprint.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              fingerprint.value.utf8.count <= 65_536,
              let bytes = Data(base64Encoded: fingerprint.value), !bytes.isEmpty else {
            throw NetEaseMusicMatcherError.invalidFingerprint
        }

        let fields = [
            ("sessionId", UUID().uuidString),
            ("algorithmCode", "shazam_v2"),
            ("duration", String(format: "%.9g", locale: Locale(identifier: "en_US_POSIX"), fingerprint.duration)),
            ("rawdata", fingerprint.value),
            ("times", "2"),
            ("decrypt", "1")
        ]
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._")
        let form = fields.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        let url = URL(string: "https://interface.music.163.com/api/music/audio/match")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = Data(form.utf8)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw MusicMatcherError.invalidResponse }
        if response.statusCode == 429 {
            throw Self.registerRateLimit(retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        }
        guard (200..<300).contains(response.statusCode) else { throw MusicMatcherError.http(response.statusCode) }

        let decoded: NetEaseRecognitionResponse
        do { decoded = try JSONDecoder().decode(NetEaseRecognitionResponse.self, from: data) }
        catch { throw MusicMatcherError.invalidResponse }
        if decoded.code == 429 { throw Self.registerRateLimit(retryAfter: response.value(forHTTPHeaderField: "Retry-After")) }
        guard decoded.code == 200 else { throw NetEaseMusicMatcherError.service(decoded.code) }
        guard let first = decoded.first else { return nil }
        let song = first.song
        let duration = song.duration / 1_000
        let position = first.startTime / 1_000 + fingerprint.duration
        guard song.id > 0, Self.hasText(song.name), !song.artists.isEmpty,
              song.artists.allSatisfy({ Self.hasText($0.name) }),
              song.duration.isFinite, duration > 0,
              first.startTime.isFinite, first.startTime >= 0,
              position.isFinite, position <= duration else { throw MusicMatcherError.invalidResponse }

        let artist = song.artists.map(\.name).joined(separator: " / ")
        var match = MusicMatch(title: song.name, artist: artist, duration: duration,
                               position: position, matchedAt: fingerprint.capturedAt)
        match.catalogKey = "netease:\(song.id)"
        // The official endpoint also returns {id: 0, name: ""} for some tracks.
        // Missing album metadata does not establish a different recording identity.
        match.album = song.album.flatMap { Self.hasText($0.name) ? $0.name : nil }
        match.titleAliases = [song.name]
        match.artistAliases = [artist]
        return match
    }

    static func rateLimitDate(retryAfter: String?, now: Date) -> Date {
        var delay: TimeInterval = 60
        if let header = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let seconds = Double(header), seconds.isFinite, seconds > 0 {
                delay = max(delay, seconds)
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                if let date = formatter.date(from: header) { delay = max(delay, date.timeIntervalSince(now)) }
            }
        }
        return now.addingTimeInterval(delay)
    }

    private static func registerRateLimit(retryAfter: String?) -> MusicMatcherError {
        let proposed = rateLimitDate(retryAfter: retryAfter, now: Date())
        let until = cooldownLock.withLock {
            retryDate = max(retryDate, proposed)
            return retryDate
        }
        return .rateLimited(until: until)
    }

    private static func hasText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct NetEaseRecognitionResponse: Decodable {
    struct Candidate: Decodable {
        struct Song: Decodable {
            struct NamedItem: Decodable { let name: String }
            let id: Int64
            let name: String
            let artists: [NamedItem]
            let album: NamedItem?
            let duration: Double
        }
        let startTime: Double
        let song: Song
    }
    let code: Int
    let first: Candidate?

    private enum CodingKeys: String, CodingKey { case code, data }
    private enum PayloadKeys: String, CodingKey { case result }

    init(from decoder: Decoder) throws {
        let envelope = try decoder.container(keyedBy: CodingKeys.self)
        code = try envelope.decode(Int.self, forKey: .code)
        guard code == 200 else { first = nil; return }
        let payload = try envelope.nestedContainer(keyedBy: PayloadKeys.self, forKey: .data)
        var results = try payload.nestedUnkeyedContainer(forKey: .result)
        // Deliberately decode only top1. Neither a later familiar title nor a
        // malformed lower candidate changes the identity returned by the provider.
        first = results.isAtEnd ? nil : try results.decode(Candidate.self)
    }
}

enum NetEaseMusicMatcherError: LocalizedError {
    case invalidFingerprint
    case service(Int)

    var errorDescription: String? {
        switch self {
        case .invalidFingerprint: return "网易云音乐指纹或采样时间无效，请重新采样。"
        case .service(let code): return "网易云识曲服务暂时不可用（服务代码 \(code)）；可以手动搜索歌词。"
        }
    }
}
