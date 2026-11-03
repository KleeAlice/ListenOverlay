import Foundation
import CommonCrypto

@main struct NetEaseLocalPlaybackTests {
    static var failures = 0, checks = 0
    static func check(_ condition: Bool, _ label: String) {
        checks += 1
        if !condition { failures += 1; print("FAIL: \(label)") }
    }
    static func fixed(_ value: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    static func variable(_ value: Int) -> [UInt8] {
        var n = value, bytes: [UInt8] = []
        repeat { let byte = UInt8(n & 127); n >>= 7; bytes.append(byte | (n == 0 ? 0 : 128)) } while n > 0
        return bytes
    }
    static func crc(_ bytes: [UInt8]) -> UInt32 {
        var value = UInt32.max
        for byte in bytes { value ^= UInt32(byte); for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0x82f63b78 : 0) } }
        value = ~value
        return ((value >> 15) | (value << 17)) &+ 0xa282ead8
    }
    static func physical(_ bytes: [UInt8], type: UInt8 = 1) -> Data {
        Data(fixed(UInt64(crc([type] + bytes)), 4) + fixed(UInt64(bytes.count), 2) + [type] + bytes)
    }
    static func encrypted(_ json: String) -> [UInt8] {
        let plain = Array(json.utf8), key = Array(")(13daqP@ssw0rd~".utf8)
        var out = [UInt8](repeating: 0, count: plain.count + 16), count = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), key, key.count, nil, plain, plain.count, &out, out.count, &count)
        precondition(status == kCCSuccess)
        return [1] + Array(Data(out.prefix(count)).base64EncodedString().utf8)
    }
    static func batch(seq: UInt64, json: String?, key: String = "lastPlaying") -> [UInt8] {
        let key = Array(("_orpheus://orpheus\0\u{1}" + key).utf8)
        let value = json.map(encrypted)
        return fixed(seq, 8) + fixed(1, 4) + [value == nil ? 0 : 1] + variable(key.count) + key + (value.map { variable($0.count) + $0 } ?? [])
    }
    static func json(id: Int = 42, current: Int = 10) -> String { "{\"resourceId\":\"\(id)\",\"trackId\":\"\(id)\",\"current\":\(current),\"resourceDuration\":210}" }
    static func queue(_ root: URL) throws {
        let dir = root.appendingPathComponent("file_storage/webdata/file")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rows = [42, 43].map { id -> [String: Any] in
            ["id": String(id), "track": ["id": String(id), "name": id == 42 ? "测试歌" : "测试歌 (Live)", "duration": 210000, "artists": [["name": "歌手甲"], ["name": "歌手乙"]], "album": ["name": "测试专辑"]]]
        }
        try JSONSerialization.data(withJSONObject: ["list": rows]).write(to: dir.appendingPathComponent("playingList"))
    }
    static func main() throws {
        let one = physical(batch(seq: 100, json: json()))
        let parsed = NetEaseLocalLog.latest(in: one)
        check(parsed?.sequence == 100 && parsed?.state?.songID == 42 && parsed?.state?.current == 10, "decode complete current record")
        check(NetEaseLocalLog.latest(in: physical(batch(seq: 101, json: json(), key: "otherKey"))) == nil, "only exact allowlisted key")
        var corrupt = one; corrupt[7] ^= 1
        check(NetEaseLocalLog.latest(in: corrupt) == nil, "CRC rejects corrupted payload")
        check(NetEaseLocalLog.latest(in: one + physical(batch(seq: 99, json: json(id: 43))))?.sequence == 100, "highest sequence wins, not physical order")
        let deletion = NetEaseLocalLog.latest(in: one + physical(batch(seq: 102, json: nil)))
        check(deletion?.sequence == 102 && deletion?.state == nil, "deletion does not revive previous song")
        for size in 0..<one.count { check(NetEaseLocalLog.latest(in: one.prefix(size)) == nil, "incomplete tail \(size)") }
        check(NetEaseLocalLog.latest(in: one + one.prefix(20))?.sequence == 100, "partial append retains complete record")
        let huge = batch(seq: 103, json: json().dropLast() + ",\"padding\":\"" + String(repeating: "x", count: 40000) + "\"}")
        let first = physical(Array(huge.prefix(32761)), type: 2)
        let last = physical(Array(huge.dropFirst(32761)), type: 4)
        check(NetEaseLocalLog.latest(in: first + last)?.sequence == 103, "fragmented write batch across 32KB blocks")
        check(NetEaseLocalLog.latest(in: physical(batch(seq: 104, json: "{\"resourceId\":\"42\",\"current\":-1}")))?.state == nil, "invalid current state rejected")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("CEFCache/Local Storage/leveldb")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try queue(root)
        let log = logs.appendingPathComponent("000001.log")
        try one.write(to: log)
        let reader = NetEaseLocalPlaybackReader(storageRoots: [root])
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        check(reader.read(processID: 1, outputActive: true, at: base) == nil, "startup waits for live write, never last-session stale song")
        try (one + physical(batch(seq: 105, json: json(current: 13)))).write(to: log)
        let live = reader.read(processID: 1, outputActive: true, at: base.addingTimeInterval(3))
        check(live?.songID == 42 && live?.title == "测试歌" && live?.artist == "歌手甲 / 歌手乙", "exact ID binds full title and credits")
        check(live?.position == 13 && live?.isPlaying == true, "native seconds and per-process output establish playback")
        check(reader.read(processID: 1, outputActive: true, at: base.addingTimeInterval(5))?.position == 15, "background interpolates without new writes")
        let pause = reader.read(processID: 1, outputActive: false, at: base.addingTimeInterval(6))
        check(pause?.isPlaying == false && pause?.position == 16, "pause freezes interpolated position")
        check(reader.read(processID: 1, outputActive: false, at: base.addingTimeInterval(10))?.position == 16, "paused stays stationary")
        try physical(batch(seq: 106, json: json(id: 43, current: 1))).write(to: logs.appendingPathComponent("000002.log"))
        let next = reader.read(processID: 1, outputActive: true, at: base.addingTimeInterval(11))
        check(next?.songID == 43 && next?.title == "测试歌 (Live)" && next?.position == 1, "background native ID changes immediately, including actual live version")
        try FileManager.default.removeItem(at: logs.appendingPathComponent("000002.log"))
        check(reader.read(processID: 1, outputActive: true, at: base.addingTimeInterval(12))?.songID == 43, "rotation cannot resurrect older sequence")
        try physical(batch(seq: 107, json: json(id: 43, current: 90))).write(to: log)
        check(reader.read(processID: 1, outputActive: true, at: base.addingTimeInterval(13))?.position == 90, "forward seek follows native position")
        try physical(batch(seq: 108, json: json(id: 43, current: 20))).write(to: log)
        check(reader.read(processID: 1, outputActive: true, at: base.addingTimeInterval(14))?.position == 20, "newer sequence authorizes backward seek")
        check(reader.read(processID: 2, outputActive: true, at: base.addingTimeInterval(15)) == nil, "new process must establish new live baseline")
        let longState = json(id: 43, current: 211).replacingOccurrences(of: "\"resourceDuration\":210", with: "\"resourceDuration\":211")
        try physical(batch(seq: 109, json: longState)).write(to: log)
        let end = reader.read(processID: 2, outputActive: false, at: base.addingTimeInterval(16))
        check(end?.position == 210 && end?.duration == 210, "rounded native duration cannot emit position beyond metadata duration")
        print("NetEase local playback: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
