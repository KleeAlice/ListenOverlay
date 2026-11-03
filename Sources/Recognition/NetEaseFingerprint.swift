import Foundation
import CryptoKit
import JavaScriptCore
@preconcurrency import AVFoundation

struct NetEaseFingerprint: Sendable {
    let value: String
    let duration: Double
    /// End of the captured six-second sample; preserved through processing and network delay.
    let capturedAt: Date
}

enum NetEaseFingerprintError: LocalizedError {
    case invalidAudio, invalidCaptureTime, runtimeIntegrity, invalidArchive, downloadFailed(Int)
    case extractionFailed, javascriptUnavailable, javascriptFailed, timedOut
    var errorDescription: String? {
        switch self {
        case .invalidAudio: return "识曲需要完整、有效的六秒声音片段。"
        case .invalidCaptureTime: return "声音片段的时间无效。"
        case .runtimeIntegrity: return "网易识曲组件校验失败，请重新准备组件。"
        case .invalidArchive: return "网易识曲组件的下载格式无效。"
        case .downloadFailed(let code): return "网易识曲组件下载失败（\(code)）。"
        case .extractionFailed: return "无法解压网易识曲组件。"
        case .javascriptUnavailable: return "当前系统无法运行本地声纹计算。"
        case .javascriptFailed: return "本地声纹计算失败。"
        case .timedOut: return "本地声纹计算超时，请重试。"
        }
    }
}

/// This is a downloader/adapter, not a redistribution license for NetEase's runtime.
/// Official bytes stay in Application Support and must never be added to source or app bundles.
enum NetEaseRuntimeArchive {
    static let crxSHA256 = "ef746443a0f240c525b6cdf8ff6cf27ab22f4ac0399cd3b2564452e753ce3b75"
    static let scriptSHA256 = "ac38899d27fcc81cbae644bd89ec826ebb865e93c759521ab5c7c8875ed83c1e"
    static let wasmSHA256 = "8064415bb66e45410e88877f07cd007a3ae62ebf463aac13c159a8f13e4c8fe8"
    static let version = "1.0.4"
    static var downloadURL: URL {
        var parts = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        parts.queryItems = [URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: "130.0.0.0"),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=kemcalcncfhmdkgglekijclbomdoohkp&installsource=ondemand&uc")]
        return parts.url!
    }
    static func verify(_ data: Data, sha256: String) throws {
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == sha256 else { throw NetEaseFingerprintError.runtimeIntegrity }
    }
    static func zipPayload(from data: Data) throws -> Data {
        guard data.count >= 12, Array(data.prefix(4)) == [0x43, 0x72, 0x32, 0x34] else {
            throw NetEaseFingerprintError.invalidArchive
        }
        let bytes = [UInt8](data.prefix(12))
        func uint32(_ offset: Int) -> UInt64 {
            (0..<4).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
        }
        let start = 12 + uint32(8)
        guard uint32(4) == 3, start <= UInt64(data.count), UInt64(data.count) - start >= 22 else {
            throw NetEaseFingerprintError.invalidArchive
        }
        let zip = data.subdata(in: Int(start)..<data.count)
        guard Array(zip.prefix(4)) == [0x50, 0x4b, 3, 4] else { throw NetEaseFingerprintError.invalidArchive }
        return zip
    }
    struct Files: Sendable { let script: String; let wasm: Data }
    static func verifiedFiles(at directory: URL) throws -> Files {
        func read(_ name: String, digest: String) throws -> Data {
            let url = directory.appendingPathComponent(name)
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  let size = info.fileSize, size < 1_000_000 else { throw NetEaseFingerprintError.runtimeIntegrity }
            let bytes = try Data(contentsOf: url)
            try verify(bytes, sha256: digest)
            return bytes
        }
        _ = try read("extension.crx", digest: crxSHA256)
        let scriptBytes = try read("sandbox.bundle.js", digest: scriptSHA256)
        let wasm = try read("afp.wasm", digest: wasmSHA256)
        guard let script = String(data: scriptBytes, encoding: .utf8) else { throw NetEaseFingerprintError.runtimeIntegrity }
        return Files(script: script, wasm: wasm)
    }
    static func prepare(at directory: URL) async throws -> Files {
        try Task.checkCancellation()
        if let files = try? verifiedFiles(at: directory) { return files }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 40
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (archive, response) = try await session.data(from: downloadURL)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              ["clients2.google.com", "clients2.googleusercontent.com"].contains(http.url?.host ?? "") else {
            throw NetEaseFingerprintError.downloadFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard archive.count == 302_541 else { throw NetEaseFingerprintError.runtimeIntegrity }
        try verify(archive, sha256: crxSHA256)
        let zip = try zipPayload(from: archive)
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("listen-netease-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let zipURL = temporary.appendingPathComponent("official.zip")
        let expanded = temporary.appendingPathComponent("expanded", isDirectory: true)
        try zip.write(to: zipURL, options: .atomic)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, expanded.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw NetEaseFingerprintError.extractionFailed }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard process.terminationStatus == 0 else { throw NetEaseFingerprintError.extractionFailed }
        try archive.write(to: expanded.appendingPathComponent("extension.crx"), options: .atomic)
        let files = try verifiedFiles(at: expanded)
        try Task.checkCancellation()
        // Persist only the three verified runtime files, never the extension's other scripts.
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["extension.crx", "sandbox.bundle.js", "afp.wasm"] {
            let data = try Data(contentsOf: expanded.appendingPathComponent(name))
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        let provenance: [String: String] = ["version": version, "source": downloadURL.absoluteString,
            "store": "https://chromewebstore.google.com/detail/kemcalcncfhmdkgglekijclbomdoohkp",
            "crxSHA256": crxSHA256, "scriptSHA256": scriptSHA256, "wasmSHA256": wasmSHA256,
            "notice": "Official NetEase runtime, downloaded for local use. No redistribution or embedding license is claimed."]
        try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted, .sortedKeys]).write(
            to: directory.appendingPathComponent("provenance.json"), options: .atomic)
        return files
    }
}

actor NetEaseFingerprintEngine {
    private let directory: URL
    private let worker = NetEaseFingerprintWorker()
    private var preparation: Task<Void, Error>?
    private var prepared = false
    init(runtimeDirectory: URL? = nil) {
        directory = runtimeDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ListenOverlay/Runtime/NetEase-1.0.4", isDirectory: true)
    }
    func prepare() async throws {
        try Task.checkCancellation()
        if prepared { return }
        if let preparation {
            try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
            try Task.checkCancellation(); return
        }
        let directory = self.directory, worker = self.worker
        let task = Task {
            let files = try await NetEaseRuntimeArchive.prepare(at: directory)
            try await worker.prepare(files)
        }
        preparation = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            prepared = true; preparation = nil
            try Task.checkCancellation()
        } catch { preparation = nil; throw error }
    }
    func fingerprint(buffer: AVAudioPCMBuffer, capturedAt: Date) async throws -> NetEaseFingerprint {
        try Task.checkCancellation()
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite else { throw NetEaseFingerprintError.invalidCaptureTime }
        let audio = try Self.samples(from: buffer)
        try await prepare()
        return try await worker.fingerprint(samples: audio, capturedAt: capturedAt)
    }
    nonisolated static func samples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        let rate = buffer.format.sampleRate
        guard rate.isFinite, rate > 0, buffer.format.channelCount > 0,
              abs(Double(buffer.frameLength) / rate - 6) <= 0.5 / rate else { throw NetEaseFingerprintError.invalidAudio }
        let output: AVAudioPCMBuffer
        if rate == 8000, buffer.format.channelCount == 1, buffer.format.commonFormat == .pcmFormatFloat32,
           !buffer.format.isInterleaved { output = buffer }
        else {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false),
                  let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000),
                  let converter = AVAudioConverter(from: buffer.format, to: format) else { throw NetEaseFingerprintError.invalidAudio }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, status in
                if supplied { status.pointee = .endOfStream; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            guard status != .error, conversionError == nil else { throw NetEaseFingerprintError.invalidAudio }
            output = converted
        }
        guard output.frameLength == 48000, let channel = output.floatChannelData?[0] else { throw NetEaseFingerprintError.invalidAudio }
        let samples = Array(UnsafeBufferPointer(start: channel, count: 48000))
        guard samples.allSatisfy(\.isFinite) else { throw NetEaseFingerprintError.invalidAudio }
        return samples
    }
}

/// Each JSContext is touched only by this serial queue. JavaScriptCore has no DOM,
/// native exports, sockets, file access, or network bridge. Its fetch stub serves only
/// the already verified WASM bytes. The official JavaScript is evaluated unchanged.
private final class NetEaseFingerprintWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ListenOverlay.NetEaseFingerprint", qos: .userInitiated)
    private var context: JSContext?
    private var files: NetEaseRuntimeArchive.Files?
    private var calls = 0
    func prepare(_ files: NetEaseRuntimeArchive.Files) async throws {
        try await perform { control in self.files = files; try self.load(files, control: control) }
    }
    func fingerprint(samples: [Float], capturedAt: Date) async throws -> NetEaseFingerprint {
        try await perform { control in
            // The official wrapper does not expose disposal of its C++ vector. Recycle
            // the whole VM periodically to keep long-running native memory bounded.
            if self.context == nil || self.calls >= 64 {
                guard let files = self.files else { throw NetEaseFingerprintError.javascriptUnavailable }
                try self.load(files, control: control)
            }
            guard let context = self.context else { throw NetEaseFingerprintError.javascriptUnavailable }
            defer { context.evaluateScript("__samples=null;__reply=null;__send('reset');"); self.calls += 1 }
            try control.check()
            self.seedRandom(context)
            context.setObject(samples, forKeyedSubscript: "__samples" as NSString)
            context.exception = nil
            context.evaluateScript("__send('reset');__send('record',[new Float32Array(__samples)]);")
            guard context.exception == nil,
                  context.evaluateScript("!!(__reply && __reply.type==='recordCallBack' && __reply.data && __reply.data.result instanceof ArrayBuffer)")?.toBool() == true,
                  let numbers = context.evaluateScript("Array.from(new Uint8Array(__reply.data.result))")?.toArray() as? [NSNumber],
                  !numbers.isEmpty, numbers.count < 65536 else { throw NetEaseFingerprintError.javascriptFailed }
            let value = Data(numbers.map(\.uint8Value)).base64EncodedString()
            try control.check()
            return NetEaseFingerprint(value: value, duration: 6, capturedAt: capturedAt)
        }
    }
    private func seedRandom(_ context: JSContext) {
        context.setObject((0..<16).map { _ in Int(UInt8.random(in: 0...255)) }, forKeyedSubscript: "__entropy" as NSString)
    }
    private func load<T>(_ files: NetEaseRuntimeArchive.Files, control: NetEaseFingerprintJob<T>) throws {
        context = nil; calls = 0
        guard let js = JSContext(), js.evaluateScript("typeof WebAssembly")?.toString() == "object" else {
            throw NetEaseFingerprintError.javascriptUnavailable
        }
        js.exceptionHandler = { _, _ in }
        seedRandom(js)
        js.setObject(files.wasm.map { Int($0) }, forKeyedSubscript: "__wasmBytes" as NSString)
        js.evaluateScript(Self.bridge)
        js.evaluateScript(files.script)
        guard js.exception == nil else { throw NetEaseFingerprintError.javascriptFailed }
        let deadline = Date().addingTimeInterval(5)
        while js.evaluateScript("__wasmReady")?.toBool() != true {
            try control.check()
            guard Date() < deadline else { throw NetEaseFingerprintError.timedOut }
            if js.evaluateScript("__wasmFailed")?.toBool() == true { throw NetEaseFingerprintError.javascriptFailed }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        try control.check()
        context = js
    }
    private static let bridge = """
    var __reply=null, __samples=null, __receiver=null, __wasmReady=false, __wasmFailed=false;
    var __wasmBuffer=new Uint8Array(__wasmBytes).buffer; __wasmBytes=null;
    var window={addEventListener:function(type,fn){if(type==='message')__receiver=fn;}};
    var document={currentScript:{src:'https://runtime.invalid/sandbox.bundle.js'}};
    var console={log:function(){},warn:function(){},error:function(){},info:function(){}};
    var crypto={getRandomValues:function(a){if(a.length>__entropy.length)throw Error('Entropy size');for(var i=0;i<a.length;i++)a[i]=__entropy[i];return a;}};
    var fetch=function(url){
        if(url!=='https://runtime.invalid/afp.wasm')return Promise.reject(Error('Network unavailable'));
        return Promise.resolve({ok:true,arrayBuffer:function(){return Promise.resolve(__wasmBuffer);}});
    };
    var __instantiate=WebAssembly.instantiate;
    WebAssembly.instantiate=function(bytes,imports){return __instantiate(bytes,imports).then(function(value){__wasmReady=true;return value;},function(error){__wasmFailed=true;throw error;});};
    function __send(type,data){__receiver({data:{type:type,data:data},source:{postMessage:function(message){__reply=message;}}});}
    """
    private func perform<T>(_ operation: @escaping (NetEaseFingerprintJob<T>) throws -> T) async throws -> T {
        let control = NetEaseFingerprintJob<T>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                control.start(continuation)
                queue.async {
                    do { try control.check(); control.finish(.success(try operation(control))) }
                    catch { self.context = nil; control.finish(.failure(error)) }
                }
                // Caller deadlines and cancellation are prompt. A running fixed, verified
                // six-second WASM call finishes on its serial queue; late results are discarded.
                DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                    control.finish(.failure(NetEaseFingerprintError.timedOut))
                }
            }
        } onCancel: { control.finish(.failure(CancellationError())) }
    }
}

private final class NetEaseFingerprintJob<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    func start(_ continuation: CheckedContinuation<Value, Error>) {
        let existing = lock.withLock { () -> Result<Value, Error>? in
            if let result { return result }
            self.continuation = continuation; return nil
        }
        if let existing { continuation.resume(with: existing) }
    }
    func check() throws {
        if let result = lock.withLock({ result }) {
            switch result { case .failure(let error): throw error; case .success: throw CancellationError() }
        }
    }
    func finish(_ result: Result<Value, Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            let waiter = continuation; continuation = nil; return waiter
        }
        waiter?.resume(with: result)
    }
}
