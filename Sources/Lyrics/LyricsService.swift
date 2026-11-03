import Foundation

struct LyricsServiceConfiguration: Sendable {
    /// Per HTTP request.
    var requestTimeout: TimeInterval = 5
    /// Whole automatic lookup; whatever is best by then is returned.
    var lookupBudget: TimeInterval = 7
    /// From here a synced 精确匹配/匹配 result is returned without waiting for slower providers.
    var softDeadline: TimeInterval = 1.2
    /// From here a synced 相近版本 (or a plain 精确/匹配) result is good enough.
    var relaxedDeadline: TimeInterval = 3.5
    /// Lyric bodies fetched concurrently per provider, and in total per provider.
    var fetchesPerSource = 2
    var maxFetchesPerSource = 4
    var maxResponseBytes = 2_000_000
    /// No plausible lyrics anywhere.
    var negativeTTL: TimeInterval = 30 * 60
    /// Nothing found, but some providers failed.
    var partialFailureTTL: TimeInterval = 120
    /// Every provider failed.
    var outageTTL: TimeInterval = 20
    var cacheLimit = 500
    var memoryLimit = 64
    var sources: [LyricsSource] = LyricsSource.allCases
    var now: @Sendable () -> Date = { Date() }
}

actor LyricsService {
    private let configuration: LyricsServiceConfiguration
    private let http: LyricsHTTP
    private let providers: [LyricsSource: any LyricsProvider]
    private let cache: LyricsDiskCache
    private var memory: [String: Lyrics] = [:]
    private var memoryOrder: [String] = []
    private var jobs: [UInt64: LookupJob] = [:]
    private var jobForKey: [String: UInt64] = [:]
    private var waiterJob: [UInt64: UInt64] = [:]
    private var counter: UInt64 = 0
    /// What this session already showed per song; a background upgrade only applies after the pin expires (or on the next launch).
    private var pins: [String: (id: String, until: Date)] = [:]
    private static let pinDuration: TimeInterval = 20 * 60
    /// Published jobs still collecting slower providers, by cache key.
    private var backgroundJobs: [String: UInt64] = [:]

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ListenOverlay", isDirectory: true).appendingPathComponent("Lyrics", isDirectory: true)
    }

    init(session: URLSession? = nil, cacheDirectory: URL? = nil) {
        self.init(session: session, cacheDirectory: cacheDirectory, configuration: LyricsServiceConfiguration())
    }

    init(session: URLSession?, cacheDirectory: URL?, configuration: LyricsServiceConfiguration) {
        self.configuration = configuration
        http = LyricsHTTP(session: session ?? LyricsHTTP.makeSession(timeout: configuration.requestTimeout), limiter: LyricsRateLimiter(),
                          timeout: configuration.requestTimeout, maxBytes: configuration.maxResponseBytes, now: configuration.now)
        providers = [.netEase: NetEaseLyricsProvider(), .qqMusic: QQMusicLyricsProvider(),
                     .kugou: KugouLyricsProvider(), .lrclib: LRCLIBLyricsProvider()]
        cache = LyricsDiskCache(root: cacheDirectory ?? Self.defaultDirectory, limit: configuration.cacheLimit, now: configuration.now)
    }

    // MARK: - Public API

    /// Never throws. Order: the user's choice, the cache, then all providers in parallel.
    func lookup(_ query: SongQuery) async -> LyricsLookup {
        if Task.isCancelled { return Self.cancelled(query) }
        var failures: [String] = []

        if let choice = cache.choice(for: query) {
            let wasCached = cachedContent(choice.candidate.id) != nil
            do {
                let lyrics = try await fetch(choice.candidate)
                if Task.isCancelled { return Self.cancelled(query) }
                if !wasCached { cache.saveLyrics(lyrics) }
                var candidates = cache.lookup(for: query)?.candidates ?? []
                candidates.removeAll { $0.id == choice.candidate.id }
                candidates.insert(choice.candidate, at: 0)
                return LyricsLookup(query: query, lyrics: lyrics, candidates: candidates, fromCache: wasCached, userChosen: true, failures: [])
            } catch {
                if Task.isCancelled { return Self.cancelled(query) }
                failures.append("所选歌词暂时无法获取：\(LyricsLookupError.describe(error))")
            }
        }

        if let entry = cache.lookup(for: query),
           let candidate = [pinnedID(entry.key), entry.chosenID].compactMap({ $0 })
               .lazy.compactMap({ id in entry.candidates.first { $0.id == id } }).first {
            if var lyrics = cachedContent(candidate.id) {
                lyrics.candidate = candidate
                return LyricsLookup(query: query, lyrics: lyrics, candidates: currentCandidates(entry, chosen: candidate),
                                    fromCache: true, userChosen: false, failures: failures)
            }
            if let lyrics = try? await fetch(candidate) {
                cache.saveLyrics(lyrics)
                return LyricsLookup(query: query, lyrics: lyrics, candidates: currentCandidates(entry, chosen: candidate),
                                    fromCache: true, userChosen: false, failures: failures)
            }
            if Task.isCancelled { return Self.cancelled(query) }
        }

        if cache.isNegative(query) {
            return LyricsLookup(query: query, lyrics: nil, candidates: [], fromCache: true, userChosen: false, failures: failures)
        }

        var result = await runJob(query)
        if !failures.isEmpty { result.failures = failures + result.failures }
        return result
    }

    func fetch(_ candidate: LyricsCandidate) async throws -> Lyrics {
        if var cached = cachedContent(candidate.id) {
            cached.candidate = candidate
            return cached
        }
        guard let provider = providers[candidate.source] else { throw LyricsLookupError.unavailable }
        var lyrics = try await provider.lyrics(for: candidate, http: http)
        guard lyrics.isSynced || !(lyrics.plainText ?? "").isEmpty || lyrics.instrumental else { throw LyricsLookupError.noLyrics }
        lyrics.candidate = candidate
        remember(lyrics)
        return lyrics
    }

    /// Manual search across all providers; tiers describe how much of the typed text a row explains.
    func search(_ text: String, duration: Double? = nil) async -> [LyricsCandidate] {
        let typed = SongText.collapse(text)
        guard !typed.isEmpty else { return [] }
        let request = LyricsSearchRequest(title: typed, artist: "", duration: duration, freeText: typed)
        let http = self.http
        let active = configuration.sources.compactMap { providers[$0] }
        let batches: [[LyricsSearchHit]] = await withTaskGroup(of: [LyricsSearchHit].self) { group in
            for provider in active {
                group.addTask { (try? await provider.search(request, http: http)) ?? [] }
            }
            var all: [[LyricsSearchHit]] = []
            for await batch in group { all.append(batch) }
            return all
        }
        var evaluated: [LyricsEvaluatedHit] = []
        for hit in batches.joined() {
            guard var item = LyricsMatcher.evaluateManual(hit, text: typed, duration: duration, preferred: nil) else { continue }
            if var embedded = hit.embedded {
                embedded.candidate = item.candidate
                guard let accepted = LyricsMatcher.accept(embedded, for: item, duration: duration) else { continue }
                item.candidate = accepted.candidate
                remember(accepted)
            }
            evaluated.append(item)
        }
        var seen = Set<String>()
        var result: [LyricsCandidate] = []
        let keys = Dictionary(evaluated.map { ($0.candidate.id, $0.dedupeKey) }, uniquingKeysWith: { first, _ in first })
        for candidate in LyricsMatcher.ordered(evaluated.map(\.candidate)) {
            guard seen.insert(keys[candidate.id] ?? candidate.id).inserted else { continue }
            result.append(candidate)
            if result.count >= 60 { break }
        }
        return result
    }

    func choose(_ candidate: LyricsCandidate, for query: SongQuery) {
        cache.saveChoice(candidate, for: query)
        if var content = memory[candidate.id] {
            content.candidate = candidate
            cache.saveLyrics(content)
        }
    }

    func clearChoice(for query: SongQuery) {
        cache.removeChoice(for: query)
    }

    func offset(for query: SongQuery) -> Double {
        cache.offset(for: query)
    }

    func setOffset(_ seconds: Double, for query: SongQuery) {
        cache.setOffset(seconds, for: query)
    }

    // MARK: - Content memory

    private func remember(_ lyrics: Lyrics) {
        let id = lyrics.candidate.id
        if memory[id] == nil { memoryOrder.append(id) }
        memory[id] = lyrics
        while memoryOrder.count > configuration.memoryLimit {
            memory[memoryOrder.removeFirst()] = nil
        }
    }

    private func cachedContent(_ id: String) -> Lyrics? {
        if let lyrics = memory[id] { return lyrics }
        guard let lyrics = cache.lyrics(id) else { return nil }
        remember(lyrics)
        return lyrics
    }

    /// The cached list, or — while slower providers are still answering — the live list of that lookup.
    private func currentCandidates(_ entry: LyricsDiskCache.StoredLookup, chosen: LyricsCandidate) -> [LyricsCandidate] {
        guard let id = backgroundJobs[entry.key], let job = jobs[id], !job.finished else { return entry.candidates }
        var candidates = ranked(job, chosen: chosen.id)
        if !candidates.contains(where: { $0.id == chosen.id }) { candidates.insert(chosen, at: 0) }
        return candidates
    }

    private func pinnedID(_ key: String) -> String? {
        guard let pin = pins[key] else { return nil }
        guard pin.until > configuration.now() else {
            pins[key] = nil
            return nil
        }
        return pin.id
    }

    private func pin(_ key: String, _ id: String) {
        let now = configuration.now()
        if pins.count > 256 { pins = pins.filter { $0.value.until > now } }
        pins[key] = (id, now.addingTimeInterval(Self.pinDuration))
    }

    private static func cancelled(_ query: SongQuery) -> LyricsLookup {
        LyricsLookup(query: query, lyrics: nil, candidates: [], fromCache: false, userChosen: false, failures: ["查询已取消"])
    }

    // MARK: - Lookup jobs

    /// One automatic lookup. It publishes as soon as the result is good enough, then keeps
    /// collecting the slower providers (and better-tier lyrics) for the cache until all finish or the budget ends.
    private final class LookupJob {
        let id: UInt64
        let key: String
        let query: SongQuery
        let context: LyricsMatchContext
        let started = ContinuousClock.now
        var launched = false
        var phase = 0
        var waiters: [UInt64: CheckedContinuation<LyricsLookup, Never>] = [:]
        var result: LyricsLookup?
        var hits: [String: LyricsEvaluatedHit] = [:]
        var content: [String: Lyrics] = [:]
        var fetching: Set<String> = []
        var fetchFailed: Set<String> = []
        var fetchesStarted: [LyricsSource: Int] = [:]
        var searching: Set<LyricsSource> = []
        var answered: Set<LyricsSource> = []
        var failed: Set<LyricsSource> = []
        var failures: [String] = []
        var tasks: [Task<Void, Never>] = []
        var identityID: String?
        var finished = false

        init(id: UInt64, key: String, query: SongQuery) {
            self.id = id
            self.key = key
            self.query = query
            context = LyricsMatchContext(query)
        }

        var pending: Int { searching.count + fetching.count }

        func note(_ failure: String) {
            if !failures.contains(failure) { failures.append(failure) }
        }
    }

    private func runJob(_ query: SongQuery) async -> LyricsLookup {
        let key = LyricsCacheKey.make(query)
        counter += 1
        let waiter = counter
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<LyricsLookup, Never>) in
                let job: LookupJob
                if let id = jobForKey[key], let existing = jobs[id], existing.result == nil, !existing.finished {
                    job = existing
                } else {
                    counter += 1
                    job = LookupJob(id: counter, key: key, query: query)
                    jobs[job.id] = job
                    jobForKey[key] = job.id
                }
                job.waiters[waiter] = continuation
                waiterJob[waiter] = job.id
                launch(job)
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiter) }
        }
    }

    private func cancelWaiter(_ waiter: UInt64) {
        guard let id = waiterJob.removeValue(forKey: waiter), let job = jobs[id],
              let continuation = job.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: Self.cancelled(job.query))
        if job.waiters.isEmpty, job.result == nil { abandon(job) }
    }

    private func abandon(_ job: LookupJob) {
        job.finished = true
        for task in job.tasks { task.cancel() }
        job.tasks.removeAll()
        jobs[job.id] = nil
        if jobForKey[job.key] == job.id { jobForKey[job.key] = nil }
    }

    private func launch(_ job: LookupJob) {
        guard !job.launched else { return }
        job.launched = true
        if let id = job.query.netEaseID, id > 0, configuration.sources.contains(.netEase) {
            let identity = LyricsMatcher.identity(for: job.query, id: id)
            job.hits[identity.candidate.id] = identity
            job.identityID = identity.candidate.id
            startFetch(job, identity)
        }
        for source in configuration.sources where providers[source] != nil {
            if let request = Self.searchRequest(job.query, source: source, attempt: 1) { startSearch(job, source, request, attempt: 1) }
        }
        schedule(job, after: configuration.softDeadline, phase: 1)
        schedule(job, after: configuration.relaxedDeadline, phase: 2)
        schedule(job, after: configuration.lookupBudget, phase: 3)
        evaluate(job)
    }

    static func searchRequest(_ query: SongQuery, source: LyricsSource, attempt: Int) -> LyricsSearchRequest? {
        let base = SongText.baseTitle(query.title)
        let title = base.isEmpty ? SongText.collapse(query.title) : base
        guard !title.isEmpty else { return nil }
        let artist = SongText.artists(query.artist).first { !SongText.genericArtists.contains(SongText.normalized($0)) } ?? ""
        switch attempt {
        case 1:
            return LyricsSearchRequest(title: title, artist: artist, duration: query.duration)
        case 2:
            if source == .lrclib {
                return artist.isEmpty ? nil : LyricsSearchRequest(title: title, artist: artist, duration: query.duration, broad: true)
            }
            let simplifiedTitle = SongText.simplified(title), simplifiedArtist = SongText.simplified(artist)
            if simplifiedTitle != title || simplifiedArtist != artist {
                return LyricsSearchRequest(title: simplifiedTitle, artist: simplifiedArtist, duration: query.duration, broad: true)
            }
            // Romanized or aliased artist names: the title alone, every row still has to match.
            return artist.isEmpty ? nil : LyricsSearchRequest(title: title, artist: "", duration: query.duration, broad: true)
        default:
            return nil
        }
    }

    private func schedule(_ job: LookupJob, after seconds: TimeInterval, phase: Int) {
        let id = job.id
        job.tasks.append(Task.detached { [self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.tick(id, phase: phase)
        })
    }

    private func tick(_ id: UInt64, phase: Int) {
        guard let job = jobs[id] else { return }
        job.phase = max(job.phase, phase)
        evaluate(job)
    }

    private func startSearch(_ job: LookupJob, _ source: LyricsSource, _ request: LyricsSearchRequest, attempt: Int) {
        guard let provider = providers[source] else { return }
        job.searching.insert(source)
        let http = self.http, id = job.id
        job.tasks.append(Task.detached(priority: .userInitiated) { [self] in
            let result: Result<[LyricsSearchHit], any Error>
            do { result = .success(try await provider.search(request, http: http)) } catch { result = .failure(error) }
            await self.searchFinished(id, source: source, attempt: attempt, request: request, result: result)
        })
    }

    private func searchFinished(_ id: UInt64, source: LyricsSource, attempt: Int, request: LyricsSearchRequest,
                                result: Result<[LyricsSearchHit], any Error>) {
        guard let job = jobs[id], !job.finished else { return }
        job.searching.remove(source)
        switch result {
        case .success(let hits):
            job.answered.insert(source)
            var plausible = 0
            for hit in hits {
                guard var item = LyricsMatcher.evaluate(hit, context: job.context) else { continue }
                if var embedded = hit.embedded {
                    embedded.candidate = item.candidate
                    guard let accepted = LyricsMatcher.accept(embedded, for: item, duration: job.context.duration) else { continue }
                    item.candidate = accepted.candidate
                    if let existing = job.content[item.candidate.id], LyricsMatcher.effectiveRank(existing) <= LyricsMatcher.effectiveRank(accepted) {
                        continue
                    }
                    job.content[item.candidate.id] = accepted
                    remember(accepted)
                }
                if let existing = job.hits[item.candidate.id],
                   existing.candidate.tier < item.candidate.tier || (existing.candidate.tier == item.candidate.tier && existing.metaScore >= item.metaScore) {
                    continue
                }
                job.hits[item.candidate.id] = item
                plausible += 1
            }
            if plausible == 0, attempt == 1, job.result == nil,
               let next = Self.searchRequest(job.query, source: source, attempt: 2), next != request {
                startSearch(job, source, next, attempt: 2)
            } else {
                startFetches(job, source)
            }
        case .failure(let error):
            if !(error is CancellationError) {
                job.failed.insert(source)
                job.note("\(source.displayName)：\(LyricsLookupError.describe(error))")
            }
        }
        evaluate(job)
    }

    /// Before publishing: the top few per provider (no worse than the best synced tier so far).
    /// Afterwards: only candidates that could replace the published lyrics on the next play
    /// (a better effective rank, or the same tier with word timing the published lyrics lack).
    private func startFetches(_ job: LookupJob, _ source: LyricsSource) {
        let prefix = source.rawValue + ":"
        var slots = configuration.fetchesPerSource - job.fetching.filter { $0.hasPrefix(prefix) }.count
        var started = job.fetchesStarted[source] ?? 0
        guard slots > 0, started < configuration.maxFetchesPerSource else { return }
        let wanted: (LyricsEvaluatedHit) -> Bool
        if let result = job.result {
            guard let published = result.lyrics else { return }
            let rank = LyricsMatcher.effectiveRank(published)
            let wordsMissing = published.isSynced && !published.hasWordTiming && published.candidate.source != job.query.preferredSource
            wanted = { hit in
                Double(hit.candidate.tier.rawValue) < rank
                    || (wordsMissing && hit.candidate.tier == published.candidate.tier && hit.wordHint >= 0.5)
            }
            slots = min(slots, 1)
        } else if let ceiling = job.content.values.filter(\.isSynced).map(\.candidate.tier).min() {
            wanted = { $0.candidate.tier <= ceiling }
        } else {
            wanted = { _ in true }
        }
        let pool = job.hits.values.filter { hit in
            let candidate = hit.candidate
            guard candidate.source == source, job.content[candidate.id] == nil, !job.fetching.contains(candidate.id),
                  !job.fetchFailed.contains(candidate.id) else { return false }
            return wanted(hit)
        }.sorted { a, b in
            if a.candidate.tier != b.candidate.tier { return a.candidate.tier < b.candidate.tier }
            if a.candidate.score != b.candidate.score { return a.candidate.score > b.candidate.score }
            return a.candidate.id < b.candidate.id
        }
        for hit in pool {
            guard slots > 0, started < configuration.maxFetchesPerSource else { break }
            startFetch(job, hit)
            slots -= 1
            started += 1
        }
    }

    private func startFetch(_ job: LookupJob, _ hit: LyricsEvaluatedHit) {
        let candidate = hit.candidate
        guard let provider = providers[candidate.source] else { return }
        job.fetching.insert(candidate.id)
        job.fetchesStarted[candidate.source, default: 0] += 1
        let http = self.http, id = job.id
        job.tasks.append(Task.detached(priority: .userInitiated) { [self] in
            let result: Result<Lyrics, any Error>
            do { result = .success(try await provider.lyrics(for: candidate, http: http)) } catch { result = .failure(error) }
            await self.fetchFinished(id, candidateID: candidate.id, result: result)
        })
    }

    private func fetchFinished(_ id: UInt64, candidateID: String, result: Result<Lyrics, any Error>) {
        guard let job = jobs[id], !job.finished else { return }
        job.fetching.remove(candidateID)
        guard let hit = job.hits[candidateID] else {
            evaluate(job)
            return
        }
        switch result {
        case .success(let lyrics):
            if let accepted = LyricsMatcher.accept(lyrics, for: hit, duration: job.context.duration) {
                job.content[candidateID] = accepted
                job.hits[candidateID]?.candidate = accepted.candidate
                remember(accepted)
            } else {
                // No lyric content or a placeholder: 「明显不相符」.
                job.fetchFailed.insert(candidateID)
                job.hits[candidateID] = nil
            }
        case .failure(let error):
            job.fetchFailed.insert(candidateID)
            if let error = error as? LyricsLookupError, error == .noLyrics {
                job.hits[candidateID] = nil
            } else if !(error is CancellationError) {
                job.note("\(hit.candidate.source.displayName)：获取歌词失败（\(LyricsLookupError.describe(error))）")
            }
        }
        startFetches(job, hit.candidate.source)
        evaluate(job)
    }

    private func evaluate(_ job: LookupJob) {
        guard !job.finished else { return }
        let elapsed = Self.seconds(since: job.started)
        var phase = job.phase
        if elapsed >= configuration.softDeadline { phase = max(phase, 1) }
        if elapsed >= configuration.relaxedDeadline { phase = max(phase, 2) }
        if elapsed >= configuration.lookupBudget { phase = 3 }
        let pending = job.pending
        if job.result == nil {
            let best = LyricsMatcher.best(Array(job.content.values))
            var done = pending == 0 || phase >= 3
            if !done, let best {
                let candidate = best.candidate
                if best.isSynced {
                    if candidate.id == job.identityID {
                        done = true
                    } else if candidate.tier <= .strong, let preferred = job.query.preferredSource, candidate.source == preferred {
                        done = true
                    } else if candidate.tier == .exact, best.hasWordTiming,
                              job.query.preferredSource == nil || job.query.preferredSource == candidate.source {
                        done = true
                    } else if phase >= 1, candidate.tier <= .strong {
                        done = true
                    } else if phase >= 2, candidate.tier <= .version {
                        done = true
                    }
                } else if phase >= 2, candidate.tier <= .strong {
                    done = true
                }
            }
            if done { publish(job, best: best) }
        }
        if job.result != nil, job.pending == 0 || phase >= 3 { finish(job) }
    }

    private func publish(_ job: LookupJob, best: Lyrics?) {
        let candidates = ranked(job, chosen: best?.candidate.id)
        var failures = job.failures
        if best == nil {
            for source in job.searching.sorted(by: { $0.rawValue < $1.rawValue }) {
                failures.append("\(source.displayName)：超过查询时限")
            }
        }
        let lookup = LyricsLookup(query: job.query, lyrics: best, candidates: candidates, fromCache: false, userChosen: false, failures: failures)
        job.result = lookup
        if jobForKey[job.key] == job.id { jobForKey[job.key] = nil }
        let now = configuration.now()
        if let best {
            cache.saveLyrics(best)
            let lifetime: TimeInterval = best.candidate.tier <= .strong ? 30 * 86_400 : 3 * 86_400
            cache.saveLookup(.init(key: job.key, query: job.query, chosenID: best.candidate.id, candidates: candidates,
                                   savedAt: now, expiresAt: now.addingTimeInterval(lifetime)))
            cache.clearNegative(job.key)
            pin(job.key, best.candidate.id)
            backgroundJobs[job.key] = job.id
        } else {
            let ttl: TimeInterval
            if job.pending > 0 || (!job.failed.isEmpty && job.answered.isEmpty) {
                ttl = configuration.outageTTL
            } else if !job.failed.isEmpty {
                ttl = configuration.partialFailureTTL
            } else {
                ttl = configuration.negativeTTL
            }
            cache.saveNegative(job.key, until: now.addingTimeInterval(ttl))
        }
        let waiters = job.waiters
        job.waiters.removeAll()
        for (waiter, continuation) in waiters {
            waiterJob[waiter] = nil
            continuation.resume(returning: lookup)
        }
    }

    /// Background completion: the cache keeps every candidate found. Lyrics that arrived after publishing and are
    /// clearly better (a better rank, or word timing at the same rank) become the cached choice for the next play;
    /// this session keeps showing what it showed (see `pins`).
    private func finish(_ job: LookupJob) {
        guard !job.finished else { return }
        job.finished = true
        for task in job.tasks { task.cancel() }
        job.tasks.removeAll()
        jobs[job.id] = nil
        if jobForKey[job.key] == job.id { jobForKey[job.key] = nil }
        if backgroundJobs[job.key] == job.id { backgroundJobs[job.key] = nil }
        guard let published = job.result?.lyrics else { return }
        var chosen = published
        let publishedRank = LyricsMatcher.effectiveRank(published)
        let upgrades = job.content.values.filter { lyrics in
            guard lyrics.candidate.id != published.candidate.id else { return false }
            let rank = LyricsMatcher.effectiveRank(lyrics)
            if rank < publishedRank { return true }
            return rank == publishedRank && lyrics.isSynced && lyrics.hasWordTiming && !published.hasWordTiming
                && published.candidate.source != job.query.preferredSource
        }
        if let best = LyricsMatcher.best(upgrades) {
            chosen = best
            cache.saveLyrics(best)
        }
        var candidates = ranked(job, chosen: chosen.candidate.id)
        if !candidates.contains(where: { $0.id == published.candidate.id }) {
            candidates.insert(published.candidate, at: min(1, candidates.count))
        }
        guard candidates.map(\.id) != job.result?.candidates.map(\.id) || chosen.candidate.id != published.candidate.id else { return }
        let lifetime: TimeInterval = chosen.candidate.tier <= .strong ? 30 * 86_400 : 3 * 86_400
        let now = configuration.now()
        cache.updateLookup(key: job.key) { entry in
            entry.candidates = candidates
            entry.chosenID = chosen.candidate.id
            entry.savedAt = now
            entry.expiresAt = now.addingTimeInterval(lifetime)
        }
    }

    private func ranked(_ job: LookupJob, chosen: String?) -> [LyricsCandidate] {
        var seen = Set<String>()
        var result: [LyricsCandidate] = []
        if let chosen, let hit = job.hits[chosen] {
            result.append(hit.candidate)
            seen.insert(hit.dedupeKey)
        }
        for candidate in LyricsMatcher.ordered(job.hits.values.map(\.candidate)) where candidate.id != chosen {
            guard seen.insert(job.hits[candidate.id]?.dedupeKey ?? candidate.id).inserted else { continue }
            result.append(candidate)
            if result.count >= 40 { break }
        }
        return result
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
