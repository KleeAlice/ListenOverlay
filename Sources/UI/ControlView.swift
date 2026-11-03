import AppKit
import SwiftUI

enum Theme {
    static let background = Color(hex: "0D1015")
    static let raised = Color.white.opacity(0.045)
    static let stroke = Color.white.opacity(0.085)
    static let accent = Color(hex: "7CE7FF")
    static let violet = Color(hex: "B48CFF")
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.4)
    static let brand = LinearGradient(colors: [Color(hex: "7CE7FF"), Color(hex: "B48CFF"), Color(hex: "FF7BC5")], startPoint: .leading, endPoint: .trailing)
}

enum ControlPage: String, CaseIterable, Identifiable {
    case nowPlaying, style, player, desktop, sources, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nowPlaying: return "正在播放"
        case .style: return "歌词样式"
        case .player: return "小播放器"
        case .desktop: return "桌面显示"
        case .sources: return "来源与字幕"
        case .about: return "关于"
        }
    }
    var symbol: String {
        switch self {
        case .nowPlaying: return "music.note"
        case .style: return "paintpalette.fill"
        case .player: return "play.rectangle.fill"
        case .desktop: return "macwindow"
        case .sources: return "dot.radiowaves.left.and.right"
        case .about: return "info.circle.fill"
        }
    }
}

/// Local view state. The macOS 27 SDK turns `@State` into a macro whose plugin
/// ships only with Xcode, so views keep small state in an object instead.
@MainActor final class ViewState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor final class ControlNavigation: ObservableObject {
    @Published var page: ControlPage = .nowPlaying
}

struct ControlView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: ControlNavigation

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.stroke).frame(width: 1)
            ScrollView {
                Group {
                    switch navigation.page {
                    case .nowPlaying: NowPlayingPage(model: model)
                    case .style: StylePage(model: model)
                    case .player: PlayerStylePage(model: model)
                    case .desktop: DesktopPage(model: model)
                    case .sources: SourcesPage(model: model)
                    case .about: AboutPage()
                    }
                }
                .padding(.horizontal, 30).padding(.top, 34).padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .frame(minWidth: 900, minHeight: 640)
        .background(Theme.background)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .tint(Theme.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.brand).frame(width: 34, height: 34)
                    Image(systemName: "waveform").font(.system(size: 16, weight: .bold)).foregroundStyle(Color(hex: "0D1015"))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("听见").font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("桌面歌词与字幕").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.top, 38).padding(.bottom, 18)
            ForEach(ControlPage.allCases) { page in
                Button { navigation.page = page } label: {
                    HStack(spacing: 10) {
                        Image(systemName: page.symbol).font(.system(size: 13, weight: .semibold)).frame(width: 20)
                            .foregroundStyle(navigation.page == page ? Theme.accent : Theme.secondary)
                        Text(page.title).font(.system(size: 13, weight: navigation.page == page ? .semibold : .regular))
                        Spacer()
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(navigation.page == page ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            nowPlayingMini
            Toggle(isOn: $model.overlay.visible) {
                Text("显示桌面歌词").font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch).controlSize(.small).padding(.horizontal, 10).padding(.bottom, 4)
            Toggle(isOn: $model.overlay.locked) {
                Text("锁定（鼠标穿透）").font(.system(size: 12))
            }
            .toggleStyle(.switch).controlSize(.small).padding(.horizontal, 10).padding(.bottom, 16)
        }
        .padding(.horizontal, 10)
        .frame(width: 210)
        .background(Color.black.opacity(0.25))
    }

    private var nowPlayingMini: some View {
        HStack(spacing: 8) {
            Circle().fill(model.track == nil ? Theme.tertiary : (model.playhead.isPlaying ? Color(hex: "5EF0A0") : Color(hex: "FFC857")))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.track.map { model.display($0.title) } ?? "未在播放").font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Text(model.track?.source.label ?? (model.players.netEase ? "网易云已打开" : model.players.qqMusic ? "QQ 音乐已打开" : "等待播放器"))
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.bottom, 10)
    }
}

// MARK: Shared pieces

struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
            Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
        }
        .padding(.bottom, 18)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
    }
}

struct SectionLabel: View {
    let title: String
    var symbol: String?
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent) }
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.88))
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control
        }
    }
}

struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = Theme.accent
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 3.5)
        .background(tint.opacity(0.13), in: Capsule())
    }
}

struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 74, alignment: .leading)
            Slider(value: $value, in: range, step: step).controlSize(.small)
            Text(format(value)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary).frame(width: 46, alignment: .trailing)
        }
    }
}

/// Colour picker with a hex field.
struct ColorField: View {
    let title: String
    @Binding var hex: String
    @StateObject private var draft = ViewState("")
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 8) {
            ColorPicker(title, selection: Binding(get: { Color(hex: hex) }, set: { if let value = $0.hexString { hex = value } }), supportsOpacity: false)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                TextField("RRGGBB", text: $draft.value).textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
                    .frame(width: 64).focused($editing).onSubmit(commit)
                    .onChange(of: editing) { _, value in if !value { commit() } }
            }
        }
        .onAppear { draft.value = hex }
        .onChange(of: hex) { _, value in draft.value = value }
    }

    private func commit() {
        let value = draft.value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "").uppercased()
        if HexColor.isValid(value) { hex = value }
        draft.value = hex
    }
}

/// A desktop-like backdrop so previews show transparency and contrast honestly.
struct WallpaperBackdrop: View {
    enum Kind: String, CaseIterable, Identifiable {
        case night, dusk, light
        var id: String { rawValue }
        var title: String { self == .night ? "深色桌面" : self == .dusk ? "风景桌面" : "浅色桌面" }
    }
    let kind: Kind
    var body: some View {
        switch kind {
        case .night:
            LinearGradient(colors: [Color(hex: "131A26"), Color(hex: "1F3047"), Color(hex: "2B2140")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .dusk:
            GeometryReader { proxy in
                ZStack {
                    LinearGradient(colors: [Color(hex: "F3A76C"), Color(hex: "C2678F"), Color(hex: "3F4C8C")], startPoint: .top, endPoint: .bottom)
                    Ellipse().fill(Color(hex: "1B2340").opacity(0.85))
                        .frame(width: proxy.size.width * 1.5, height: proxy.size.height * 0.8)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 1.12).blur(radius: 2)
                }
            }
        case .light:
            LinearGradient(colors: [Color(hex: "EEF1F5"), Color(hex: "D7DEE8")], startPoint: .top, endPoint: .bottom)
        }
    }
}
