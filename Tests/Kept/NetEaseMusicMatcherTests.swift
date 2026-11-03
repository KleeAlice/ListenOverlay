import Foundation

private final class NetEaseStubProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Data, URLResponse))?
    static var requests: [URLRequest] = []
    static var stalled = false
    static var cancellations = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (handler, stalled) = Self.lock.withLock {
            Self.requests.append(request)
            return (Self.handler, Self.stalled)
        }
        if stalled { return }
        do {
            guard let handler else { throw URLError(.badServerResponse) }
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { Self.lock.withLock { Self.cancellations += 1 } }
    static var count: Int { lock.withLock { requests.count } }

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }
}

@main
enum NetEaseMusicMatcherTests {
    static var failures = 0
    static var checks = 0
    static let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    static let first = #"{"startTime":44980,"song":{"id":185821,"name":"最长的电影","artists":[{"name":"周杰伦"}],"album":{"name":"我很忙"},"duration":235840}}"#

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures += 1; print("FAIL: \(message)") }
    }

    static func fingerprint(value: String = "+/8=", duration: Double = 6, capturedAt: Date = anchor) -> NetEaseFingerprint {
        NetEaseFingerprint(value: value, duration: duration, capturedAt: capturedAt)
    }

    static func response(_ candidates: String) -> String { "{\"code\":200,\"data\":{\"result\":[\(candidates)]}}" }

    static func stub(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> NetEaseMusicMatcher {
        NetEaseStubProtocol.lock.withLock {
            NetEaseStubProtocol.requests = []
            NetEaseStubProtocol.stalled = false
            NetEaseStubProtocol.cancellations = 0
            NetEaseStubProtocol.handler = { request in
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetEaseStubProtocol.self]
        return NetEaseMusicMatcher(session: URLSession(configuration: configuration))
    }

    static func expectInvalidResponse(_ body: String, _ message: String) async {
        let matcher = stub(body)
        do {
            _ = try await matcher.recognize(fingerprint: fingerprint())
            expect(false, message)
        } catch MusicMatcherError.invalidResponse { expect(true, message) }
        catch { expect(false, "\(message): unexpected error \(error)") }
    }

    static func serviceRateLimitScenario() async throws {
        let client = stub(#"{"code":429,"message":"too many requests"}"#)
        let before = Date()
        var deadline: Date?
        do { _ = try await client.recognize(fingerprint: fingerprint()); expect(false, "service code 429 creates a cooldown") }
        catch MusicMatcherError.rateLimited(let until) {
            deadline = until
            expect(until >= before.addingTimeInterval(60), "service code 429 gets at least a minute cooldown")
        } catch { expect(false, "service code 429 is a rate-limit error rather than a generic service error") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetEaseStubProtocol.self]
        let another = NetEaseMusicMatcher(session: URLSession(configuration: configuration))
        do { _ = try await another.recognize(fingerprint: fingerprint()); expect(false, "service cooldown also blocks new instances") }
        catch MusicMatcherError.rateLimited(let until) { expect(until == deadline, "service code 429 shares the deadline across instances") }
        catch { expect(false, "service cooldown retains the rate-limit error") }
        expect(NetEaseStubProtocol.count == 1, "service cooldown prevents every later network attempt")
    }

    static func finish() {
        if failures > 0 { print("\(failures) of \(checks) NetEase matcher checks failed"); exit(1) }
        print("All \(checks) NetEase matcher checks passed")
    }

    static func main() async throws {
        if CommandLine.arguments.contains("--service-rate-limit") {
            try await serviceRateLimitScenario()
            finish()
            return
        }
        let defaultConfiguration = NetEaseMusicMatcher.sessionConfiguration()
        expect(defaultConfiguration.urlCache == nil, "default session never uses a disk or memory URL cache")
        expect(defaultConfiguration.httpCookieStorage == nil && !defaultConfiguration.httpShouldSetCookies, "default session has no cookie storage")
        expect(defaultConfiguration.urlCredentialStorage == nil, "default session has no account credential storage")
        let matcher = stub(response(first))
        let match = try await matcher.recognize(fingerprint: fingerprint())
        expect(match?.title == "最长的电影" && match?.artist == "周杰伦" && match?.album == "我很忙", "native title, artist and album are retained")
        expect(match?.duration == 235.84, "song duration milliseconds convert to seconds")
        expect(abs((match?.position ?? -1) - 50.98) < 0.000_001, "position includes sample duration at capture end")
        expect(match?.matchedAt == anchor, "network response time never replaces the capture anchor")
        expect(match?.catalogKey == "netease:185821" && match?.identity == "netease:185821", "provider-prefixed IDs cannot collide with Shazam")
        expect(match?.appleMusicID == nil, "NetEase ID is not represented as an Apple catalog ID")
        expect(match?.titleAliases == ["最长的电影"] && match?.artistAliases == ["周杰伦"], "only returned native names become aliases")
        let request = NetEaseStubProtocol.lock.withLock { NetEaseStubProtocol.requests.first }
        if let request, let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let body = String(data: NetEaseStubProtocol.body(of: request), encoding: .utf8) ?? ""
            var form = URLComponents()
            form.percentEncodedQuery = body
            let query = Dictionary(uniqueKeysWithValues: (form.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            expect(components.scheme == "https" && components.host == "interface.music.163.com" && components.path == "/api/music/audio/match", "request uses the official extension's endpoint")
            expect(request.httpMethod == "POST" && components.query == nil, "request transmits the fingerprint in a form body, never in the URL")
            expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded; charset=UTF-8", "form content type follows the official extension")
            expect(query["rawdata"] == "+/8=" && body.contains("%2B") && body.contains("%2F") && body.contains("%3D"), "base64 plus, slash and padding are encoded and round-trip")
            expect(query["algorithmCode"] == "shazam_v2" && query["duration"] == "6" && query["times"] == "2" && query["decrypt"] == "1", "official fingerprint parameters are retained")
            expect(query["sessionId"].flatMap(UUID.init(uuidString:)) != nil && query.count == 6, "query contains a random session ID and no account or raw audio fields")
            expect(request.timeoutInterval > 0 && request.timeoutInterval <= 20, "recognition has a bounded timeout")
            expect(!request.httpShouldHandleCookies && request.value(forHTTPHeaderField: "Cookie") == nil, "recognition neither attaches nor accepts account cookies")
            expect(request.cachePolicy == .reloadIgnoringLocalCacheData, "recognition cannot reuse a cached playback position")
            expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store", "request explicitly forbids fingerprint response caching")
        } else { expect(false, "recognition produces a request") }

        let second = first.replacingOccurrences(of: "44980", with: "52980")
        let next = try await stub(response(second)).recognize(fingerprint: fingerprint(capturedAt: anchor.addingTimeInterval(8)))
        var confirmation = MusicConfirmation()
        expect(match.map { !confirmation.observe($0) } == true, "one provider result remains an unconfirmed candidate")
        expect(next.map { confirmation.observe($0) } == true, "independent excerpts with coherent offsets confirm the same recording")

        let wrongFirst = first.replacingOccurrences(of: "185821", with: "999").replacingOccurrences(of: "最长的电影", with: "Different Song (Live)")
        let ordered = try await stub(response(wrongFirst + "," + first)).recognize(fingerprint: fingerprint())
        expect(ordered?.catalogKey == "netease:999" && ordered?.title == "Different Song (Live)", "only top1 is returned even when a later candidate has the expected title")
        let ignoredLower = try await stub(response(first + ",null,{\"broken\":true}")).recognize(fingerprint: fingerprint())
        expect(ignoredLower?.catalogKey == "netease:185821", "malformed lower candidates are not decoded or selected")
        await expectInvalidResponse(response("null," + first), "invalid top1 never falls through to a valid later candidate")
        let collaborators = first.replacingOccurrences(of: #"[{"name":"周杰伦"}]"#, with: #"[{"name":"周杰伦"},{"name":"費玉清"}]"#)
            .replacingOccurrences(of: "最长的电影", with: "千里之外 (Live)")
        let collaboration = try await stub(response(collaborators)).recognize(fingerprint: fingerprint())
        expect(collaboration?.title == "千里之外 (Live)" && collaboration?.artist == "周杰伦 / 費玉清", "recording suffixes and all artists remain intact")
        let noAlbum = first.replacingOccurrences(of: #""album":{"name":"我很忙"},"#, with: "")
        expect(try await stub(response(noAlbum)).recognize(fingerprint: fingerprint())?.album == nil, "missing optional album does not invent one")
        for emptyName in ["", "  "] {
            let emptyAlbum = first.replacingOccurrences(of: "我很忙", with: emptyName)
            do {
                let result = try await stub(response(emptyAlbum)).recognize(fingerprint: fingerprint())
                expect(result?.album == nil && result?.catalogKey == "netease:185821", "empty optional album is unknown metadata, not a malformed identity")
            } catch { expect(false, "empty optional album should decode: \(error)") }
        }
        let aiCover = #"{"startTime":45120,"song":{"id":3439782604,"name":"【AIHANNI 范玉欣cover】搁浅 Step Aside","artists":[{"name":"cwjfyn"}],"album":{"id":0,"name":""},"duration":239513}}"#
        do {
            let result = try await stub(response(aiCover)).recognize(fingerprint: fingerprint())
            expect(result?.album == nil && result?.title == "【AIHANNI 范玉欣cover】搁浅 Step Aside" && result?.artist == "cwjfyn", "empty-album parsing preserves the real AI-cover identity for later rejection")
            expect(result?.catalogKey == "netease:3439782604" && abs((result?.position ?? -1) - 51.12) < 0.000_001, "empty-album parsing neither remaps the candidate nor rewrites its timeline")
        } catch { expect(false, "observed empty-album response should decode as an unconfirmed candidate: \(error)") }
        expect(try await stub(response("")).recognize(fingerprint: fingerprint()) == nil, "code 200 with an empty result is no match")

        for body in ["not json", "{}", #"{"code":200}"#, #"{"code":200,"data":{}}"#, #"{"code":200,"data":{"result":null}}"#] {
            await expectInvalidResponse(body, "malformed success response is rejected: \(body)")
        }
        let replacements: [(String, String)] = [
            (#""id":185821"#, #""id":0"#), (#""id":185821"#, #""id":-1"#),
            (#""id":185821"#, #""id":"185821""#), (#""id":185821"#, #""id":1.5"#),
            (#""name":"最长的电影""#, #""name":" ""#), (#""name":"周杰伦""#, #""name":" ""#),
            (#""artists":[{"name":"周杰伦"}]"#, #""artists":[]"#),
            (#""duration":235840"#, #""duration":0"#), (#""duration":235840"#, #""duration":-1"#),
            (#""duration":235840"#, #""duration":1e999"#), (#""duration":235840"#, #""duration":null"#),
            (#""startTime":44980"#, #""startTime":-1"#), (#""startTime":44980"#, #""startTime":1e999"#),
            (#""startTime":44980"#, #""startTime":null"#), (#""startTime":44980"#, #""startTime":235841"#),
            (#""startTime":44980"#, #""startTime":230000"#)
        ]
        for (old, new) in replacements {
            await expectInvalidResponse(response(first.replacingOccurrences(of: old, with: new)), "invalid top1 field is rejected: \(new)")
        }
        let lastSample = first.replacingOccurrences(of: "44980", with: "229840")
        expect(try await stub(response(lastSample)).recognize(fingerprint: fingerprint())?.position == 235.84, "sample ending exactly at song duration is valid")

        for invalid in [fingerprint(value: ""), fingerprint(value: "not base64!"), fingerprint(duration: 0), fingerprint(duration: -1),
                        fingerprint(duration: .nan), fingerprint(duration: .infinity), fingerprint(duration: 30),
                        fingerprint(capturedAt: Date(timeIntervalSinceReferenceDate: .infinity))] {
            let client = stub(response(first))
            do { _ = try await client.recognize(fingerprint: invalid); expect(false, "invalid fingerprint metadata is rejected") }
            catch { expect(true, "invalid fingerprint metadata is rejected") }
            expect(NetEaseStubProtocol.count == 0, "invalid fingerprint does not reach the network")
        }

        let serviceFailure = stub(#"{"code":500,"message":"unavailable"}"#)
        do { _ = try await serviceFailure.recognize(fingerprint: fingerprint()); expect(false, "service failure cannot become no match") }
        catch NetEaseMusicMatcherError.service(let code) { expect(code == 500, "service status survives HTTP success") }
        catch { expect(false, "service failure uses a clear provider error") }
        let unavailable = stub("unavailable", status: 503)
        do { _ = try await unavailable.recognize(fingerprint: fingerprint()); expect(false, "HTTP failures throw") }
        catch MusicMatcherError.http(let code) { expect(code == 503, "HTTP status is preserved") }
        catch { expect(false, "HTTP failure type is preserved") }
        let nonHTTP = stub(response(first))
        NetEaseStubProtocol.lock.withLock {
            NetEaseStubProtocol.handler = { request in (Data(), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)) }
        }
        do { _ = try await nonHTTP.recognize(fingerprint: fingerprint()); expect(false, "non-HTTP responses are rejected") }
        catch MusicMatcherError.invalidResponse { expect(true, "non-HTTP responses are rejected") }
        catch { expect(false, "non-HTTP response error is clear") }
        let offline = stub(response(first))
        NetEaseStubProtocol.lock.withLock { NetEaseStubProtocol.handler = { _ in throw URLError(.notConnectedToInternet) } }
        do { _ = try await offline.recognize(fingerprint: fingerprint()); expect(false, "transport failures propagate") }
        catch { expect((error as? URLError)?.code == .notConnectedToInternet, "transport failure retains its cause") }

        let preCancelledClient = stub(response(first))
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await preCancelledClient.recognize(fingerprint: fingerprint())
        }
        do { _ = try await preCancelled.value; expect(false, "pre-cancelled recognition throws") }
        catch { expect(error is CancellationError, "pre-cancelled recognition retains cancellation semantics") }
        expect(NetEaseStubProtocol.count == 0, "pre-cancelled recognition never reaches the network")
        let cancellable = stub(response(first))
        NetEaseStubProtocol.lock.withLock { NetEaseStubProtocol.stalled = true }
        let cancelled = Task { try await cancellable.recognize(fingerprint: fingerprint()) }
        for _ in 0..<100 where NetEaseStubProtocol.count == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        cancelled.cancel()
        do { _ = try await cancelled.value; expect(false, "in-flight cancellation must throw") }
        catch { expect(error is CancellationError || (error as? URLError)?.code == .cancelled, "in-flight cancellation retains cancellation semantics") }
        for _ in 0..<100 where NetEaseStubProtocol.lock.withLock({ NetEaseStubProtocol.cancellations }) == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        expect(NetEaseStubProtocol.lock.withLock { NetEaseStubProtocol.cancellations } == 1, "in-flight cancellation stops its network request")

        for (header, delay) in [(nil, 60.0), ("1", 60.0), ("120", 120.0), ("invalid", 60.0), ("inf", 60.0), ("-5", 60.0), ("Tue, 14 Nov 2023 22:18:20 GMT", 300.0)] as [(String?, Double)] {
            expect(NetEaseMusicMatcher.rateLimitDate(retryAfter: header, now: anchor) == anchor.addingTimeInterval(delay), "Retry-After has at least a minute cooldown: \(header ?? "missing")")
        }
        let limited = stub("{}", status: 429, headers: ["Retry-After": "120"])
        let beforeLimit = Date()
        var deadline: Date?
        do { _ = try await limited.recognize(fingerprint: fingerprint()); expect(false, "HTTP 429 throws a rate limit") }
        catch MusicMatcherError.rateLimited(let until) { deadline = until; expect(until >= beforeLimit.addingTimeInterval(120), "server Retry-After is honored") }
        catch { expect(false, "HTTP 429 has a retry deadline") }
        let secondConfiguration = URLSessionConfiguration.ephemeral
        secondConfiguration.protocolClasses = [NetEaseStubProtocol.self]
        let anotherMatcher = NetEaseMusicMatcher(session: URLSession(configuration: secondConfiguration))
        for client in [limited, anotherMatcher] {
            do { _ = try await client.recognize(fingerprint: fingerprint()); expect(false, "cooldown blocks repeated and new matcher requests") }
            catch MusicMatcherError.rateLimited(let until) { expect(until == deadline, "all matcher instances share the same cooldown") }
            catch { expect(false, "cooldown retains the rate-limit error") }
        }
        expect(NetEaseStubProtocol.count == 1, "cooldown never sends another network request")

        // A separate test process provides a clean shared cooldown without adding
        // a production reset hook that could bypass the provider's rate limit.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--service-rate-limit"]
        let output = Pipe()
        child.standardOutput = output
        child.standardError = output
        try child.run()
        let childOutput = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        expect(child.terminationStatus == 0, "HTTP 200 service-code 429 shares cooldown: \(String(data: childOutput, encoding: .utf8) ?? "")")
        finish()
    }
}
