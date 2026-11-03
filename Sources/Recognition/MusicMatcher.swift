import Foundation
import AVFoundation
import ShazamKit

struct MusicMatch {
    let title: String
    let artist: String
    let duration: Double?
    /// Song position at matchedAt, the capture end (not the network response time).
    let position: Double?
    let matchedAt: Date
    var appleMusicID: String?
    var netEaseSongID: Int64?
    var catalogKey: String?
    var album: String?
    var titleAliases: [String] = []
    var artistAliases: [String] = []

    var identity: String { catalogKey ?? appleMusicID ?? "\(title)\u{0}\(artist)" }
}

final class MusicMatcher {
    private let session: URLSession
    private let metadata: SongMetadataClient
    private let cooldownLock = NSLock()
    private var retryDate = Date.distantPast
    private let metadataLock = NSLock()
    private var metadataCache: [String: SongMetadata] = [:]
    private var metadataOrder: [String] = []

    init(session: URLSession = .shared) {
        self.session = session
        self.metadata = SongMetadataClient(session: session)
    }

    /// Call immediately after collecting the buffer. Only a fingerprint leaves the machine.
    /// This uses an unofficial service, whose availability and format can change.
    func recognize(buffer: AVAudioPCMBuffer, enrichMetadata: Bool = true) async throws -> MusicMatch? {
        try Task.checkCancellation()
        let allowedAt = cooldownLock.withLock { retryDate }
        guard Date() >= allowedAt else { throw MusicMatcherError.rateLimited(until: allowedAt) }
        let captureEnd = Date()
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        guard duration.isFinite, (3...12.1).contains(duration), buffer.format.channelCount == 1 else {
            throw MusicMatcherError.invalidAudio
        }
        try Task.checkCancellation()
        let generator = SHSignatureGenerator()
        try generator.append(buffer, at: nil)
        let signature = generator.signature()
        let raw = try Self.rawSignature(from: signature.dataRepresentation)
        let url = URL(string: "https://amp.shazam.com/discovery/v5/en-US/US/iphone/-/tag/\(UUID().uuidString)/\(UUID().uuidString)?sync=true&webv3=true&sampling=true&connected=&shazamapiversion=v3&sharehub=true&hubv5minorversion=v5.1&hidelb=true&video=v3")!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        // Endpoint, headers and JSON schema adapted from ShazamIO (MIT); see Resources license.
        Self.setHeaders(on: &request, language: "en-US")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "timezone": TimeZone.current.identifier,
            "signature": ["uri": "data:audio/vnd.shazam.sig;base64," + raw.base64EncodedString(), "samplems": Int(signature.duration * 1000)],
            "timestamp": Int64(captureEnd.timeIntervalSince1970 * 1000),
            "context": [String: String](), "geolocation": [String: String]()
        ])
        let data = try await responseData(for: request)
        guard let match = try Self.decodeResponse(data, sampleDuration: duration, captureEnd: captureEnd) else { return nil }
        guard enrichMetadata else { return match }
        return try await enrich(match)
    }

    /// Call only after the fingerprint identity is accepted. Cache song details,
    /// never playback positions: each fingerprint retains its own capture anchor.
    func enrich(_ match: MusicMatch) async throws -> MusicMatch {
        try Task.checkCancellation()
        if let details = cachedMetadata(for: match.identity) { return Self.applying(details, to: match) }
        let allowedAt = cooldownLock.withLock { retryDate }
        guard Date() >= allowedAt else { throw MusicMatcherError.rateLimited(until: allowedAt) }
        // Never guess artist/title translations. Look up the exact catalog item returned
        // by the fingerprint provider, keeping the original names as verified aliases.
        if let id = match.appleMusicID {
            do {
                if let details = try await metadata.resolve(appleMusicID: id) {
                    try Task.checkCancellation()
                    remember(details, for: match.identity)
                    return Self.applying(details, to: match)
                }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            }
        }
        try Task.checkCancellation()
        // Some exact Apple IDs are unavailable in the Taiwan storefront. The same
        // Shazam catalog key can still supply Chinese names without a text search.
        if let key = match.catalogKey, !key.isEmpty, key.utf8.allSatisfy({ (48...57).contains($0) }) {
            let url = URL(string: "https://amp.shazam.com/discovery/v5/zh-CN/CN/iphone/-/track/\(key)?shazamapiversion=v3&video=v3")!
            var localizedRequest = URLRequest(url: url, timeoutInterval: 8)
            Self.setHeaders(on: &localizedRequest, language: "zh-CN")
            do {
                let data = try await responseData(for: localizedRequest)
                if let details = try Self.localizedMetadata(data, for: match) {
                    try Task.checkCancellation()
                    remember(details, for: match.identity)
                    return Self.applying(details, to: match)
                }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            }
        }
        try Task.checkCancellation()
        return match
    }

    private func cachedMetadata(for identity: String) -> SongMetadata? {
        metadataLock.withLock {
            guard let details = metadataCache[identity] else { return nil }
            metadataOrder.removeAll { $0 == identity }
            metadataOrder.append(identity)
            return details
        }
    }

    private func remember(_ details: SongMetadata, for identity: String) {
        metadataLock.withLock {
            metadataCache[identity] = details
            metadataOrder.removeAll { $0 == identity }
            metadataOrder.append(identity)
            if metadataOrder.count > 64 { metadataCache.removeValue(forKey: metadataOrder.removeFirst()) }
        }
    }

    private static func setHeaders(on request: inout URLRequest, language: String) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(language, forHTTPHeaderField: "Accept-Language")
        request.setValue("IPHONE", forHTTPHeaderField: "X-Shazam-Platform")
        request.setValue("14.1.0", forHTTPHeaderField: "X-Shazam-AppVersion")
        request.setValue("Dalvik/2.1.0 (Linux; U; Android 5.0.2; VS980 4G Build/LRX22G)", forHTTPHeaderField: "User-Agent")
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let allowedAt = cooldownLock.withLock { retryDate }
        guard Date() >= allowedAt else { throw MusicMatcherError.rateLimited(until: allowedAt) }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw MusicMatcherError.invalidResponse }
        if response.statusCode == 429 {
            let now = Date()
            var delay: TimeInterval = 60
            if let header = response.value(forHTTPHeaderField: "Retry-After") {
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
            let until = now.addingTimeInterval(delay)
            cooldownLock.withLock { retryDate = until }
            throw MusicMatcherError.rateLimited(until: until)
        }
        guard (200..<300).contains(response.statusCode) else { throw MusicMatcherError.http(response.statusCode) }
        return data
    }

    static func localizedFallback(_ data: Data, for match: MusicMatch) throws -> MusicMatch? {
        guard let details = try localizedMetadata(data, for: match) else { return nil }
        return applying(details, to: match)
    }

    private static func localizedMetadata(_ data: Data, for match: MusicMatch) throws -> SongMetadata? {
        let track = try JSONDecoder().decode(RecognitionResponse.Track.self, from: data)
        guard let key = match.catalogKey, !key.isEmpty, track.key == key,
              !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !track.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let album = track.sections?.filter { $0.type == "SONG" }.flatMap { $0.metadata ?? [] }
            .first { ["专辑", "專輯", "Album"].contains($0.title ?? "") }?.text
        return SongMetadata(title: track.title, artist: track.subtitle, album: album,
                            duration: nil, titleAliases: [track.title], artistAliases: [track.subtitle])
    }

    static func applying(_ details: SongMetadata, to match: MusicMatch) -> MusicMatch {
        var result = MusicMatch(title: details.title, artist: details.artist, duration: details.duration ?? match.duration,
                                position: match.position, matchedAt: match.matchedAt)
        result.appleMusicID = match.appleMusicID
        result.catalogKey = match.catalogKey
        result.album = details.album
        result.titleAliases = Array(Set([match.title] + match.titleAliases + details.titleAliases)).sorted()
        result.artistAliases = Array(Set([match.artist] + match.artistAliases + details.artistAliases)).sorted()
        return result
    }

    /// macOS 27 wraps the wire packet in a version 2 SHSignature container.
    /// Fail closed on unknown containers, rather than relying on an arbitrary magic-byte search.
    static func rawSignature(from data: Data) throws -> Data {
        func word(_ bytes: Data, _ offset: Int) -> UInt32? {
            guard offset >= 0, bytes.count >= offset + 4 else { return nil }
            return bytes[offset..<offset + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        }
        let payload: Data
        if word(data, 0) == 0x25802580 {
            guard word(data, 4) == 2, word(data, 8) == 12, data.count > 12 else { throw MusicMatcherError.unsupportedSignature }
            payload = Data(data.dropFirst(12))
        } else {
            payload = data
        }
        guard payload.count >= 56, let magic = word(payload, 0), [UInt32(0xcafe2580), UInt32(0xb8709880)].contains(magic),
              let size = word(payload, 8), Int(size) + 48 == payload.count else { throw MusicMatcherError.unsupportedSignature }
        return payload
    }

    static func decodeResponse(_ data: Data, sampleDuration: Double, captureEnd: Date) throws -> MusicMatch? {
        let response = try JSONDecoder().decode(RecognitionResponse.self, from: data)
        guard let first = response.matches.first else { return nil }
        // A noticeably shifted match cannot safely drive a normal-speed lyric clock.
        for skew in [first.timeskew, first.frequencyskew].compactMap({ $0 }) {
            guard skew.isFinite, abs(skew) <= 0.01 else { return nil }
        }
        guard let track = response.track, !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MusicMatcherError.invalidResponse
        }
        let position = first.offset.flatMap { $0.isFinite ? max(0, $0 + sampleDuration) : nil }
        var result = MusicMatch(title: track.title, artist: track.subtitle, duration: nil, position: position, matchedAt: captureEnd)
        result.catalogKey = track.key
        result.appleMusicID = track.hub?.actions?.first(where: {
            $0.type == "applemusicplay" && !($0.id ?? "").isEmpty && ($0.id ?? "").allSatisfy { $0.isASCII && $0.isNumber }
        })?.id
        return result
    }
}

private struct RecognitionResponse: Decodable {
    struct Match: Decodable { let offset: Double?; let timeskew: Double?; let frequencyskew: Double? }
    struct Track: Decodable {
        struct Hub: Decodable {
            struct Action: Decodable { let type: String?; let id: String? }
            let actions: [Action]?
        }
        struct Section: Decodable {
            struct Metadata: Decodable { let title: String?; let text: String? }
            let type: String?
            let metadata: [Metadata]?
        }
        let sections: [Section]?
        let title: String
        let subtitle: String
        let key: String?
        let hub: Hub?
    }
    let matches: [Match]
    let track: Track?
}

enum MusicMatcherError: LocalizedError {
    case invalidAudio
    case unsupportedSignature
    case invalidResponse
    case http(Int)
    case rateLimited(until: Date)

    var errorDescription: String? {
        switch self {
        case .invalidAudio: return "音乐识别需要 3–12 秒的单声道音频。"
        case .unsupportedSignature: return "此系统的音乐指纹格式暂不支持；可以手动搜索歌词。"
        case .invalidResponse: return "音乐识别服务返回了无效响应。"
        case .http(let code): return "音乐识别服务暂时不可用（HTTP \(code)）；可以手动搜索歌词。"
        case .rateLimited(let until): return "识曲服务限流，约 \(String(format: "%.0f", max(1, ceil(until.timeIntervalSinceNow)))) 秒后重试；可以手动搜索歌词。"
        }
    }
}
