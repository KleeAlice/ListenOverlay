import AppKit
import SwiftUI

struct NowPlayingPage: View {
    @ObservedObject var model: AppModel
    @StateObject private var showCandidates = ViewState(false)
    @StateObject private var showSearch = ViewState(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "正在播放", subtitle: "跟随播放器切歌，自动查找并同步歌词。")
            if model.track == nil { emptyState } else { hero; lyricsCard }
            if model.track != nil, !model.stage.lines.isEmpty { LyricsListCard(model: model) }
        }
        .sheet(isPresented: $showCandidates.value) { CandidatesSheet(model: model) }
        .sheet(isPresented: $showSearch.value) { SearchSheet(model: model) }
    }

    private var emptyState: some View {
        Card(padding: 24) {
            HStack(alignment: .top, spacing: 18) {
                ZStack {
                    Circle().fill(Theme.brand).frame(width: 64, height: 64).blur(radius: 18).opacity(0.6)
                    Image(systemName: "music.note.list").font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.brand)
                }
                .frame(width: 70, height: 70)
                VStack(alignment: .leading, spacing: 10) {
                    Text("还没有正在播放的歌曲").font(.system(size: 17, weight: .semibold))
                    hint("1.circle.fill", "打开网易云音乐播放任意歌曲 —— 窗口隐藏、后台切歌都能跟上。", model.players.netEase ? "网易云已打开" : nil)
                    hint("2.circle.fill", "QQ 音乐等其他播放器：在「来源与字幕」打开「听歌识曲」。", model.players.qqMusic ? "QQ 音乐已打开" : nil)
                    hint("3.circle.fill", "也可以直接搜索歌词，从现在开始计时。", nil)
                    HStack {
                        Button { showSearch.value = true } label: { Label("搜索歌词", systemImage: "magnifyingglass") }
                            .buttonStyle(.borderedProminent)
                        Button("来源设置") { NotificationCenter.default.post(name: .openControlPage, object: ControlPage.sources) }
                    }
                    .controlSize(.regular).padding(.top, 4)
                }
            }
        }
    }

    private func hint(_ symbol: String, _ text: String, _ status: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
            if let status { Chip(text: status, symbol: "checkmark", tint: Color(hex: "5EF0A0")) }
        }
    }

    private var hero: some View {
        Card(padding: 20) {
            HStack(alignment: .center, spacing: 20) {
                artwork
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Chip(text: model.track?.source.label ?? "", symbol: "dot.radiowaves.left.and.right")
                        Text(model.track?.source.detail ?? "").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                    Text(model.display(model.track?.title ?? "")).font(.system(size: 24, weight: .bold)).lineLimit(2)
                    Text([model.track?.artist, model.track?.album].compactMap { $0 }.filter { !$0.isEmpty }.map(model.display).joined(separator: " · "))
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in progress(context.date) }
                        .padding(.top, 6)
                    if model.track?.source == .manual {
                        HStack {
                            Button("从头开始", action: model.restartManual)
                            Button(model.playhead.isPlaying ? "暂停计时" : "继续计时", action: model.toggleManualPause)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var artwork: some View {
        ZStack {
            if let image = model.artwork.image {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 150, height: 150).blur(radius: 26).opacity(0.65)
                Image(nsImage: image).resizable().scaledToFill().frame(width: 128, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: "2C3E5C"), Color(hex: "4B2D6B")], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 128, height: 128)
                    .overlay(Image(systemName: "music.note").font(.system(size: 44, weight: .semibold)).foregroundStyle(.white.opacity(0.85)))
            }
        }
        .frame(width: 140, height: 140)
    }

    private func progress(_ date: Date) -> some View {
        let duration = model.track?.duration ?? 0
        let position = min(model.playhead.position(at: date), duration > 0 ? duration : .greatestFiniteMagnitude)
        return VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(Theme.brand).frame(width: duration > 0 ? geometry.size.width * min(1, position / duration) : 0)
                }
            }
            .frame(height: 4)
            HStack {
                Text(clock(position)); Spacer()
                Text(model.playhead.isPlaying ? "播放中" : "已暂停").foregroundStyle(model.playhead.isPlaying ? Color(hex: "5EF0A0") : Color(hex: "FFC857"))
                Spacer(); Text(duration > 0 ? clock(duration) : "--:--")
            }
            .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: 420)
    }

    private var lyricsCard: some View {
        Card {
            HStack(alignment: .center) {
                SectionLabel(title: "歌词", symbol: "quote.bubble.fill")
                Spacer()
                Button { showSearch.value = true } label: { Label("搜索", systemImage: "magnifyingglass") }
                Button { showCandidates.value = true } label: { Label("换一个版本（\(model.candidates.count)）", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(model.candidates.isEmpty)
            }
            .controlSize(.small)
            status
            Divider().opacity(0.4)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("歌词时间").font(.system(size: 12.5, weight: .medium))
                    Text("歌词比歌声慢就点「提前」，快就点「延后」；按歌曲分别记住。").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                Spacer()
                Button { model.nudgeOffset(-0.5) } label: { Label("延后", systemImage: "minus") }
                Text(String(format: "%+.1f 秒", model.lyricOffset)).font(.system(size: 13, weight: .semibold).monospacedDigit()).frame(width: 64)
                Button { model.nudgeOffset(0.5) } label: { Label("提前", systemImage: "plus") }
                Button("归零") { model.lyricOffset = 0 }.disabled(model.lyricOffset == 0)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var status: some View {
        switch model.lyricsStatus {
        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在同时查找网易云、QQ 音乐、酷狗和 LRCLIB…").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
            }
        case .found, .instrumental:
            if let lyrics = model.lyrics {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Chip(text: lyrics.candidate.source.displayName, symbol: "music.mic")
                        Chip(text: lyrics.candidate.tier.label, symbol: lyrics.candidate.tier.symbol,
                             tint: lyrics.candidate.tier <= .strong ? Color(hex: "5EF0A0") : Color(hex: "FFC857"))
                        if lyrics.hasWordTiming { Chip(text: "逐字", symbol: "character.cursor.ibeam", tint: Theme.violet) }
                        if lyrics.hasTranslation { Chip(text: "含翻译", symbol: "character.book.closed", tint: Theme.violet) }
                        if model.stage.timing == .estimated { Chip(text: "按时长估算滚动", symbol: "clock", tint: Color(hex: "FFC857")) }
                        if model.lyricsUserChosen { Chip(text: "你选的版本", symbol: "hand.point.up.left.fill", tint: Color(hex: "FF7BC5")) }
                        if model.lyricsFromCache { Chip(text: "已缓存", symbol: "internaldrive", tint: Theme.tertiary) }
                    }
                    Text([model.display(lyrics.candidate.title), model.display(lyrics.candidate.artist), lyrics.candidate.album.map(model.display)]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    if !lyrics.candidate.note.isEmpty {
                        Text(lyrics.candidate.note).font(.system(size: 11.5))
                            .foregroundStyle(lyrics.candidate.tier <= .strong ? Theme.tertiary : Color(hex: "FFC857"))
                    }
                    if model.lyricsUserChosen { Button("恢复自动选择", action: model.resetChoice).controlSize(.small) }
                }
            }
        case .notFound:
            HStack {
                Text("四个歌词库都没有找到可用的歌词。可以手动搜索其他写法（如去掉括号里的版本）。").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("重新查找", action: model.retryLookup).controlSize(.small)
            }
        case .failed(let message):
            HStack {
                Text(message).font(.system(size: 12)).foregroundStyle(Color(hex: "FFC857")).lineLimit(2)
                Spacer()
                Button("重试", action: model.retryLookup).controlSize(.small)
            }
        case .idle:
            Text("等待歌曲…").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
        }
    }
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
}

/// Full lyrics, following the song. Clicking the line being sung re-times the song.
struct LyricsListCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Card {
            HStack {
                SectionLabel(title: "歌词全文", symbol: "text.alignleft")
                Spacer()
                Text("点一下正在唱的那一句，立即校准时间").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let time = model.playhead.position(at: context.date) + model.lyricOffset
                let current = model.stage.index(at: time + StageFrame.lead)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(model.stage.lines.enumerated()), id: \.offset) { index, line in
                                if !line.isGap {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(line.text).font(.system(size: index == current ? 17 : 14, weight: index == current ? .bold : .regular))
                                            .foregroundStyle(index == current ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.white.opacity(0.5)))
                                        if let translation = line.translation, !translation.isEmpty {
                                            Text(translation).font(.system(size: 11.5)).foregroundStyle(.white.opacity(index == current ? 0.7 : 0.32))
                                        }
                                    }
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture { calibrate(to: line) }
                                    .animation(.easeOut(duration: 0.2), value: current)
                                }
                            }
                        }
                        .padding(.vertical, 70)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 260)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                                 .init(color: .black, location: 0.82), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                    .onChange(of: current) { _, value in
                        guard let value else { return }
                        withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(value, anchor: .center) }
                    }
                    .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
                }
            }
        }
    }

    private func calibrate(to line: StageLine) {
        let now = model.playhead.position(at: Date())
        model.lyricOffset = ((line.start - now) * 10).rounded() / 10
    }
}

struct CandidateRow: View {
    let candidate: LyricsCandidate
    let selected: Bool
    let referenceDuration: Double?
    let display: (String) -> String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(display(candidate.title)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if selected { Chip(text: "当前", symbol: "checkmark", tint: Color(hex: "5EF0A0")) }
                }
                Text([display(candidate.artist), candidate.album.map(display)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    Chip(text: candidate.source.displayName, tint: Theme.accent)
                    Chip(text: candidate.tier.label, symbol: candidate.tier.symbol, tint: candidate.tier <= .strong ? Color(hex: "5EF0A0") : Color(hex: "FFC857"))
                    if let duration = candidate.duration {
                        Text(clock(duration) + (referenceDuration.map { abs($0 - duration) >= 1 ? String(format: " · 相差 %.0f 秒", abs($0 - duration)) : " · 时长一致" } ?? ""))
                            .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.tertiary)
                    }
                }
                if !candidate.note.isEmpty { Text(candidate.note).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary).lineLimit(2) }
            }
            Spacer()
            Button(actionTitle, action: action).controlSize(.small).disabled(selected)
        }
        .padding(12)
        .background(selected ? Color.white.opacity(0.07) : Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct CandidatesSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("换一个歌词版本").font(.system(size: 18, weight: .bold))
                    Text("按匹配程度排列；选中后这首歌以后都会用它。").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                if model.lyricsUserChosen { Button("恢复自动选择") { model.resetChoice(); dismiss() } }
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.candidates) { candidate in
                        CandidateRow(candidate: candidate, selected: model.lyrics?.candidate.id == candidate.id,
                                     referenceDuration: model.track?.duration, display: model.display, actionTitle: "使用") {
                            model.use(candidate)
                        }
                    }
                }
            }
        }
        .padding(22).frame(width: 600, height: 520)
        .background(Theme.background).environment(\.colorScheme, .dark)
        .onAppear(perform: model.refreshCandidates)
    }
}

struct SearchSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var attach: Bool { model.track != nil && model.track?.source != .manual }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("搜索歌词").font(.system(size: 18, weight: .bold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack {
                TextField("歌名 歌手", text: $model.searchText).textFieldStyle(.roundedBorder).onSubmit(model.search)
                Button("搜索", action: model.search).disabled(model.searching)
            }
            HStack(spacing: 8) {
                if model.searching { ProgressView().controlSize(.small) }
                Text(attach ? "选中的歌词会用于当前播放的歌曲（按播放器进度同步）。" : "没有检测到播放器：选中后从现在开始计时，可在小播放器上微调。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                Spacer()
                Text(model.searchMessage).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.searchResults) { candidate in
                        CandidateRow(candidate: candidate, selected: model.lyrics?.candidate.id == candidate.id, referenceDuration: model.track?.duration,
                                     display: model.display, actionTitle: attach ? "用于当前歌曲" : "从头开始") {
                            if attach { model.use(candidate) } else { model.playManually(candidate) }
                            dismiss()
                        }
                    }
                }
            }
        }
        .padding(22).frame(width: 620, height: 560)
        .background(Theme.background).environment(\.colorScheme, .dark)
        .onAppear { if model.searchText.isEmpty, let track = model.track { model.searchText = "\(track.title) \(track.artist)" } }
    }
}

extension Notification.Name {
    static let openControlPage = Notification.Name("ListenOverlay.openControlPage")
}
