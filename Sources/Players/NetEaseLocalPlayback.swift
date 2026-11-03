import Foundation
import CommonCrypto
import CoreAudio

// Local lastPlaying format/AES reference: CloudLyrics-for-macOS (MIT).
// Copyright (c) 2026 hellomyonly55. See Resources/CloudLyrics-LICENSE.txt.
// This reader opens only allowlisted playback files, read-only. It never opens
// the LevelDB database, takes its lock, reads cookies, or modifies player data.
struct NetEaseLocalState: Decodable {
    let current: Double
    let resourceDuration: Double
    let resourceId: String
    let trackId: String?
    var songID: Int64? {
        guard let value = Int64(resourceId), value > 0,
              trackId == nil || trackId == resourceId else { return nil }
        return value
    }
    static func decode(_ value: [UInt8]) -> Self? {
        guard value.first == 1, value.count <= 131_072,
              let encrypted = Data(base64Encoded: Data(value.dropFirst())),
              !encrypted.isEmpty, encrypted.count.isMultiple(of: 16) else { return nil }
        let key = Array(")(13daqP@ssw0rd~".utf8)
        var output = [UInt8](repeating: 0, count: encrypted.count + 16), length = 0
        let status = encrypted.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode), key, key.count, nil,
                    bytes.baseAddress, encrypted.count, &output, output.count, &length)
        }
        guard status == kCCSuccess,
              let state = try? JSONDecoder().decode(Self.self, from: Data(output.prefix(length))),
              state.songID != nil, state.current.isFinite, state.resourceDuration.isFinite,
              state.resourceDuration > 0, state.resourceDuration <= 86_400,
              (0...state.resourceDuration).contains(state.current) else { return nil }
        return state
    }
}

enum NetEaseLocalLog {
    struct Record { let sequence: UInt64; let state: NetEaseLocalState? }
    private static let key = Array("_orpheus://orpheus\0\u{1}lastPlaying".utf8)
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0x82f63b78 : 0) }
        return value
    }
    private static func checksum(_ bytes: ArraySlice<UInt8>, type: UInt8) -> UInt32 {
        var value = UInt32.max
        value = crcTable[Int((value ^ UInt32(type)) & 255)] ^ (value >> 8)
        for byte in bytes { value = crcTable[Int((value ^ UInt32(byte)) & 255)] ^ (value >> 8) }
        value = ~value
        return ((value >> 15) | (value << 17)) &+ 0xa282ead8
    }
    private static func integer(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<count { value |= UInt64(bytes[offset + index]) << (8 * index) }
        return value
    }
    private static func variable(_ bytes: [UInt8], _ offset: inout Int) -> Int? {
        var result = 0
        for shift in stride(from: 0, to: 35, by: 7) {
            guard offset < bytes.count else { return nil }
            let byte = bytes[offset]; offset += 1
            if shift == 28 && byte > 15 { return nil }
            result |= Int(byte & 127) << shift
            if byte < 128 { return result }
        }
        return nil
    }
    private static func field(_ bytes: [UInt8], _ offset: inout Int) -> [UInt8]? {
        guard let size = variable(bytes, &offset), size <= bytes.count - offset else { return nil }
        let result = Array(bytes[offset..<(offset + size)]); offset += size
        return result
    }
    private static func batch(_ bytes: [UInt8]) -> Record? {
        guard bytes.count >= 12 else { return nil }
        let sequence = integer(bytes, 0, 8), count = integer(bytes, 8, 4)
        guard count > 0, count <= 100_000, sequence < (1 << 56), count < (1 << 56) - sequence else { return nil }
        var offset = 12, latest: Record?
        for index in 0..<count {
            guard offset < bytes.count else { return nil }
            let tag = bytes[offset]; offset += 1
            guard tag == 0 || tag == 1, let name = field(bytes, &offset) else { return nil }
            var value: [UInt8]?
            if tag == 1 { guard let content = field(bytes, &offset) else { return nil }; value = content }
            if name == key { latest = Record(sequence: sequence + index, state: value.flatMap(NetEaseLocalState.decode)) }
        }
        return offset == bytes.count ? latest : nil
    }
    /// Parses complete, checksum-verified LevelDB log batches. SSTable bytes are
    /// never substring-scanned: an old compacted value is not current playback.
    static func latest(in data: Data) -> Record? {
        guard data.count <= 8 * 1_024 * 1_024 else { return nil }
        let bytes = Array(data)
        var latest: Record?, fragments: [UInt8]?
        for block in stride(from: 0, to: bytes.count, by: 32768) {
            let end = min(block + 32768, bytes.count)
            var cursor = block
            while cursor + 7 <= end {
                let crc = UInt32(integer(bytes, cursor, 4))
                let size = Int(integer(bytes, cursor + 4, 2)), type = bytes[cursor + 6]
                cursor += 7
                guard size > 0, cursor + size <= end else { fragments = nil; break }
                let payload = bytes[cursor..<(cursor + size)]; cursor += size
                guard checksum(payload, type: type) == crc else { fragments = nil; continue }
                var complete: [UInt8]?
                switch type {
                case 1: fragments = nil; complete = Array(payload)
                case 2: fragments = Array(payload)
                case 3, 4:
                    if fragments != nil, fragments!.count + size <= 2_000_000 {
                        fragments!.append(contentsOf: payload)
                        if type == 4 { complete = fragments; fragments = nil }
                    } else { fragments = nil }
                default: fragments = nil
                }
                if let complete, let record = batch(complete), latest.map({ record.sequence > $0.sequence }) ?? true { latest = record }
            }
        }
        return latest
    }
}

struct NetEaseLocalObservation {
    let songID: Int64
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let position: Double
    let isPlaying: Bool?
}

final class NetEaseLocalPlaybackReader {
    private struct Track {
        let id: Int64, title: String, artist: String, album: String
        let duration: Double
    }
    private struct FileStamp: Equatable { let size: Int; let modified: Date }
    private let roots: [URL]
    private var processID: pid_t?
    private var selectedRoot: URL?
    private var logCache: [URL: (FileStamp, NetEaseLocalLog.Record?)] = [:]
    private var sequence: UInt64?
    private var state: NetEaseLocalState?
    private var track: Track?
    private var verified = false
    private var position: Double = 0
    private var observedAt: Date?
    private var lastNativeChange = Date.distantPast
    private var wasPlaying = false

    init(storageRoots: [URL]? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots = storageRoots ?? [
            home.appendingPathComponent("Library/Application Support/com.netease.163music/Documents/storage"),
            home.appendingPathComponent("Library/Containers/com.netease.163music/Data/Documents/storage")
        ]
    }
    func reset() {
        selectedRoot = nil; logCache.removeAll(); sequence = nil; state = nil; track = nil
        verified = false; observedAt = nil; wasPlaying = false; lastNativeChange = .distantPast
    }
    func read(processID: pid_t, outputActive: Bool?, at now: Date = Date()) -> NetEaseLocalObservation? {
        if self.processID != processID { reset(); self.processID = processID }
        let candidates = roots.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("CEFCache/Local Storage/leveldb").path) }
        // Two different installations' stores cannot safely be ranked by mtime.
        guard candidates.count == 1, let root = candidates.first else { return nil }
        if selectedRoot != root { reset(); selectedRoot = root }
        let record = latest(root)
        let elapsed = observedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        if wasPlaying { position += elapsed }
        observedAt = now
        if let record, sequence.map({ record.sequence > $0 }) ?? true {
            let baseline = sequence == nil
            sequence = record.sequence
            guard let incoming = record.state, let id = incoming.songID else {
                verified = false; state = nil; track = nil; wasPlaying = false
                return nil
            }
            if !baseline {
                let changed = state?.songID != id
                let moved = state.map { abs($0.current - incoming.current) > 0.001 } ?? true
                if changed || moved { lastNativeChange = now }
                if changed || state == nil || incoming.current < state!.current || abs(position - incoming.current) > 3 {
                    position = incoming.current
                } else if moved { position = max(position, incoming.current) }
                verified = true
            } else { position = incoming.current }
            state = incoming
            if track?.id != id { track = Self.track(id: id, root: root) }
        }
        guard verified, let state, let id = state.songID else { return nil }
        if track?.id != id { track = Self.track(id: id, root: root) }
        guard let track, abs(track.duration - state.resourceDuration) <= 3 else { return nil }
        let playing: Bool? = outputActive ?? (now.timeIntervalSince(lastNativeChange) <= 8 ? true : nil)
        wasPlaying = playing ?? wasPlaying
        position = min(max(0, position), min(track.duration, state.resourceDuration))
        return NetEaseLocalObservation(songID: id, title: track.title, artist: track.artist, album: track.album,
            duration: track.duration, position: position, isPlaying: playing)
    }
    private func latest(_ root: URL) -> NetEaseLocalLog.Record? {
        let directory = root.appendingPathComponent("CEFCache/Local Storage/leveldb")
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) else { return nil }
        let logs = files.filter { $0.pathExtension == "log" && $0.deletingPathExtension().lastPathComponent.allSatisfy(\.isNumber) }
        guard logs.count <= 16 else { return nil }
        var latest: NetEaseLocalLog.Record?
        logCache = logCache.filter { logs.contains($0.key) }
        for file in logs {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= 8 * 1_024 * 1_024,
                  let modified = values.contentModificationDate else { continue }
            let stamp = FileStamp(size: size, modified: modified)
            let record: NetEaseLocalLog.Record?
            if let cached = logCache[file], cached.0 == stamp { record = cached.1 }
            else {
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                let data = try? handle.read(upToCount: size)
                try? handle.close()
                guard let data else { continue }
                record = NetEaseLocalLog.latest(in: data)
                logCache[file] = (stamp, record)
            }
            if let record, latest.map({ record.sequence > $0.sequence }) ?? true { latest = record }
        }
        return latest
    }
    private static func track(id: Int64, root: URL) -> Track? {
        let url = root.appendingPathComponent("file_storage/webdata/file/playingList")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_000_000,
              let data = try? Data(contentsOf: url), data.count <= 16_000_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["list"] as? [[String: Any]], list.count <= 20_000 else { return nil }
        func identifier(_ value: Any?) -> Int64? {
            if let text = value as? String { return Int64(text) }
            return (value as? NSNumber)?.int64Value
        }
        let rows = list.filter { identifier($0["id"]) == id }
        guard let row = rows.first, let item = row["track"] as? [String: Any], identifier(item["id"]) == id,
              let title = item["name"] as? String, let duration = item["duration"] as? Double,
              let artists = item["artists"] as? [[String: Any]], !artists.isEmpty,
              let album = (item["album"] as? [String: Any])?["name"] as? String else { return nil }
        let names = artists.compactMap { $0["name"] as? String }
        let artist = names.joined(separator: " / ")
        guard names.count == artists.count, [title, artist, album].allSatisfy({ !$0.isEmpty && $0.count <= 180 && $0.rangeOfCharacter(from: .controlCharacters) == nil }),
              duration.isFinite, duration > 0 else { return nil }
        return Track(id: id, title: title, artist: artist, album: album, duration: duration / 1000)
    }
}

enum PlayerAudioOutput {
    /// Public CoreAudio metadata: a Boolean only, no audio samples or microphone.
    static func isActive(processID: pid_t) -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = processID, object: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object) == noErr, object != 0 else { return nil }
        address.mSelector = kAudioProcessPropertyIsRunningOutput
        var active: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &active) == noErr else { return nil }
        return active != 0
    }
}
