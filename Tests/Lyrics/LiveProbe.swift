import Foundation

/// Network probe against the real providers. Not part of the offline run:
///   Tests/run_lyrics_tests.sh --live
/// Uses a fresh cache directory so every song is a cold lookup, then repeats two songs to show cache hits.
@main struct LiveProbe {
    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func flag(_ value: Bool) -> String { value ? "是" : "否" }

    static func main() async {
        let root = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : URL(fileURLWithPath: ".build/lyrics/live-cache")
        let directory = root.appendingPathComponent("run-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        let service = LyricsService(cacheDirectory: directory)
        let songs = [
            SongQuery(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269),
            SongQuery(title: "晴天 (Live)", artist: "周杰伦", album: "2004 无与伦比 演唱会", duration: 299),
            SongQuery(title: "后来", artist: "刘若英", duration: 341),
            SongQuery(title: "光年之外", artist: "G.E.M.邓紫棋", duration: 235),
            SongQuery(title: "夜曲", artist: "周杰伦", duration: 226),
            SongQuery(title: "Shape of You", artist: "Ed Sheeran", duration: 233),
            SongQuery(title: "Lemon", artist: "米津玄師", duration: 255),
            SongQuery(title: "稻香", artist: "周杰伦", duration: 223),
            SongQuery(title: "一个不存在的歌名", artist: "无名氏", duration: 200),
        ]
        print("cache: \(directory.path)")
        print("| 歌曲 | 来源 | 匹配 | 同步 | 逐字 | 翻译 | 行数 | 用时 | 说明 |")
        print("|---|---|---|---|---|---|---|---|---|")
        var details: [String] = []
        for query in songs {
            let start = ContinuousClock.now
            let result = await service.lookup(query)
            let elapsed = seconds(since: start)
            let name = "\(query.title) / \(query.artist)"
            if let lyrics = result.lyrics {
                let candidate = lyrics.candidate
                print("| \(name) | \(candidate.source.displayName) | \(candidate.tier.label) | \(flag(lyrics.isSynced)) | \(flag(lyrics.hasWordTiming)) | "
                      + "\(flag(lyrics.hasTranslation)) | \(lyrics.lines.count) | \(String(format: "%.2f s", elapsed)) | \(candidate.note) |")
                details.append("\(name): first line 「\(lyrics.lines.first(where: { !$0.text.isEmpty })?.text ?? lyrics.plainText?.prefix(20).description ?? "")」, "
                               + "credits \(lyrics.credits.count), candidates \(result.candidates.count): "
                               + result.candidates.prefix(4).map { "\($0.source.displayName)·\($0.tier.label)·\($0.title)/\($0.artist)·\($0.duration.map { String(Int($0)) } ?? "?")s" }.joined(separator: "; "))
            } else {
                print("| \(name) | — | 无结果 | — | — | — | 0 | \(String(format: "%.2f s", elapsed)) | 候选 \(result.candidates.count) |")
            }
            if !result.failures.isEmpty { details.append("\(name) failures: \(result.failures.joined(separator: "；"))") }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        print("")
        for line in details { print("- " + line) }

        // Let background completion finish, then show warm lookups.
        try? await Task.sleep(nanoseconds: 7_500_000_000)
        print("")
        for query in songs.prefix(2) {
            let start = ContinuousClock.now
            let result = await service.lookup(query)
            print(String(format: "warm %@: fromCache=%@ %.3f s, candidates %d, source %@", query.title, result.fromCache ? "true" : "false",
                         seconds(since: start), result.candidates.count, result.lyrics?.candidate.source.displayName ?? "—"))
        }
    }
}
