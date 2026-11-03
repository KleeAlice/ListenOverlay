import AppKit
import SwiftUI

struct PlayerStylePage: View {
    @ObservedObject var model: AppModel
    @StateObject private var idleHover = OverlayHover()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "小播放器", subtitle: "歌词下方的小卡片：显示歌曲、进度和来源。鼠标移上去可微调歌词时间。")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14)], spacing: 14) {
                ForEach(MiniPlayerStyle.allCases) { style in
                    let selected = model.overlay.miniPlayer == style
                    Button { model.overlay.miniPlayer = style } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            ZStack {
                                WallpaperBackdrop(kind: .dusk)
                                if style == .hidden {
                                    Text("只显示歌词").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                                } else {
                                    MiniPlayerView(model: model, hover: idleHover, preview: style).scaleEffect(0.86)
                                }
                            }
                            .frame(height: 130)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .allowsHitTesting(false)
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(style.title).font(.system(size: 13, weight: .semibold))
                                    Text(style.detail).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                                }
                                Spacer()
                                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                            }
                        }
                        .padding(10)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.stroke), lineWidth: selected ? 2 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Card {
                SectionLabel(title: "操作", symbol: "hand.tap.fill")
                Text("拖动歌词或小播放器：一起移动 · 双击：打开听见 · 右键：快捷菜单（样式、锁定、歌词时间、位置）")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Text("网易云和 QQ 音乐没有提供公开的播放控制接口，所以小播放器不代替播放器的播放 / 切歌按钮。")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
        }
    }
}

struct DesktopPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "桌面显示", subtitle: "歌词浮在所有窗口上方，背景完全透明；只有文字区域会接收鼠标。")
            Card {
                SettingRow(title: "显示桌面歌词", detail: "也可以从菜单栏的波形图标切换。") {
                    Toggle("", isOn: $model.overlay.visible).labelsHidden().toggleStyle(.switch)
                }
                Divider().opacity(0.4)
                SettingRow(title: "锁定歌词", detail: "鼠标完全穿透歌词和小播放器；把鼠标停在歌词上会出现解锁按钮。") {
                    Toggle("", isOn: $model.overlay.locked).labelsHidden().toggleStyle(.switch)
                }
                Divider().opacity(0.4)
                SettingRow(title: "悬停时显示工具条", detail: "调字号、换样式、锁定、隐藏。") {
                    Toggle("", isOn: $model.overlay.showToolbarOnHover).labelsHidden().toggleStyle(.switch)
                }
            }
            Card {
                SectionLabel(title: "位置与大小", symbol: "arrow.up.and.down.and.arrow.left.and.right")
                SettingRow(title: "位置", detail: model.overlay.placement == .custom ? "已拖动到自定义位置。" : "拖动歌词即可放到任意位置。") {
                    HStack {
                        Button("屏幕上方") { model.overlay.placement = .top }
                        Button("屏幕下方") { model.overlay.placement = .bottom }
                    }
                    .controlSize(.small)
                }
                ValueSlider(title: "歌词宽度", value: $model.overlay.widthFraction, range: 0.3...0.95) { String(format: "%.0f%%", $0 * 100) }
                ValueSlider(title: "字号", value: $model.style.fontSize, range: 18...64, step: 1) { "\(Int($0))" }
            }
            Card {
                SectionLabel(title: "动画流畅度", symbol: "gauge.with.dots.needle.67percent")
                Picker("帧率", selection: $model.overlay.frameRate) {
                    Text("省电 20 帧").tag(20); Text("标准 30 帧").tag(30); Text("流畅 60 帧").tag(60)
                }
                .pickerStyle(.segmented).labelsHidden()
                Text("歌曲暂停或没有播放时，歌词停止重绘，几乎不耗电。").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            Card {
                SectionLabel(title: "何时显示", symbol: "eye")
                Toggle("暂停超过 3 秒时隐藏", isOn: $model.overlay.hideWhenPaused)
                Toggle("找不到歌词时隐藏", isOn: $model.overlay.hideWhenNoLyrics)
                Toggle("繁体歌词转为简体", isOn: $model.sources.simplifiedChinese)
            }
            .toggleStyle(.checkbox).font(.system(size: 12.5))
        }
    }
}

struct SourcesPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "来源与字幕", subtitle: "听见从哪里知道正在放哪首歌，以及是否把声音转成字幕。")
            Card {
                HStack(spacing: 10) {
                    Image(systemName: "cloud.fill").foregroundStyle(Color(hex: "FF4D5E"))
                    Text("网易云音乐").font(.system(size: 14, weight: .semibold))
                    status(model.players.netEase ? "已打开" : "未运行", on: model.players.netEase)
                    Spacer()
                    Toggle("", isOn: $model.sources.followNetEase).labelsHidden().toggleStyle(.switch)
                }
                Text("直接读取网易云在本机记录的当前歌曲与进度：窗口隐藏、最小化、后台切歌都能实时跟上，不需要录屏权限，也不读取账号。")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Card {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.badge.magnifyingglass").foregroundStyle(Color(hex: "31C27C"))
                    Text("QQ 音乐与其他播放器 · 听歌识曲").font(.system(size: 14, weight: .semibold))
                    status(model.players.qqMusic ? "QQ 音乐已打开" : "QQ 音乐未运行", on: model.players.qqMusic)
                    Spacer()
                    Toggle("", isOn: $model.sources.listenToIdentify).labelsHidden().toggleStyle(.switch)
                }
                Text("通过 Mac 正在播放的声音识别歌曲（声音指纹发往网易识曲与 Shazam 核对，原始音频不上传、不保存）。切歌后约 6–12 秒跟上；暂停时歌词随之停住。需要「屏幕与系统录音」权限。")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.listeningStatus.isEmpty, model.sources.listenToIdentify {
                    Text(model.listeningStatus).font(.system(size: 11.5)).foregroundStyle(Theme.accent)
                }
            }
            Card {
                SectionLabel(title: "模式", symbol: "captions.bubble.fill")
                Picker("模式", selection: $model.sources.mode) {
                    ForEach(ListenMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(model.sources.mode.detail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                if model.sources.mode != .lyrics {
                    Picker("字幕语言", selection: $model.sources.captionLanguage) {
                        Text("中英自动").tag("auto"); Text("中文").tag("zh-CN"); Text("English").tag("en-US")
                    }
                    .frame(width: 220).controlSize(.small)
                }
            }
            if model.sources.mode != .lyrics || model.sources.listenToIdentify { captureCard }
        }
    }

    private func status(_ text: String, on: Bool) -> some View {
        Chip(text: text, symbol: on ? "circle.fill" : "circle", tint: on ? Color(hex: "5EF0A0") : Theme.tertiary)
    }

    private var captureCard: some View {
        Card {
            SectionLabel(title: "系统声音", symbol: "speaker.wave.2.fill")
            HStack(spacing: 10) {
                switch model.captureState {
                case .running:
                    LevelMeter(level: model.level)
                    Text("正在聆听 Mac 的声音（不录麦克风，不保存录音）").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                case .starting:
                    ProgressView().controlSize(.small)
                    Text("正在准备…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                case .needsPermission:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: "FFC857"))
                    Text("需要在系统设置中允许「听见」录制屏幕与系统声音，允许后重新打开听见。").font(.system(size: 12))
                    Spacer()
                    Button("打开系统设置", action: model.openRecordingSettings).controlSize(.small)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: "FFC857"))
                    Text(message).font(.system(size: 12)).lineLimit(2)
                    Spacer()
                    Button("重试", action: model.retryCapture).controlSize(.small)
                case .off:
                    Text("未开启").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<14, id: \.self) { index in
                Capsule().fill(Float(index) < min(14, level * 90) ? Theme.accent : Color.white.opacity(0.13))
                    .frame(width: 3, height: CGFloat(5 + (index % 4) * 3))
            }
        }
        .frame(height: 16)
    }
}

struct AboutPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "关于听见", subtitle: "Mac 桌面歌词与实时字幕。")
            Card {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.brand).frame(width: 60, height: 60)
                        Image(systemName: "waveform").font(.system(size: 28, weight: .bold)).foregroundStyle(Color(hex: "0D1015"))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("听见").font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
            }
            Card {
                SectionLabel(title: "歌词从哪里来", symbol: "magnifyingglass")
                Text("同时查询网易云音乐、QQ 音乐、酷狗音乐与 LRCLIB。先找同一首、同一版本；找不到时逐级放宽到同歌手的其他版本、现场版、同名歌曲，只排除明显不相符的结果。每一首都能在「正在播放」里换版本，选择会被记住。")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Card {
                SectionLabel(title: "隐私", symbol: "lock.shield.fill")
                Text("查询歌词时只发送歌名、歌手、专辑和时长。读取网易云播放状态只在本机进行。听歌识曲只发送声音指纹，录音不保存、不上传。歌词与校准偏移缓存在本机。")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
