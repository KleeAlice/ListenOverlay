import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private final class ArtworkStub: URLProtocol {
    struct Reply {
        var status = 200
        var data = Data()
        var headers: [String: String] = [:]
        var wait = false
        var redirect: URL?
    }
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Reply)!
    private static var seen: [URLRequest] = []
    private static var stops = 0
    static func reset(_ body: @escaping (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        handler = body; seen = []; stops = 0
    }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    static var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        let body = Self.handler!
        Self.lock.unlock()
        let reply = body(request)
        if reply.wait { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: nil, headerFields: reply.headers)!
        if let redirect = reply.redirect {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.lock.lock(); Self.stops += 1; Self.lock.unlock()
    }
}

@main struct AlbumArtworkTests {
    static var checks = 0
    static var failures = 0
    static let redURL = "https://p1.music.126.net/fixture/red.png"
    static let blueURL = "https://is1-ssl.mzstatic.com/image/fixture/100x100bb.jpg"
    static func expect(_ value: Bool, _ message: String) {
        checks += 1
        if !value { failures += 1; print("FAIL: \(message)") }
    }
    static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    static func song(_ id: Int64 = 42, art: String? = redURL) -> [String: Any] {
        ["id": id, "album": art.map { ["picUrl": $0] } ?? [:]]
    }
    static func apple(_ id: Int64 = 42, art: String? = blueURL, wrapper: String = "track", kind: String = "song") -> [String: Any] {
        var row: [String: Any] = ["trackId": id, "wrapperType": wrapper, "kind": kind]
        if let art { row["artworkUrl100"] = art }; return row
    }
    private static func service(_ body: @escaping (URLRequest) -> ArtworkStub.Reply) -> AlbumArtworkClient {
        ArtworkStub.reset(body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkStub.self]
        return AlbumArtworkClient(session: URLSession(configuration: configuration))
    }
    static func fixture(width: Int = 32, height: Int = 32, color: (UInt8, UInt8, UInt8, UInt8),
                        rightQuarter: (UInt8, UInt8, UInt8, UInt8)? = nil) -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let pixel = (offset / 4) % width >= width * 3 / 4 ? (rightQuarter ?? color) : color
            pixels[offset] = pixel.0; pixels[offset + 1] = pixel.1
            pixels[offset + 2] = pixel.2; pixels[offset + 3] = pixel.3
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
    static func expectError(_ message: String, _ action: () async throws -> AlbumArtwork?) async {
        do { _ = try await action(); expect(false, message) }
        catch { expect(!(error is CancellationError), message) }
    }
    static func liveProbe() async throws {
        let client = AlbumArtworkClient()
        var rows: [[String: Any]] = []
        for id: Int64 in [185709, 185956] {
            let started = Date()
            guard let artwork = try await client.load(.netEase(id)) else {
                throw NSError(domain: "AlbumArtworkTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "No cover for \(id)"])
            }
            let elapsed = Date().timeIntervalSince(started)
            let source = CGImageSourceCreateWithData(artwork.imageData as CFData, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
            rows.append(["provider": "netEase", "requestedSongID": id, "dominantHex": artwork.dominantHex,
                         "thumbnailBytes": artwork.imageData.count, "elapsedSeconds": elapsed,
                         "width": properties[kCGImagePropertyPixelWidth]!, "height": properties[kCGImagePropertyPixelHeight]!])
        }
        let report: [String: Any] = ["checkedAt": ISO8601DateFormatter().string(from: Date()),
            "scope": "Direct production artwork-client network probe; not player or UI integration. No audio or lyrics requested.",
            "results": rows, "distinctColors": Set(rows.compactMap { $0["dominantHex"] as? String }).count == 2]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
    static func main() async throws {
        if CommandLine.arguments.contains("--live-artwork") { try await liveProbe(); return }
        let red = fixture(color: (230, 32, 32, 255))
        let blue = fixture(color: (30, 60, 220, 255))
        var client = service { request in
            if request.url!.host == "music.163.com" {
                return .init(data: json(["code": 200, "songs": [song()]]))
            }
            return .init(data: red)
        }
        let redArt = try await client.load(.netEase(42))
        expect(redArt?.dominantHex == "E62020", "known red image retains its dominant RGB color")
        expect(redArt?.imageData.isEmpty == false, "verified artwork returns decodable image bytes")
        expect(ArtworkStub.requests.count == 2, "one exact detail request and one image request")
        if let request = ArtworkStub.requests.first {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.path == "/api/song/detail/" && query.contains(.init(name: "id", value: "42"))
                && query.contains(.init(name: "ids", value: "[42]")), "NetEase uses exact ID detail endpoint")
        }
        let reused = try await client.load(.netEase(42))
        expect(reused?.dominantHex == redArt?.dominantHex && ArtworkStub.requests.count == 2,
               "same verified catalog ID reuses bounded memory cache")
        expect(ArtworkStub.requests.allSatisfy { !$0.httpShouldHandleCookies && $0.timeoutInterval <= 8 },
               "each network request disables cookies and carries a short timeout")
        client = service { request in
            if request.url!.host == "itunes.apple.com" {
                return .init(data: json(["resultCount": 1, "results": [apple()]]))
            }
            return .init(data: blue)
        }
        let blueArt = try await client.load(.apple(42))
        expect(blueArt?.dominantHex == "1E3CDC", "known blue image yields a distinct stable color")
        expect(ArtworkStub.requests.first?.url?.path == "/lookup", "Apple artwork uses ID lookup")
        for row in [song(43), song(42, art: nil)] {
            client = service { _ in .init(data: json(["code": 200, "songs": [row]])) }
            expect(try await client.load(.netEase(42)) == nil, "wrong NetEase ID or missing art returns nil")
            expect(ArtworkStub.requests.count == 1, "unverified or missing artwork never downloads an image")
        }
        client = service { request in
            if request.url!.host == "music.163.com" {
                return .init(data: json(["code": 200, "songs": [song(42, art: ArtworkStub.requests.count == 1 ? nil : redURL)]]))
            }
            return .init(data: red)
        }
        expect(try await client.load(.netEase(42)) == nil, "initial missing artwork returns nil")
        expect(try await client.load(.netEase(42))?.dominantHex == "E62020" && ArtworkStub.requests.count == 3,
               "explicit retry can recover artwork after an earlier missing response")
        for url in ["http://p1.music.126.net/a.png", "https://p1.music.126.net.evil.test/a.png",
                    "https://evil.test/music.126.net/a.png", "file:///tmp/a.png", "not a URL",
                    "https://user@p1.music.126.net/a.png", "https://p1.music.126.net:444/a.png"] {
            client = service { _ in .init(data: json(["code": 200, "songs": [song(42, art: url)]])) }
            expect(try await client.load(.netEase(42)) == nil, "untrusted or malformed image URL is rejected: \(url)")
            expect(ArtworkStub.requests.count == 1, "rejected URL never triggers a fetch")
        }
        for row in [apple(43), apple(42, wrapper: "collection"), apple(42, kind: "music-video"), apple(42, art: nil)] {
            client = service { _ in .init(data: json(["resultCount": 1, "results": [row]])) }
            expect(try await client.load(.apple(42)) == nil, "Apple requires exact track ID, track wrapper, song kind, and art")
            expect(ArtworkStub.requests.allSatisfy { $0.url!.host == "itunes.apple.com" }, "invalid Apple row never downloads artwork")
        }
        client = service { request in
            if request.url!.host == "itunes.apple.com" {
                let country = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "country" }?.value
                return .init(data: json(["results": country == "TW" ? [] : [apple()]]))
            }
            return .init(data: blue)
        }
        expect(try await client.load(.apple(42))?.dominantHex == "1E3CDC", "Apple retries the same ID in US when TW has no artwork")
        expect(ArtworkStub.requests.count == 3, "Apple fallback is bounded to two exact storefront lookups")
        client = service { _ in .init(status: 503) }
        await expectError("HTTP service failure throws") { try await client.load(.netEase(42)) }
        client = service { _ in .init(data: json(["code": 503, "songs": []])) }
        await expectError("NetEase application failure throws") { try await client.load(.netEase(42)) }
        client = service { _ in .init(data: Data("broken json".utf8)) }
        await expectError("malformed metadata throws") { try await client.load(.netEase(42)) }
        client = service { _ in .init(data: Data(repeating: 32, count: 524_289)) }
        await expectError("metadata response byte limit is enforced") { try await client.load(.netEase(42)) }
        client = service { request in
            request.url!.host == "music.163.com" ? .init(data: json(["code": 200, "songs": [song()]]))
                : .init(data: Data(repeating: 0, count: 4_194_305))
        }
        await expectError("artwork byte limit is enforced even without Content-Length") { try await client.load(.netEase(42)) }
        client = service { request in
            request.url!.host == "music.163.com" ? .init(data: json(["code": 200, "songs": [song()]]))
                : .init(data: red, headers: ["Content-Length": "4194305"])
        }
        await expectError("declared oversized artwork is rejected") { try await client.load(.netEase(42)) }
        let wide = fixture(width: 8193, height: 1, color: (230, 32, 32, 255))
        client = service { request in
            request.url!.host == "music.163.com" ? .init(data: json(["code": 200, "songs": [song()]])) : .init(data: wide)
        }
        await expectError("oversized source dimensions fail before thumbnail sampling") { try await client.load(.netEase(42)) }
        let excessivePixels = fixture(width: 4097, height: 4097, color: (230, 32, 32, 255))
        client = service { request in
            request.url!.host == "music.163.com" ? .init(data: json(["code": 200, "songs": [song()]])) : .init(data: excessivePixels)
        }
        await expectError("pixel budget rejects a source whose individual sides are within bounds") { try await client.load(.netEase(42)) }
        let larger = fixture(width: 512, height: 512, color: (230, 32, 32, 255))
        client = service { request in
            request.url!.host == "music.163.com" ? .init(data: json(["code": 200, "songs": [song()]])) : .init(data: larger)
        }
        let scaled = try await client.load(.netEase(42))!
        let scaledSource = CGImageSourceCreateWithData(scaled.imageData as CFData, nil)!
        let scaledImage = CGImageSourceCreateImageAtIndex(scaledSource, 0, nil)!
        expect(scaledImage.width == 256 && scaledImage.height == 256, "display image is downsampled to a bounded PNG")
        client = service { request in
            request.url!.host == "music.163.com" ? .init(data: json(["code": 200, "songs": [song()]]))
                : .init(data: Data("not an image".utf8))
        }
        await expectError("non-image body is rejected") { try await client.load(.netEase(42)) }
        client = service { request in
            request.url!.host == "music.163.com" ? .init(data: json(["code": 200, "songs": [song()]]))
                : .init(status: 302, redirect: URL(string: "https://untrusted.test/cover.png")!)
        }
        await expectError("artwork redirect cannot escape the trusted CDN allowlist") { try await client.load(.netEase(42)) }
        expect(ArtworkStub.requests.allSatisfy { $0.url!.host != "untrusted.test" }, "untrusted redirects never reach the network")
        for (fixtureData, message) in [
            (fixture(color: (230, 32, 32, 255), rightQuarter: (30, 60, 220, 255)), "dominant bin chooses a red majority instead of averaging it with blue"),
            (fixture(color: (0, 0, 0, 0), rightQuarter: (230, 32, 32, 255)), "transparent majority is excluded from color voting")
        ] {
            client = service { request in
                request.url!.host == "music.163.com" ? .init(data: json(["code": 200, "songs": [song()]])) : .init(data: fixtureData)
            }
            expect(try await client.load(.netEase(42))?.dominantHex == "E62020", message)
        }
        for (color, expected) in [((128 as UInt8, 128 as UInt8, 128 as UInt8, 255 as UInt8), "808080"),
                                  ((0, 0, 0, 0), "808080")] {
            let data = fixture(color: color)
            client = service { request in
                request.url!.host == "music.163.com" ? .init(data: json(["code": 200, "songs": [song()]])) : .init(data: data)
            }
            expect(try await client.load(.netEase(42))?.dominantHex == expected,
                   "grayscale and fully transparent images have a sensible neutral result")
        }
        client = service { _ in .init(wait: true) }
        let cancellationClient = client
        let pending = Task { try await cancellationClient.load(.netEase(42)) }
        for _ in 0..<100 where ArtworkStub.requests.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        pending.cancel()
        do { _ = try await pending.value; expect(false, "cancelled load must throw") }
        catch { expect(error is CancellationError || (error as? URLError)?.code == .cancelled,
                       "cancellation propagates without becoming missing artwork") }
        expect(ArtworkStub.stopCount > 0, "cancellation stops the pending network request")
        client = service { request in
            if request.url!.host == "music.163.com" {
                let id = Int64(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "id" }!.value!)!
                return .init(data: json(["code": 200, "songs": [song(id)]]))
            }
            return .init(data: red)
        }
        for id in 1...24 { _ = try await client.load(.netEase(Int64(id))) }
        _ = try await client.load(.netEase(1))
        expect(ArtworkStub.requests.count == 48, "24 cached covers fit without a repeated request")
        _ = try await client.load(.netEase(25))
        _ = try await client.load(.netEase(1))
        expect(ArtworkStub.requests.count == 50, "recently accessed cover survives least-recently-used eviction")
        _ = try await client.load(.netEase(2))
        expect(ArtworkStub.requests.count == 52, "25th cover evicts the least-recently-used cache entry")
        client = service { _ in .init(status: 503) }
        expect(try await client.load(.netEase(0)) == nil && ArtworkStub.requests.isEmpty, "nonpositive IDs never request a catalog")
        if failures > 0 { print("\(failures) of \(checks) album artwork checks failed"); exit(1) }
        print("All \(checks) album artwork checks passed")
    }
}
