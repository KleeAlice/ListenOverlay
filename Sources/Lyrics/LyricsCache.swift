import Foundation

enum LyricsCacheKey {
    /// 「title|artist|duration rounded to 2 s」 on normalized text.
    static func make(_ query: SongQuery) -> String { make(query, bucket: bucket(query.duration)) }

    static func make(_ query: SongQuery, bucket: String) -> String { prefix(query) + bucket }

    static func prefix(_ query: SongQuery) -> String {
        let title = SongText.normalized(query.title), artist = SongText.normalized(query.artist)
        return (title.isEmpty ? query.title.lowercased() : title) + "|" + (artist.isEmpty ? query.artist.lowercased() : artist) + "|"
    }

    static func bucket(_ duration: Double?) -> String {
        guard let duration, duration.isFinite, duration > 0, duration < 86_400 else { return "-" }
        return String(Int((duration / 2).rounded()) * 2)
    }

    /// The query's own bucket first, then its neighbours (players report durations with ±1 s jitter).
    static func nearby(_ query: SongQuery) -> [String] {
        guard let duration = query.duration, duration.isFinite, duration > 0, duration < 86_400 else { return [make(query)] }
        let center = Int((duration / 2).rounded()) * 2
        return [center, center - 2, center + 2].map { make(query, bucket: String($0)) }
    }
}

/// JSON files under the cache directory. Confined to the owning actor.
final class LyricsDiskCache {
    struct StoredLookup: Codable {
        var key: String
        var query: SongQuery
        var chosenID: String?
        var candidates: [LyricsCandidate]
        var savedAt: Date
        var expiresAt: Date
    }

    struct StoredLyrics: Codable {
        var id: String
        var lyrics: Lyrics
        var savedAt: Date
    }

    struct StoredChoice: Codable {
        var query: SongQuery
        var candidate: LyricsCandidate
        var savedAt: Date
    }

    struct StoredOffset: Codable {
        var seconds: Double
        var savedAt: Date
    }

    let root: URL
    let limit: Int
    private let now: @Sendable () -> Date
    private var indexes: [String: [String: Date]] = [:]
    private var negatives: [String: Date]?
    private var choices: [String: StoredChoice]?
    private var offsets: [String: StoredOffset]?

    init(root: URL, limit: Int, now: @escaping @Sendable () -> Date) {
        self.root = root
        self.limit = max(1, limit)
        self.now = now
    }

    // MARK: - Lookups

    func lookup(for query: SongQuery) -> StoredLookup? {
        for key in LyricsCacheKey.nearby(query) {
            guard let entry: StoredLookup = read("lookups", key), entry.key == key else { continue }
            if entry.expiresAt <= now() { continue }
            return entry
        }
        return nil
    }

    func saveLookup(_ entry: StoredLookup) {
        write("lookups", entry.key, entry)
    }

    func updateLookup(key: String, _ change: (inout StoredLookup) -> Void) {
        guard var entry: StoredLookup = read("lookups", key), entry.key == key else { return }
        change(&entry)
        write("lookups", key, entry)
    }

    // MARK: - Lyric contents (by candidate id)

    func lyrics(_ id: String) -> Lyrics? {
        guard let stored: StoredLyrics = read("lyrics", id), stored.id == id else { return nil }
        return stored.lyrics
    }

    func saveLyrics(_ lyrics: Lyrics) {
        write("lyrics", lyrics.candidate.id, StoredLyrics(id: lyrics.candidate.id, lyrics: lyrics, savedAt: now()))
    }

    // MARK: - Negative results

    func isNegative(_ query: SongQuery) -> Bool {
        let store = loadNegatives()
        let date = now()
        return LyricsCacheKey.nearby(query).contains { (store[$0] ?? .distantPast) > date }
    }

    func saveNegative(_ key: String, until: Date) {
        var store = loadNegatives()
        let date = now()
        store = store.filter { $0.value > date }
        store[key] = until
        if store.count > limit {
            for old in store.sorted(by: { $0.value < $1.value }).prefix(store.count - limit) { store[old.key] = nil }
        }
        negatives = store
        writeFile("negative.json", store)
    }

    func clearNegative(_ key: String) {
        var store = loadNegatives()
        guard store.removeValue(forKey: key) != nil else { return }
        negatives = store
        writeFile("negative.json", store)
    }

    // MARK: - Choices and offsets

    func choice(for query: SongQuery) -> StoredChoice? {
        resolve(loadChoices(), query)?.value
    }

    func saveChoice(_ candidate: LyricsCandidate, for query: SongQuery) {
        var store = loadChoices()
        if let existing = resolve(store, query) { store[existing.key] = nil }
        store[LyricsCacheKey.make(query)] = StoredChoice(query: query, candidate: candidate, savedAt: now())
        trim(&store) { $0.savedAt }
        choices = store
        writeFile("choices.json", store)
    }

    func removeChoice(for query: SongQuery) {
        var store = loadChoices()
        var changed = false
        while let existing = resolve(store, query) {
            store[existing.key] = nil
            changed = true
        }
        guard changed else { return }
        choices = store
        writeFile("choices.json", store)
    }

    func offset(for query: SongQuery) -> Double {
        resolve(loadOffsets(), query)?.value.seconds ?? 0
    }

    func setOffset(_ seconds: Double, for query: SongQuery) {
        var store = loadOffsets()
        let key = resolve(store, query)?.key ?? LyricsCacheKey.make(query)
        if seconds.isFinite, seconds != 0 {
            store[key] = StoredOffset(seconds: seconds, savedAt: now())
        } else {
            store[key] = nil
        }
        trim(&store) { $0.savedAt }
        offsets = store
        writeFile("offsets.json", store)
    }

    /// Exact or neighbouring bucket; otherwise the same title and artist with the closest duration (≤ 4 s),
    /// or the only entry when one side's duration is unknown.
    private func resolve<Value>(_ store: [String: Value], _ query: SongQuery) -> (key: String, value: Value)? {
        for key in LyricsCacheKey.nearby(query) {
            if let value = store[key] { return (key, value) }
        }
        let prefix = LyricsCacheKey.prefix(query)
        let matches = store.filter { $0.key.hasPrefix(prefix) }
        guard !matches.isEmpty else { return nil }
        if let duration = query.duration, duration.isFinite, duration > 0 {
            var best: (key: String, value: Value, distance: Double)?
            for (key, value) in matches {
                guard let bucket = Double(key.dropFirst(prefix.count)) else { continue }
                let distance = abs(bucket - duration)
                if distance <= 4, distance < (best?.distance ?? .infinity) { best = (key, value, distance) }
            }
            if let best { return (best.key, best.value) }
            if let unknown = matches.first(where: { $0.key.hasSuffix("|-") }) { return (unknown.key, unknown.value) }
            return nil
        }
        return matches.count == 1 ? (matches.first!.key, matches.first!.value) : nil
    }

    private func trim<Value>(_ store: inout [String: Value], by date: (Value) -> Date) {
        let bound = max(limit * 4, 100)
        guard store.count > bound else { return }
        for old in store.sorted(by: { date($0.value) < date($1.value) }).prefix(store.count - bound) { store[old.key] = nil }
    }

    private func loadNegatives() -> [String: Date] {
        if let negatives { return negatives }
        let value: [String: Date] = readFile("negative.json") ?? [:]
        negatives = value
        return value
    }

    private func loadChoices() -> [String: StoredChoice] {
        if let choices { return choices }
        let value: [String: StoredChoice] = readFile("choices.json") ?? [:]
        choices = value
        return value
    }

    private func loadOffsets() -> [String: StoredOffset] {
        if let offsets { return offsets }
        let value: [String: StoredOffset] = readFile("offsets.json") ?? [:]
        offsets = value
        return value
    }

    // MARK: - Files

    private static func fileName(_ key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex + ".json"
    }

    private func directory(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    private func index(_ folder: String) -> [String: Date] {
        if let index = indexes[folder] { return index }
        var index: [String: Date] = [:]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory(folder), includingPropertiesForKeys: [.contentModificationDateKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        for url in urls where url.pathExtension == "json" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            index[url.lastPathComponent] = date
        }
        indexes[folder] = index
        return index
    }

    private func read<Value: Decodable>(_ folder: String, _ key: String) -> Value? {
        let name = Self.fileName(key)
        guard index(folder)[name] != nil else { return nil }
        let url = directory(folder).appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Value.self, from: data) else {
            // Corrupt or vanished: forget it.
            try? FileManager.default.removeItem(at: url)
            indexes[folder]?[name] = nil
            return nil
        }
        let date = now()
        indexes[folder]?[name] = date
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return value
    }

    private func write<Value: Encodable>(_ folder: String, _ key: String, _ value: Value) {
        let name = Self.fileName(key)
        let folderURL = directory(folder)
        _ = index(folder)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: folderURL.appendingPathComponent(name), options: .atomic)
        } catch {
            return
        }
        let date = now()
        indexes[folder]?[name] = date
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folderURL.appendingPathComponent(name).path)
        prune(folder)
    }

    private func prune(_ folder: String) {
        guard let index = indexes[folder], index.count > limit else { return }
        for (name, _) in index.sorted(by: { $0.value < $1.value }).prefix(index.count - limit) {
            try? FileManager.default.removeItem(at: directory(folder).appendingPathComponent(name))
            indexes[folder]?[name] = nil
        }
    }

    private func readFile<Value: Decodable>(_ name: String) -> Value? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func writeFile<Value: Encodable>(_ name: String, _ value: Value) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: root.appendingPathComponent(name), options: .atomic)
        } catch {
            return
        }
    }
}
