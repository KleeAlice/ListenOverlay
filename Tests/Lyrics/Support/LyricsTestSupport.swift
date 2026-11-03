import Foundation

/// Minimal assertion helper in the style of the app's other test executables.
struct Checks {
    let suite: String
    private(set) var count = 0

    init(_ suite: String) { self.suite = suite }

    mutating func that(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        count += 1
        guard condition else {
            let extra = detail()
            fputs("FAIL: \(suite): \(label)\(extra.isEmpty ? "" : " — \(extra)")\n", stderr)
            exit(1)
        }
    }

    mutating func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        that(actual == expected, label, "got \(actual), expected \(expected)")
    }

    mutating func near(_ actual: Double?, _ expected: Double, _ label: String, tolerance: Double = 0.001) {
        that(actual.map { abs($0 - expected) <= tolerance } ?? false, label, "got \(actual.map { String($0) } ?? "nil"), expected \(expected)")
    }

    func pass(_ summary: String) {
        print("PASS: \(count) \(summary)")
    }
}

enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func text(_ name: String) -> String {
        guard let value = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else {
            fputs("FAIL: missing fixture \(name)\n", stderr)
            exit(1)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fresh cache directories under `.build/lyrics/test-caches` (the runner clears it).
    static func temporaryDirectory(_ label: String) -> URL {
        let root = directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(".build/lyrics/test-caches/\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Serves canned HTTP responses to a URLSession; nothing reaches the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json; charset=utf-8"]
        var body = Data()
        var delay: TimeInterval = 0

        static func json(_ object: Any, delay: TimeInterval = 0, status: Int = 200) -> Reply {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return Reply(status: status, body: data, delay: delay)
        }

        static func raw(_ text: String, delay: TimeInterval = 0, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            var reply = Reply(status: status, body: Data(text.utf8), delay: delay)
            for (key, value) in headers { reply.headers[key] = value }
            return reply
        }
    }

    typealias Handler = @Sendable (URLRequest) -> Reply?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var log: [URLRequest] = []

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            log = []
        }
    }

    static var requests: [URLRequest] { lock.withLock { log } }

    static func requests(host: String) -> [URLRequest] { requests.filter { $0.url?.host == host } }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private let stateLock = NSLock()
    nonisolated(unsafe) private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let handler = Self.lock.withLock { () -> Handler? in
            Self.log.append(request)
            return Self.handler
        }
        guard let reply = handler?(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let deliver: @Sendable () -> Void = { [self] in
            guard !self.stateLock.withLock({ self.stopped }) else { return }
            guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: reply.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
    }
}

/// Routes by host and path prefix; `query` entries must all be present with equal values.
struct StubRoute: Sendable {
    var host: String
    var path: String
    var query: [String: String] = [:]
    var reply: StubURLProtocol.Reply

    func matches(_ request: URLRequest) -> Bool {
        guard let url = request.url, url.host == host, url.path.hasPrefix(path) else { return false }
        guard !query.isEmpty else { return true }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return query.allSatisfy { key, value in items.contains { $0.name == key && $0.value == value } }
    }

    static func install(_ routes: [StubRoute]) {
        StubURLProtocol.install { request in routes.first { $0.matches(request) }?.reply }
    }
}

extension Lyrics {
    var texts: [String] { lines.map(\.text) }
}
