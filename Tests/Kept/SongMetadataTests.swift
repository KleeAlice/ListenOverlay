import Foundation

private final class MetadataStubProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, Data))?
    private static let lock = NSLock()
    private static var storedRequests: [URLRequest] = []
    static var requests: [URLRequest] {
        get { lock.withLock { storedRequests } }
        set { lock.withLock { storedRequests = newValue } }
    }
    static var waitsForCancellation = false
    private static var stoppedPendingRequests = 0
    static var cancellationCount: Int {
        get { lock.withLock { stoppedPendingRequests } }
        set { lock.withLock { stoppedPendingRequests = newValue } }
    }
    private var isAwaitingCancellation = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let waits = Self.waitsForCancellation
        Self.lock.withLock {
            isAwaitingCancellation = waits
            Self.storedRequests.append(request)
        }
        if waits { return }
        do {
            guard let respond = Self.respond else { throw URLError(.badServerResponse) }
            let (status, data) = try respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        Self.lock.withLock {
            // Completed/error fixtures may receive a late stop callback. Only
            // the deliberately suspended request is this test's cancellation.
            guard isAwaitingCancellation else { return }
            isAwaitingCancellation = false
            Self.stoppedPendingRequests += 1
        }
    }
}

@main
enum SongMetadataTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAIL: \(message)") }
    }

    static func stub(_ json: String, status: Int = 200) -> SongMetadataClient {
        MetadataStubProtocol.requests = []
        MetadataStubProtocol.waitsForCancellation = false
        MetadataStubProtocol.cancellationCount = 0
        MetadataStubProtocol.respond = { _ in (status, Data(json.utf8)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataStubProtocol.self]
        return SongMetadataClient(session: URLSession(configuration: configuration))
    }

    static func main() async throws {
        let exact = stub(#"{"results":[{"wrapperType":"track","kind":"song","trackId":535913714,"trackName":"晴天 (Live)","artistName":"周杰倫","collectionName":"2004 無與倫比演唱會 (Live)","trackTimeMillis":299360}]}"#)
        let metadata = try await exact.resolve(appleMusicID: "535913714")
        expect(metadata?.title == "晴天 (Live)", "exact Apple song ID supplies its localized title without losing version text")
        expect(metadata?.artist == "周杰倫", "exact Apple song ID supplies its localized artist")
        expect(metadata?.album == "2004 無與倫比演唱會 (Live)", "verified album is preserved")
        expect(metadata?.duration == 299.36, "Apple track milliseconds convert to precise seconds")
        expect(metadata?.titleAliases == ["晴天 (Live)"] && metadata?.artistAliases == ["周杰倫"], "only returned metadata becomes an alias")
        if let request = MetadataStubProtocol.requests.first {
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            expect(components.host == "itunes.apple.com" && components.path == "/lookup", "metadata uses only Apple's ID lookup endpoint")
            expect(query["id"] == "535913714" && query["country"] == "TW" && query["term"] == nil, "metadata uses an exact ID and Taiwan storefront, never a fuzzy search")
            expect(query["lang"] == nil, "undocumented zh_tw language parameter is not required for Taiwan metadata")
            expect(request.timeoutInterval > 0 && request.timeoutInterval <= 10, "optional metadata lookup has a bounded timeout")
        } else {
            expect(false, "an uncached song is looked up in Apple's catalog")
        }

        let cached = try await exact.resolve(appleMusicID: "535913714")
        expect(cached == metadata && MetadataStubProtocol.requests.count == 1, "successful exact-ID metadata is cached")

        let unrelated = stub(#"{"results":[{"wrapperType":"track","kind":"song","trackId":999,"trackName":"晴天 (Live)","artistName":"周杰倫"},{"wrapperType":"collection","kind":"song","trackId":535913714,"trackName":"晴天 (Live)","artistName":"周杰倫"},{"wrapperType":"track","kind":"music-video","trackId":535913714,"trackName":"晴天 (Live)","artistName":"周杰倫"}]}"#)
        let rejected = try await unrelated.resolve(appleMusicID: "535913714")
        expect(rejected == nil, "same text, wrong ID, albums and music videos cannot become verified song aliases")

        let aliases = stub(#"{"results":[{"wrapperType":"track","kind":"song","trackId":535913714,"trackName":" 晴天 (Live) ","artistName":"周杰倫"},{"wrapperType":"track","kind":"song","trackId":999,"trackName":"Unrelated","artistName":"Other Artist"},{"wrapperType":"track","kind":"song","trackId":535913714,"trackName":"Sunny Day (Live)","artistName":"Jay Chou"},{"wrapperType":"track","kind":"song","trackId":535913714,"trackName":"晴天 (Live)","artistName":"周杰倫"}]}"#)
        let variants = try await aliases.resolve(appleMusicID: "535913714")
        expect(variants?.title == "晴天 (Live)", "first verified result provides the display title after whitespace cleanup")
        expect(variants?.titleAliases == ["晴天 (Live)", "Sunny Day (Live)"], "same-ID title aliases are unique in response order")
        expect(variants?.artistAliases == ["周杰倫", "Jay Chou"], "same-ID artist aliases are unique in response order")

        for duration in ["0", "-1000", "null"] {
            let invalidDuration = stub("{\"results\":[{\"wrapperType\":\"track\",\"kind\":\"song\",\"trackId\":535913714,\"trackName\":\"晴天 (Live)\",\"artistName\":\"周杰倫\",\"trackTimeMillis\":\(duration)}]}")
            let result = try await invalidDuration.resolve(appleMusicID: "535913714")
            expect(result != nil && result?.duration == nil, "non-positive or missing duration \(duration) is not used as song duration")
        }
        for duration in ["1e999", "\"NaN\"", "\"Infinity\""] {
            let nonfinite = stub("{\"results\":[{\"wrapperType\":\"track\",\"kind\":\"song\",\"trackId\":535913714,\"trackName\":\"晴天 (Live)\",\"artistName\":\"周杰倫\",\"trackTimeMillis\":\(duration)}]}")
            do {
                let result = try await nonfinite.resolve(appleMusicID: "535913714")
                expect(result?.duration == nil, "nonfinite duration \(duration) is never accepted")
            } catch is DecodingError {
                // Invalid JSON numeric values may also fail the whole optional lookup.
            }
        }

        let invalidIdentity = stub(#"{"results":[{"wrapperType":"track","kind":"song","trackId":535913714,"trackName":" ","artistName":"周杰倫"},{"wrapperType":"track","kind":"song","trackId":535913714,"trackName":"晴天","artistName":""}]}"#)
        expect(try await invalidIdentity.resolve(appleMusicID: "535913714") == nil, "blank titles or artists never create incomplete identities")

        let invalidIDs = stub(#"{"results":[]}"#)
        for id in ["", "0", "-1", "535913714,999", "535913714&country=US", "五三五", "999999999999999999999999"] {
            let result = try await invalidIDs.resolve(appleMusicID: id)
            expect(result == nil, "invalid ID is rejected: \(id)")
        }
        expect(MetadataStubProtocol.requests.isEmpty, "invalid IDs never trigger catalog traffic")

        let missing = stub(#"{"results":[]}"#)
        expect(try await missing.resolve(appleMusicID: "535913714") == nil, "empty lookup means metadata is unavailable")
        _ = try await missing.resolve(appleMusicID: "535913714")
        expect(MetadataStubProtocol.requests.count == 2, "unavailable metadata is not cached as a permanent failure")
        let notFound = stub("not found", status: 404)
        expect(try await notFound.resolve(appleMusicID: "535913714") == nil, "HTTP 404 means metadata is unavailable")

        let serverError = stub("unavailable", status: 503)
        do {
            _ = try await serverError.resolve(appleMusicID: "535913714")
            expect(false, "HTTP service errors must throw")
        } catch { }
        let networkError = stub("")
        MetadataStubProtocol.respond = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await networkError.resolve(appleMusicID: "535913714")
            expect(false, "network failure must throw")
        } catch {
            expect((error as? URLError)?.code == .notConnectedToInternet, "network errors retain their original identity")
        }

        let cancelledClient = stub(#"{"results":[]}"#)
        MetadataStubProtocol.waitsForCancellation = true
        let cancelled = Task { try await cancelledClient.resolve(appleMusicID: "535913714") }
        for _ in 0..<100 where MetadataStubProtocol.requests.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(!MetadataStubProtocol.requests.isEmpty, "the cancellation fixture starts its network request")
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            expect(false, "cancellation must not complete as an unavailable lookup")
        } catch {
            expect(error is CancellationError || (error as? URLError)?.code == .cancelled, "cancellation is propagated")
        }
        // The cancelled async task can resume before URLProtocol receives its
        // stop callback. Wait for that observable event, not scheduler ordering.
        for _ in 0..<100 where MetadataStubProtocol.cancellationCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(MetadataStubProtocol.cancellationCount == 1, "cancelling metadata lookup cancels its network request")

        if failures > 0 { print("\(failures) song metadata tests failed"); exit(1) }
        print("All song metadata tests passed")
    }
}
