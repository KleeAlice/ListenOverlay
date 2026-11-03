import AVFoundation
import CoreMedia
import Foundation
import Speech

struct SpeechCaption {
    let text: String
    let isFinal: Bool
    let locale: String
}

struct SpeechCandidate {
    let text: String
    let isFinal: Bool
    let locale: String
    let confidence: Double
    let range: CMTimeRange
}

/// Confidence arbitration and reciprocal overlap are informed by Audicap (MIT):
/// https://github.com/ShinoKana/audicap/blob/main/Recognizer.swift.
/// See ThirdPartyNotices for the upstream copyright and license.
enum SpeechChoice {
    static func overlapsCommitted(_ range: CMTimeRange, committed: [CMTimeRange]) -> Bool {
        let start = range.start.seconds, end = range.end.seconds
        guard start.isFinite, end.isFinite, end > start else { return false }
        let intersections = committed.compactMap { other -> (Double, Double)? in
            let lower = max(start, other.start.seconds), upper = min(end, other.end.seconds)
            return upper > lower ? (lower, upper) : nil
        }.sorted { $0.0 < $1.0 }
        var covered = 0.0, cursor = start
        for (lower, upper) in intersections {
            covered += max(0, upper - max(cursor, lower))
            cursor = max(cursor, upper)
        }
        return covered >= (end - start) * 0.5
    }

    static func sameUtterance(_ a: CMTimeRange, _ b: CMTimeRange) -> Bool {
        let overlap = min(a.end.seconds, b.end.seconds) - max(a.start.seconds, b.start.seconds)
        return overlap > 0 && a.duration.seconds > 0 && b.duration.seconds > 0
            && overlap >= a.duration.seconds * 0.5 && overlap >= b.duration.seconds * 0.5
    }

    static func best(_ candidates: [SpeechCandidate], preferred: String?) -> SpeechCandidate? {
        candidates.filter { $0.text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) }
            .max { score($0, preferred: preferred) < score($1, preferred: preferred) }
    }

    private static func score(_ result: SpeechCandidate, preferred: String?) -> Double {
        var score = result.confidence >= 0 ? result.confidence : 0.5
        if result.locale == preferred { score += 0.04 }
        // English recognizers occasionally return Han-only guesses for Chinese audio.
        if result.locale.hasPrefix("en"), result.text.range(of: "\\p{Han}", options: .regularExpression) != nil { score -= 0.3 }
        return score
    }
}

/// On-device recognition only. SpeechAnalyzer does not require SFSpeechRecognizer authorization.
final class SpeechEngine: @unchecked Sendable {
    private final class Lane: @unchecked Sendable {
        let locale: String
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let input: AsyncStream<AnalyzerInput>
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        var resultTask: Task<Void, Never>?

        init(locale: Locale) {
            self.locale = locale.identifier(.bcp47)
            transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [.transcriptionConfidence])
            analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
            (input, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(512))
        }
    }

    enum EngineError: LocalizedError {
        case unavailable, unsupported(String), assets(String), format
        var errorDescription: String? {
            switch self {
            case .unavailable: return "这台 Mac 的本地语音识别目前不可用。需要 Apple 芯片和 macOS 26 或更新版本。"
            case .unsupported(let locale): return "系统暂不支持识别语言：\(locale)。"
            case .assets(let message): return "语音语言包准备失败：\(message)。请检查网络后重试。"
            case .format: return "无法准备语音识别所需的音频格式，请重新开始。"
            }
        }
    }

    private let stateLock = NSLock()
    private let inputLock = NSLock()
    private var generation = 0
    private var accepting = false
    private var lanes: [Lane] = []
    private var audioFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    private var audioFrames: Int64 = 0
    private var reportedOverflow = false
    private var onCaption: ((SpeechCaption) -> Void)?
    private var onStatus: ((String) -> Void)?

    // Arbitration is confined to the main queue.
    private struct Group {
        let id: UUID
        var candidates: [SpeechCandidate]
        var extended: Bool = false
    }
    private var groups: [Group] = []
    private var emitted: [(CMTimeRange, Date)] = []
    private var preferred: String?

    func start(language: String, onCaption: @escaping (SpeechCaption) -> Void,
               onStatus: @escaping (String) -> Void) async throws {
        await stop()
        let token = stateLock.withLock { () -> Int in
            generation += 1
            self.onCaption = onCaption
            self.onStatus = onStatus
            return generation
        }
        await MainActor.run { groups = []; emitted = []; preferred = nil }
        guard SpeechTranscriber.isAvailable else { throw EngineError.unavailable }
        status("正在准备本地语音识别…", token: token)
        let requested = language == "auto" ? ["en-US", "zh-CN"] : [language]
        var prepared: [Lane] = []
        do {
            for identifier in requested {
                try checkCurrent(token)
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
                    throw EngineError.unsupported(identifier)
                }
                try checkCurrent(token)
                prepared.append(Lane(locale: locale))
            }
            let modules: [any SpeechModule] = prepared.map(\.transcriber)
            let assetState = await AssetInventory.status(forModules: modules)
            try checkCurrent(token)
            if assetState != .installed {
                status("首次使用正在下载语音语言包，请保持联网…", token: token)
                do {
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                        try await request.downloadAndInstall()
                    }
                } catch {
                    try checkCurrent(token)
                    throw EngineError.assets(error.localizedDescription)
                }
            }
            try checkCurrent(token)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else { throw EngineError.format }
            try checkCurrent(token)
            for lane in prepared { try await lane.analyzer.prepareToAnalyze(in: format); try checkCurrent(token) }
            inputLock.withLock {
                audioFormat = format; converter = nil; converterSource = nil; audioFrames = 0; reportedOverflow = false
            }
            let installed = stateLock.withLock { () -> Bool in
                guard generation == token else { return false }
                lanes = prepared
                return true
            }
            guard installed else { throw CancellationError() }
            let laneCount = prepared.count
            for lane in prepared {
                lane.resultTask = Task { [weak self, weak lane] in
                    guard let self, let lane else { return }
                    do {
                        for try await result in lane.transcriber.results {
                            guard self.isCurrent(token) else { break }
                            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            let values = result.text.runs.compactMap { $0[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] }
                            let confidence = values.isEmpty ? -1 : values.reduce(0, +) / Double(values.count)
                            let candidate = SpeechCandidate(text: text, isFinal: result.isFinal, locale: lane.locale,
                                                            confidence: confidence, range: result.range)
                            await MainActor.run { self.receive(candidate, token: token, laneCount: laneCount) }
                        }
                    } catch {
                        if !(error is CancellationError), self.isCurrent(token) {
                            self.status("语音识别中断，请停止后重新开始。\(error.localizedDescription)", token: token)
                        }
                    }
                }
                try await lane.analyzer.start(inputSequence: lane.input)
                try checkCurrent(token)
            }
            stateLock.withLock { if generation == token { accepting = true } }
            status(language == "auto" ? "正在聆听系统声音 · 自动识别中英文" : "正在聆听系统声音", token: token)
        } catch {
            for lane in prepared {
                lane.continuation.finish()
                await lane.analyzer.cancelAndFinishNow()
                lane.resultTask?.cancel()
            }
            stateLock.withLock { if generation == token { lanes = []; accepting = false } }
            throw error
        }
    }

    /// Called by the serial capture callback; conversion does not create an unbounded work queue.
    func feed(_ buffer: AVAudioPCMBuffer) {
        let session = stateLock.withLock { accepting ? (generation, lanes) : nil }
        guard let (token, targets) = session else { return }
        inputLock.withLock {
            guard isCurrent(token), let format = audioFormat, buffer.frameLength > 0 else { return }
            let output: AVAudioPCMBuffer
            if buffer.format == format { output = buffer }
            else {
                if converterSource != buffer.format {
                    converter = AVAudioConverter(from: buffer.format, to: format)
                    converterSource = buffer.format
                }
                guard let converter else { status("音频格式转换失败，请重新开始。", token: token); return }
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)) + 32
                guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
                var supplied = false
                var error: NSError?
                let result = converter.convert(to: converted, error: &error) { _, inputStatus in
                    if supplied { inputStatus.pointee = .noDataNow; return nil }
                    supplied = true; inputStatus.pointee = .haveData
                    return buffer
                }
                guard result != .error, error == nil, converted.frameLength > 0 else { return }
                output = converted
            }
            let time = CMTime(value: audioFrames, timescale: CMTimeScale(format.sampleRate))
            audioFrames += Int64(output.frameLength)
            for lane in targets {
                let result = lane.continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: time))
                if case .dropped = result, !reportedOverflow {
                    reportedOverflow = true
                    status("系统繁忙，已跳过积压声音以保持字幕实时。", token: token)
                }
            }
        }
    }

    func stop() async {
        let (token, current): (Int, [Lane]) = stateLock.withLock {
            accepting = false
            if lanes.isEmpty { generation += 1 }
            let current = lanes
            lanes = []
            return (generation, current)
        }
        for lane in current { lane.continuation.finish() }
        await withTaskGroup(of: Void.self) { group in
            for lane in current {
                group.addTask {
                    let deadline = Task {
                        do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                        await lane.analyzer.cancelAndFinishNow()
                    }
                    try? await lane.analyzer.finalizeAndFinishThroughEndOfInput()
                    deadline.cancel()
                    await lane.resultTask?.value
                }
            }
        }
        await MainActor.run {
            if isCurrent(token) {
                let pending = groups; groups = []
                for group in pending { deliver(group, token: token) }
            }
        }
        stateLock.withLock {
            if generation == token { generation += 1; lanes = []; onCaption = nil; onStatus = nil }
        }
    }

    private func checkCurrent(_ token: Int) throws {
        guard isCurrent(token), !Task.isCancelled else { throw CancellationError() }
    }
    private func isCurrent(_ token: Int) -> Bool { stateLock.withLock { generation == token } }
    private func status(_ text: String, token: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let callback = self.stateLock.withLock { self.generation == token ? self.onStatus : nil }
            callback?(text)
        }
    }

    private func receive(_ candidate: SpeechCandidate, token: Int, laneCount: Int) {
        guard isCurrent(token) else { return }
        if laneCount == 1 { emit(candidate, token: token); return }
        if !candidate.isFinal {
            if candidate.locale == (preferred ?? "en-US") { emit(candidate, token: token) }
            return
        }
        guard candidate.confidence < 0 || candidate.confidence >= 0.25 else { return }
        emitted.removeAll { Date().timeIntervalSince($0.1) > 30 }
        guard !SpeechChoice.overlapsCommitted(candidate.range, committed: emitted.map(\.0)) else { return }
        if let index = groups.firstIndex(where: { group in group.candidates.contains { SpeechChoice.sameUtterance($0.range, candidate.range) } }) {
            groups[index].candidates.append(candidate)
            if Set(groups[index].candidates.map(\.locale)).count == laneCount {
                let group = groups.remove(at: index)
                deliver(group, token: token)
            }
        } else {
            let group = Group(id: UUID(), candidates: [candidate])
            groups.append(group)
            schedule(group.id, token: token, delay: 1.2)
        }
    }

    private func schedule(_ id: UUID, token: Int, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isCurrent(token), let index = self.groups.firstIndex(where: { $0.id == id }) else { return }
            var group = self.groups.remove(at: index)
            if !group.extended, (group.candidates.map(\.confidence).max() ?? 0) < 0.8 {
                group.extended = true
                self.groups.append(group)
                self.schedule(id, token: token, delay: 1.8)
            } else { self.deliver(group, token: token) }
        }
    }

    private func deliver(_ group: Group, token: Int) {
        guard isCurrent(token), let best = SpeechChoice.best(group.candidates, preferred: preferred) else { return }
        guard !SpeechChoice.overlapsCommitted(best.range, committed: emitted.map(\.0)) else { return }
        preferred = best.locale
        emitted.append((best.range, Date()))
        emit(best, token: token)
    }

    private func emit(_ candidate: SpeechCandidate, token: Int) {
        let callback = stateLock.withLock { generation == token ? onCaption : nil }
        callback?(SpeechCaption(text: candidate.text, isFinal: candidate.isFinal, locale: candidate.locale))
    }
}
