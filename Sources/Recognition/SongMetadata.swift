import Foundation

struct SongMetadata: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String?
    let duration: Double?
    let titleAliases: [String]
    let artistAliases: [String]
}

actor SongMetadataClient {
    private let session: URLSession
    private var cache: [Int64: SongMetadata] = [:]

    init(session: URLSession = .shared) { self.session = session }

    /// Enrich only a recognized Apple song ID; a text search cannot establish identity.
    func resolve(appleMusicID: String) async throws -> SongMetadata? {
        try Task.checkCancellation()
        guard !appleMusicID.isEmpty,
              appleMusicID.utf8.allSatisfy({ (48...57).contains($0) }),
              let trackID = Int64(appleMusicID), trackID > 0 else { return nil }
        if let cached = cache[trackID] { return cached }

        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        // The Taiwan storefront supplies native Chinese names. Apple's documented
        // lang values are only en_us and ja_jp, so no undocumented lang is required.
        components.queryItems = [URLQueryItem(name: "id", value: String(trackID)),
                                 URLQueryItem(name: "country", value: "TW")]
        var request = URLRequest(url: components.url!, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-TW", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw SongMetadataError.invalidResponse }
        if response.statusCode == 404 { return nil }
        guard (200..<300).contains(response.statusCode) else { throw SongMetadataError.http(response.statusCode) }

        let decoded = try JSONDecoder().decode(SongMetadataResponse.self, from: data)
        let tracks = decoded.results.filter {
            $0.trackId == trackID && $0.wrapperType == "track" && $0.kind == "song"
                && Self.nonempty($0.trackName) != nil && Self.nonempty($0.artistName) != nil
        }
        guard let first = tracks.first,
              let title = Self.nonempty(first.trackName), let artist = Self.nonempty(first.artistName) else { return nil }
        let duration = first.trackTimeMillis.flatMap { milliseconds -> Double? in
            let seconds = milliseconds / 1000
            return seconds.isFinite && seconds > 0 ? seconds : nil
        }
        let metadata = SongMetadata(title: title, artist: artist, album: Self.nonempty(first.collectionName),
                                    duration: duration,
                                    titleAliases: Self.unique(tracks.compactMap { Self.nonempty($0.trackName) }),
                                    artistAliases: Self.unique(tracks.compactMap { Self.nonempty($0.artistName) }))
        try Task.checkCancellation()
        cache[trackID] = metadata
        return metadata
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private struct SongMetadataResponse: Decodable {
    struct Track: Decodable {
        let wrapperType: String?
        let kind: String?
        let trackId: Int64?
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let trackTimeMillis: Double?
    }
    let results: [Track]
}

enum SongMetadataError: Error {
    case invalidResponse
    case http(Int)
}
