import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum AlbumArtworkReference: Hashable, Sendable {
    case netEase(Int64)
    case apple(Int64)
}

struct AlbumArtwork: Sendable {
    let imageData: Data
    let dominantHex: String
}

actor AlbumArtworkClient {
    private struct Cached {
        let artwork: AlbumArtwork
        var access: UInt64
    }
    private let session: URLSession
    private var cache: [AlbumArtworkReference: Cached] = [:]
    private var access: UInt64 = 0
    private var cacheBytes = 0

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: configuration)
    }

    func load(_ reference: AlbumArtworkReference) async throws -> AlbumArtwork? {
        try Task.checkCancellation()
        access &+= 1
        if var entry = cache[reference] {
            entry.access = access; cache[reference] = entry
            return entry.artwork
        }
        let url: URL?
        switch reference {
        case .netEase(let id):
            guard id > 0 else { return nil }
            url = try await netEaseURL(id: id)
        case .apple(let id):
            guard id > 0 else { return nil }
            url = try await appleURL(id: id)
        }
        try Task.checkCancellation()
        var artwork: AlbumArtwork?
        if let url {
            let data = try await fetch(url, limit: 4 * 1_024 * 1_024, policy: .artwork)
            try Task.checkCancellation()
            artwork = try Self.decode(data)
        }
        try Task.checkCancellation()
        if let artwork { remember(artwork, for: reference) }
        return artwork
    }

    private func remember(_ artwork: AlbumArtwork, for reference: AlbumArtworkReference) {
        // The store deduplicates polling; leaving misses uncached permits explicit retries.
        cacheBytes -= cache.removeValue(forKey: reference)?.artwork.imageData.count ?? 0
        while cache.count >= 24 || cacheBytes + artwork.imageData.count > 8 * 1_024 * 1_024 {
            guard let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key else { break }
            cacheBytes -= cache.removeValue(forKey: oldest)?.artwork.imageData.count ?? 0
        }
        access &+= 1
        cache[reference] = Cached(artwork: artwork, access: access)
        cacheBytes += artwork.imageData.count
    }

    private struct NetEaseReply: Decodable {
        struct Song: Decodable {
            struct Album: Decodable { let picUrl: String? }
            let id: Int64
            let album: Album?
        }
        let code: Int
        let songs: [Song]?
    }

    private func netEaseURL(id: Int64) async throws -> URL? {
        var components = URLComponents(string: "https://music.163.com/api/song/detail/")!
        components.queryItems = [.init(name: "id", value: String(id)), .init(name: "ids", value: "[\(id)]")]
        let data = try await fetch(components.url!, limit: 512 * 1_024, policy: .netEase)
        let reply = try JSONDecoder().decode(NetEaseReply.self, from: data)
        guard reply.code == 200 else { throw AlbumArtworkError.invalidResponse }
        let matches = (reply.songs ?? []).filter { $0.id == id }
        guard matches.count == 1, let raw = matches.first?.album?.picUrl else { return nil }
        return Self.artworkURL(raw)
    }

    private struct AppleReply: Decodable {
        struct Track: Decodable {
            let trackId: Int64?
            let wrapperType: String?
            let kind: String?
            let artworkUrl100: String?
        }
        let results: [Track]
    }

    private func appleURL(id: Int64) async throws -> URL? {
        for country in ["TW", "US"] {
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            components.queryItems = [.init(name: "id", value: String(id)), .init(name: "country", value: country)]
            let data = try await fetch(components.url!, limit: 512 * 1_024, policy: .apple)
            let reply = try JSONDecoder().decode(AppleReply.self, from: data)
            let matches = reply.results.filter { $0.trackId == id && $0.wrapperType == "track" && $0.kind == "song" }
            guard matches.count <= 1 else { return nil }
            if let raw = matches.first?.artworkUrl100, let url = Self.artworkURL(raw) { return url }
        }
        return nil
    }

    private static func artworkURL(_ raw: String) -> URL? {
        guard raw.count <= 2_048, let url = URL(string: raw), ArtworkURLPolicy.artwork.allows(url) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if url.host!.lowercased().hasSuffix(".music.126.net") {
            var query = components.queryItems?.filter { $0.name != "param" } ?? []
            query.append(.init(name: "param", value: "256y256")); components.queryItems = query
        } else if components.path.hasSuffix("/100x100bb.jpg") {
            components.path = String(components.path.dropLast("100x100bb.jpg".count)) + "256x256bb.jpg"
        }
        return components.url
    }

    private func fetch(_ url: URL, limit: Int, policy: ArtworkURLPolicy) async throws -> Data {
        try Task.checkCancellation()
        guard policy.allows(url) else { throw AlbumArtworkError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpShouldHandleCookies = false
        let delegate = ArtworkRedirectDelegate(policy: policy)
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, let finalURL = http.url,
              policy.allows(finalURL), (200..<300).contains(http.statusCode) else {
            throw AlbumArtworkError.invalidResponse
        }
        guard response.expectedContentLength <= Int64(limit) else { throw AlbumArtworkError.responseTooLarge }
        var data = Data()
        data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < limit else { throw AlbumArtworkError.responseTooLarge }
            data.append(byte)
            if data.count % 16_384 == 0 { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        return data
    }

    private static func decode(_ data: Data) throws -> AlbumArtwork {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 8_192, height <= 8_192,
              width * height <= 16_777_216 else { throw AlbumArtworkError.invalidImage }
        func thumbnail(_ size: Int) -> CGImage? {
            CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: size
            ] as CFDictionary)
        }
        guard let sample = thumbnail(64), sample.width <= 64, sample.height <= 64,
              let display = thumbnail(256), display.width <= 256, display.height <= 256 else {
            throw AlbumArtworkError.invalidImage
        }
        let color = try dominantColor(sample)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw AlbumArtworkError.invalidImage
        }
        CGImageDestinationAddImage(destination, display, nil)
        guard CGImageDestinationFinalize(destination), output.length <= 1_024 * 1_024 else {
            throw AlbumArtworkError.invalidImage
        }
        return AlbumArtwork(imageData: output as Data, dominantHex: color)
    }

    private static func dominantColor(_ image: CGImage) throws -> String {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw AlbumArtworkError.invalidImage }
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw AlbumArtworkError.invalidImage }
        struct Bin {
            var count = 0
            var red = 0
            var green = 0
            var blue = 0
        }
        var bins = [Bin](repeating: Bin(), count: 4_096)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            guard alpha >= 128 else { continue }
            let red = min(255, (Int(pixels[offset]) * 255 + alpha / 2) / alpha)
            let green = min(255, (Int(pixels[offset + 1]) * 255 + alpha / 2) / alpha)
            let blue = min(255, (Int(pixels[offset + 2]) * 255 + alpha / 2) / alpha)
            let index = ((red >> 4) << 8) | ((green >> 4) << 4) | (blue >> 4)
            bins[index].count += 1
            bins[index].red += red; bins[index].green += green; bins[index].blue += blue
        }
        // Ascending bins and a strict comparison give ties a stable result.
        var winner = Bin()
        for bin in bins where bin.count > winner.count { winner = bin }
        guard winner.count > 0 else { return "808080" }
        return String(format: "%02X%02X%02X", (winner.red + winner.count / 2) / winner.count,
                      (winner.green + winner.count / 2) / winner.count, (winner.blue + winner.count / 2) / winner.count)
    }
}

private enum AlbumArtworkError: Error {
    case invalidResponse
    case responseTooLarge
    case invalidImage
}

private enum ArtworkURLPolicy: Sendable {
    case netEase, apple, artwork
    func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { return false }
        switch self {
        case .netEase: return host == "music.163.com"
        case .apple: return host == "itunes.apple.com"
        case .artwork: return host.hasSuffix(".music.126.net") || host.hasSuffix(".mzstatic.com")
        }
    }
}

private final class ArtworkRedirectDelegate: NSObject, URLSessionTaskDelegate {
    let policy: ArtworkURLPolicy
    init(policy: ArtworkURLPolicy) { self.policy = policy }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, policy.allows(url) else { completionHandler(nil); return }
        var clean = request
        clean.httpShouldHandleCookies = false
        clean.setValue(nil, forHTTPHeaderField: "Cookie")
        clean.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(clean)
    }
}
