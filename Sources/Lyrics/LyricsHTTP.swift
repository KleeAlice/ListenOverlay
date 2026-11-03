import Foundation

enum LyricsLookupError: LocalizedError, Sendable, Equatable {
    case http(Int)
    case rateLimited(Int)
    case timeout
    case tooLarge
    case invalidResponse
    case network(String)
    case noLyrics
    case decodeFailed
    case unavailable

    /// Short Chinese text for diagnostics.
    var reason: String {
        switch self {
        case .http(let status): return "服务暂时不可用（HTTP \(status)）"
        case .rateLimited(let seconds): return "请求过于频繁，\(max(1, seconds)) 秒后再试"
        case .timeout: return "请求超时"
        case .tooLarge: return "响应过大"
        case .invalidResponse: return "返回数据无法解析"
        case .network(let detail): return detail
        case .noLyrics: return "没有歌词"
        case .decodeFailed: return "歌词解码失败"
        case .unavailable: return "来源不可用"
        }
    }

    var errorDescription: String? { reason }

    static func describe(_ error: any Error) -> String {
        if let error = error as? LyricsLookupError { return error.reason }
        if let error = error as? URLError { return from(error).reason }
        if error is CancellationError { return "已取消" }
        return "未知错误"
    }

    static func from(_ error: URLError) -> LyricsLookupError {
        switch error.code {
        case .timedOut: return .timeout
        case .notConnectedToInternet, .dataNotAllowed: return .network("未连接网络")
        case .cannotFindHost, .dnsLookupFailed: return .network("无法解析服务器地址")
        case .cannotConnectToHost: return .network("无法连接服务器")
        case .networkConnectionLost: return .network("网络连接中断")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return .network("安全连接失败")
        case .badServerResponse, .cannotParseResponse: return .invalidResponse
        default: return .network("网络错误（\(error.code.rawValue)）")
        }
    }
}

/// Per-source HTTP 429 back-off shared by every request of one service.
actor LyricsRateLimiter {
    private var blockedUntil: [LyricsSource: Date] = [:]

    func remaining(_ source: LyricsSource, now: Date) -> TimeInterval? {
        guard let until = blockedUntil[source], until > now else { return nil }
        return until.timeIntervalSince(now)
    }

    func block(_ source: LyricsSource, for seconds: TimeInterval, now: Date) {
        let until = now.addingTimeInterval(seconds)
        if until > (blockedUntil[source] ?? .distantPast) { blockedUntil[source] = until }
    }
}

struct LyricsHTTP: Sendable {
    static let userAgent = "ListenOverlay/1.0 (macOS desktop lyrics)"

    let session: URLSession
    let limiter: LyricsRateLimiter
    let timeout: TimeInterval
    let maxBytes: Int
    let now: @Sendable () -> Date

    /// No cookies, no URL cache.
    static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 3
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }

    func get(_ url: URL, source: LyricsSource, headers: [String: String] = [:]) async throws -> Data {
        try Task.checkCancellation()
        if let wait = await limiter.remaining(source, now: now()) {
            throw LyricsLookupError.rateLimited(Int(wait.rounded(.up)))
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let session = self.session
        let maxBytes = self.maxBytes
        let prepared = request
        let reply: Reply
        do {
            reply = try await Self.withDeadline(timeout) {
                let (bytes, response) = try await session.bytes(for: prepared)
                guard let http = response as? HTTPURLResponse else { throw LyricsLookupError.invalidResponse }
                if http.expectedContentLength > Int64(maxBytes) { throw LyricsLookupError.tooLarge }
                var data = Data()
                if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > maxBytes { throw LyricsLookupError.tooLarge }
                }
                return Reply(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"), data: data)
            }
        } catch let error as LyricsLookupError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw LyricsLookupError.from(error)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw LyricsLookupError.network("网络错误")
        }
        if reply.status == 429 {
            let delay = Self.retryDelay(reply.retryAfter, now: now())
            await limiter.block(source, for: delay, now: now())
            throw LyricsLookupError.rateLimited(Int(delay.rounded(.up)))
        }
        guard (200..<300).contains(reply.status) else { throw LyricsLookupError.http(reply.status) }
        return reply.data
    }

    private struct Reply: Sendable {
        var status: Int
        var retryAfter: String?
        var data: Data
    }

    /// Retry-After as seconds or an HTTP date; clamped to 5 s … 15 min, 60 s when absent.
    static func retryDelay(_ header: String?, now: Date) -> TimeInterval {
        var delay: TimeInterval = 60
        if let value = header?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            if let seconds = Double(value), seconds.isFinite {
                delay = seconds
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
                if let date = formatter.date(from: value) { delay = date.timeIntervalSince(now) }
            }
        }
        return min(900, max(5, delay))
    }

    static func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.01, seconds) * 1_000_000_000))
                throw LyricsLookupError.timeout
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw LyricsLookupError.timeout }
            return value
        }
    }

    static func url(_ base: String, _ items: [(String, String)]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents keeps '+' literal; form decoders read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// Decodes JSON, tolerating a JSONP wrapper such as `callback({...})`.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            guard let first = data.firstIndex(where: { $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: "[") }),
                  let last = data.lastIndex(where: { $0 == UInt8(ascii: "}") || $0 == UInt8(ascii: "]") }), first < last,
                  first > data.startIndex,
                  let value = try? JSONDecoder().decode(T.self, from: data[first...last]) else {
                throw LyricsLookupError.invalidResponse
            }
            return value
        }
    }
}

/// A string field some providers send as a number.
struct LyricsLenientString: Decodable, Sendable, Hashable {
    var value: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let integer = try? container.decode(Int64.self) {
            value = String(integer)
        } else if let double = try? container.decode(Double.self), double.isFinite, abs(double) < 9e15 {
            value = String(Int64(double))
        } else {
            value = ""
        }
    }
}
