import AppKit
import SwiftUI

/// Shared pointer state for the overlay panels (polled, so it also works while locked).
@MainActor final class OverlayHover: ObservableObject {
    @Published var lyrics = false
    @Published var player = false
    @Published var locked = false
    /// The player panel is on screen; hidden panels stop animating.
    @Published var playerShown = true
}

/// The small player card under the lyrics.
struct MiniPlayerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hover: OverlayHover
    /// Settings previews show every style side by side.
    var preview: MiniPlayerStyle?

    var body: some View {
        Group {
            switch preview ?? model.overlay.miniPlayer {
            case .capsule: capsule
            case .vinyl: vinyl
            case .glass: glass
            case .album: album
            case .minimal: minimal
            case .hidden: EmptyView()
            }
        }
        .fixedSize()
        .padding(10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("听见小播放器，\(title)，\(subtitle)")
    }

    // MARK: Data

    private var title: String { model.track.map { model.display($0.title) } ?? (model.showingCaptions ? "实时字幕" : "听见") }
    private var subtitle: String {
        guard let track = model.track else { return model.showingCaptions ? model.captureMessage : model.idleMessage }
        return [track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }.map(model.display).joined(separator: " · ")
    }
    private var accent: Color { Color(hex: model.artwork.dominantHex.map { HexColor.mix($0, "FFFFFF", 0.35) } ?? model.style.sungHex) }
    private var duration: Double? { model.track?.duration.flatMap { $0 > 0 ? $0 : nil } }
    private func position(_ date: Date) -> Double { min(model.playhead.position(at: date), duration ?? .greatestFiniteMagnitude) }
    private func progress(_ date: Date) -> Double { duration.map { min(1, max(0, position(date) / $0)) } ?? 0 }
    private func clock(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--:--" }
        return String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }
    private var lyricBadge: String {
        switch model.lyricsStatus {
        case .found: return model.lyrics.map { "\($0.candidate.source.displayName) · \($0.candidate.tier.label)" } ?? ""
        case .searching: return "正在找歌词"
        case .instrumental: return "纯音乐"
        case .notFound: return "暂无歌词"
        case .failed: return "歌词服务重试中"
        case .idle: return model.track?.source.label ?? ""
        }
    }

    // MARK: Pieces

    private func artwork(_ size: CGFloat, round: Bool) -> some View {
        Group {
            if let image = model.artwork.image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [accent.opacity(0.9), Color(hex: "3A2C6B")], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: model.showingCaptions ? "captions.bubble.fill" : "music.note").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: round ? size / 2 : size * 0.22, style: .continuous))
    }

    /// Hover controls that work for every source: nudge lyric timing, open settings.
    private var controls: some View {
        HStack(spacing: 4) {
            if model.track?.source == .manual {
                control("backward.end.fill", .restart, help: "从头")
                control(model.playhead.isPlaying ? "pause.fill" : "play.fill", .playPause, help: "暂停")
            }
            control("minus", .offsetMinus, help: "歌词延后 0.5 秒")
            Text(String(format: "%+.1f", model.lyricOffset)).font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75)).frame(width: 30)
            control("plus", .offsetPlus, help: "歌词提前 0.5 秒")
            control("slider.horizontal.3", .settings, help: "打开听见")
        }
    }

    private func control(_ symbol: String, _ action: OverlayAction, help: String) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            .frame(width: 24, height: 24).background(.white.opacity(0.14), in: Circle())
            .overlayHotspot(action).accessibilityLabel(help)
    }

    private func bar(_ date: Date, width: CGFloat, height: CGFloat = 3) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.16))
            Capsule().fill(accent).frame(width: max(height, width * progress(date)))
                .shadow(color: accent.opacity(0.7), radius: 3)
        }
        .frame(width: width, height: height)
    }

    private func texts(_ titleSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: titleSize, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Text(subtitle).font(.system(size: titleSize * 0.78)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
        }
    }

    // MARK: Styles

    private var capsule: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !model.playhead.isPlaying || !hover.playerShown)) { context in
            HStack(spacing: 10) {
                artwork(34, round: true)
                    .rotationEffect(.degrees(position(context.date) * 24))
                    .overlay(Circle().trim(from: 0, to: progress(context.date)).stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(-4))
                    .padding(4)
                texts(13).frame(width: 170, alignment: .leading)
                Spacer(minLength: 0)
                if hover.player { controls } else {
                    Text("\(clock(model.track == nil ? nil : position(context.date))) / \(clock(duration))")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.leading, 5).padding(.trailing, 14).frame(height: 50)
            .frame(minWidth: 330)
            .background(Capsule().fill(Color.black.opacity(0.32)))
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            .environment(\.colorScheme, .dark)
        }
    }

    private var vinyl: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !model.playhead.isPlaying || !hover.playerShown)) { context in
            HStack(spacing: 14) {
                ZStack(alignment: .topTrailing) {
                    VinylDisc(artwork: AnyView(artwork(30, round: true)), size: 66, angle: position(context.date) * 40)
                    Tonearm(playing: model.playhead.isPlaying).frame(width: 30, height: 46).offset(x: 12, y: -6)
                }
                .frame(width: 78, height: 70)
                VStack(alignment: .leading, spacing: 6) {
                    texts(13.5)
                    HStack(spacing: 8) {
                        bar(context.date, width: 150)
                        Text(clock(model.track == nil ? nil : position(context.date))).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                    }
                }
                .frame(width: 200, alignment: .leading)
                if hover.player { controls }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "2A2320").opacity(0.92), Color(hex: "120F0E").opacity(0.92)], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.1)))
        }
    }

    private var glass: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !hover.playerShown)) { context in
            HStack(spacing: 12) {
                artwork(58, round: false)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(model.track?.source.label ?? "听见").font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2).background(.white.opacity(0.16), in: Capsule())
                        if !lyricBadge.isEmpty { Text(lyricBadge).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1) }
                    }
                    texts(14)
                    HStack(spacing: 8) {
                        bar(context.date, width: 170)
                        Text("\(clock(model.track == nil ? nil : position(context.date))) / \(clock(duration))")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(width: 252, alignment: .leading)
                if hover.player { controls }
            }
            .foregroundStyle(.white)
            .padding(12)
            .glassEffect(.regular.tint(accent.opacity(0.22)), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, .dark)
        }
    }

    private var album: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !hover.playerShown)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 12) {
                artwork(54, round: false).shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 6) {
                    texts(14)
                    HStack(spacing: 8) {
                        bar(context.date, width: 176)
                        Text(clock(model.track == nil ? nil : position(context.date))).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(width: 238, alignment: .leading)
                if hover.player { controls }
            }
            .padding(12)
            .background {
                ZStack {
                    if let image = model.artwork.image {
                        Image(nsImage: image).resizable().scaledToFill()
                            .scaleEffect(1.6 + 0.12 * sin(t * 0.35)).rotationEffect(.degrees(t * 4))
                            .blur(radius: 26).saturation(1.5)
                    } else {
                        AngularGradient(colors: [accent, Color(hex: "7A5CFF"), Color(hex: "FF5FA2"), accent], center: .center, angle: .degrees(t * 20))
                            .blur(radius: 18)
                    }
                    Color.black.opacity(0.32)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.14)))
        }
    }

    private var minimal: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !hover.playerShown)) { context in
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text([title, model.track.map { model.display($0.artist) } ?? ""].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                        .shadow(color: .black.opacity(0.7), radius: 3, y: 1)
                    if hover.player { controls }
                }
                bar(context.date, width: 240, height: 2)
            }
        }
    }
}

/// A record that spins with the song; the sheen stays put so the motion reads.
struct VinylDisc: View {
    let artwork: AnyView
    let size: CGFloat
    let angle: Double
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(hex: "2B2B2E"), Color(hex: "0C0C0D")], center: .center, startRadius: 2, endRadius: size / 2))
            ForEach(0..<7, id: \.self) { ring in
                Circle().stroke(.white.opacity(ring % 2 == 0 ? 0.06 : 0.025), lineWidth: 0.8).padding(CGFloat(ring) * 3.2 + 4)
            }
            artwork
            Circle().fill(Color(hex: "0C0C0D")).frame(width: 5, height: 5)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(angle))
        .overlay(Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.16), .clear, .clear, .white.opacity(0.1), .clear], center: .center)))
        .shadow(color: .black.opacity(0.5), radius: 5, y: 2)
    }
}

/// Swings onto the record while playing, lifts off when paused.
struct Tonearm: View {
    let playing: Bool
    var body: some View {
        Canvas { ctx, size in
            var arm = Path()
            arm.move(to: CGPoint(x: size.width - 5, y: 5))
            arm.addLine(to: CGPoint(x: size.width - 9, y: size.height - 12))
            arm.addLine(to: CGPoint(x: size.width - 16, y: size.height - 4))
            ctx.stroke(arm, with: .color(Color(hex: "C9CDD3")), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: size.width - 10, y: 0, width: 10, height: 10)), with: .color(Color(hex: "8E949C")))
            ctx.fill(Path(roundedRect: CGRect(x: size.width - 20, y: size.height - 8, width: 7, height: 6), cornerRadius: 1.5), with: .color(Color(hex: "E7E9EC")))
        }
        .rotationEffect(.degrees(playing ? 14 : -6), anchor: .topTrailing)
        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: playing)
    }
}
