import SwiftUI

struct StylePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var fonts = FontProvisioner.shared
    @StateObject private var backdrop = ViewState(WallpaperBackdrop.Kind.night)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "歌词样式", subtitle: "每种样式都是真实的动态效果。歌词背景始终完全透明，只绘制文字和光效。")
            preview
            gallery
            editor
        }
    }

    // MARK: Preview

    private var preview: some View {
        ZStack(alignment: .topTrailing) {
            WallpaperBackdrop(kind: backdrop.value)
            GeometryReader { proxy in
                let style = model.style.with(fontSize: min(model.style.fontSize, 44), opacity: model.style.opacity)
                LyricStageView(track: .demo, playhead: .stopped, style: style,
                               width: min(640, proxy.size.width - style.effectPadding * 2 - 20), demo: true)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            Picker("背景", selection: $backdrop.value) {
                ForEach(WallpaperBackdrop.Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 230).padding(12)
        }
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke))
    }

    // MARK: Gallery

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(title: "选择样式", symbol: "sparkles")
                Spacer()
                if model.style.isModified { Chip(text: "已在「\(model.style.preset.title)」基础上修改", symbol: "slider.horizontal.3", tint: Color(hex: "FFC857")) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 12)], spacing: 12) {
                ForEach(LyricPreset.allCases) { preset in card(preset) }
            }
        }
    }

    private func card(_ preset: LyricPreset) -> some View {
        let selected = model.style.preset == preset
        return Button {
            model.style = preset.style.with(fontSize: model.style.fontSize, opacity: model.style.opacity)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    WallpaperBackdrop(kind: .night)
                    GeometryReader { proxy in
                        let style = preset.style.with(fontSize: preset == .marquee ? 20 : 21, opacity: 1)
                        LyricStageView(track: .demo, playhead: .stopped, style: style,
                                       width: max(100, proxy.size.width - style.effectPadding * 2 - 6), demo: true, frameRate: 24)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .frame(height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .allowsHitTesting(false)
                HStack(spacing: 6) {
                    Text(preset.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                }
                Text(preset.detail).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary).lineLimit(2).frame(height: 28, alignment: .top)
                HStack(spacing: 4) { ForEach(preset.badges, id: \.self) { Chip(text: $0, tint: Theme.violet) } }
            }
            .padding(10)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.stroke), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(title: "细调", symbol: "slider.horizontal.3")
                Spacer()
                Button("恢复「\(model.style.preset.title)」预设") {
                    model.style = model.style.preset.style.with(fontSize: model.style.fontSize, opacity: model.style.opacity)
                }
                .controlSize(.small).disabled(!model.style.isModified)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) { textCard; colourCard }
                VStack(spacing: 14) { effectCard; motionCard; layoutCard }
            }
        }
    }

    private var textCard: some View {
        Card {
            SectionLabel(title: "文字", symbol: "textformat")
            HStack {
                Picker("字体", selection: $model.style.typeface) {
                    ForEach(LyricTypeface.allCases) { face in Text(face.title).tag(face) }
                }
                Picker("粗细", selection: $model.style.weight) {
                    ForEach(LyricWeight.allCases) { weight in Text(weight.title).tag(weight) }
                }
            }
            .controlSize(.small)
            if !fonts.downloading.isEmpty {
                Text("正在从系统下载字体：\(fonts.downloading.sorted().joined(separator: "、"))…").font(.system(size: 10.5)).foregroundStyle(Color(hex: "FFC857"))
            }
            ValueSlider(title: "字号", value: $model.style.fontSize, range: 18...64, step: 1) { "\(Int($0))" }
            ValueSlider(title: "字距", value: $model.style.letterSpacing, range: 0...8, step: 0.5) { String(format: "%.1f", $0) }
            ValueSlider(title: "不透明度", value: $model.style.opacity, range: 0...1)
            Text("不透明度为 0 时歌词完全隐藏，可从菜单栏或这里恢复。").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
        }
    }

    private var colourCard: some View {
        Card {
            SectionLabel(title: "颜色", symbol: "paintpalette")
            Picker("填充", selection: $model.style.fill) {
                ForEach(LyricFill.allCases) { Text($0.title).tag($0) }
            }
            .controlSize(.small)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                ColorField(title: "未唱颜色", hex: $model.style.baseHex)
                ColorField(title: "已唱颜色", hex: $model.style.sungHex)
                ColorField(title: "发光颜色", hex: $model.style.glowHex)
                ColorField(title: "描边颜色", hex: $model.style.outlineHex)
            }
            if [.gradient, .flow].contains(model.style.fill) {
                Divider().opacity(0.4)
                HStack {
                    Text(model.style.fill == .flow ? "流动色带" : "渐变色").font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Button { if model.style.gradientHexes.count < 7 { model.style.gradientHexes.append(model.style.gradientHexes.last ?? "FFFFFF") } } label: { Image(systemName: "plus") }
                        .disabled(model.style.gradientHexes.count >= 7)
                    Button { if model.style.gradientHexes.count > 2 { model.style.gradientHexes.removeLast() } } label: { Image(systemName: "minus") }
                        .disabled(model.style.gradientHexes.count <= 2)
                }
                .controlSize(.small)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                    ForEach(model.style.gradientHexes.indices, id: \.self) { index in
                        ColorField(title: "第 \(index + 1) 色", hex: Binding(get: { model.style.gradientHexes.indices.contains(index) ? model.style.gradientHexes[index] : "FFFFFF" },
                                                                          set: { if model.style.gradientHexes.indices.contains(index) { model.style.gradientHexes[index] = $0 } }))
                    }
                }
            }
        }
        .onChange(of: model.style.fill) { _, fill in
            if [.gradient, .flow].contains(fill), model.style.gradientHexes.count < 2 {
                model.style.gradientHexes = fill == .flow ? ["FF3B6B", "FFE347", "2EC5FF", "B48CFF"] : ["FFF4C2", "F2C94C"]
            }
        }
    }

    private var effectCard: some View {
        Card {
            SectionLabel(title: "光效", symbol: "sun.max.fill")
            ValueSlider(title: "发光强度", value: $model.style.glow, range: 0...1)
            ValueSlider(title: "字底光晕", value: $model.style.backing, range: 0...1)
            ValueSlider(title: "描边粗细", value: $model.style.outline, range: 0...6, step: 0.5) { String(format: "%.1f", $0) }
            if model.style.fill == .hue || (model.style.typeface == .pixel && model.style.pixelGrid) {
                ValueSlider(title: "灯芯发白", value: $model.style.coreWhite, range: 0...1)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                Toggle("逐字染色", isOn: $model.style.karaoke)
                Toggle("唱到才发光", isOn: $model.style.glowOnSung)
                Toggle("文字阴影", isOn: $model.style.shadow)
                Toggle("霓虹闪烁", isOn: $model.style.flicker)
                Toggle("信号撕裂", isOn: $model.style.rgbSplit)
                if model.style.typeface == .pixel { Toggle("像素灯珠", isOn: $model.style.pixelGrid) }
            }
            .toggleStyle(.checkbox).font(.system(size: 12))
            Text("字底光晕让浅色字在浅色桌面上也清楚（像素灯珠时是灯板的深浅）；发光超过 75% 进入「光污染」档。").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
        }
    }

    private var motionCard: some View {
        Card {
            SectionLabel(title: "动态", symbol: "wind")
            Group {
                Picker("持续动效", selection: $model.style.motion) { ForEach(LyricMotion.allCases) { Text($0.title).tag($0) } }
                Picker("换句动画", selection: $model.style.entrance) { ForEach(LyricEntrance.allCases) { Text($0.title).tag($0) } }
                Picker("粒子", selection: $model.style.particles) { ForEach(LyricParticles.allCases) { Text($0.title).tag($0) } }
                Picker("装饰", selection: $model.style.ornament) { ForEach(LyricOrnament.allCases) { Text($0.title).tag($0) } }
            }
            .controlSize(.small)
            ValueSlider(title: "动画速度", value: $model.style.speed, range: 0.25...3, step: 0.05) { String(format: "%.2f×", $0) }
        }
    }

    private var layoutCard: some View {
        Card {
            SectionLabel(title: "排版", symbol: "text.alignleft")
            Picker("布局", selection: $model.style.layout) { ForEach(LyricLayout.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented)
            if model.style.layout == .ticker {
                Toggle("跑马灯泡", isOn: $model.style.chaseLights).toggleStyle(.checkbox).font(.system(size: 12))
            }
            if model.style.layout == .stack {
                Picker("第二行", selection: $model.style.secondary) { ForEach(LyricSecondary.allCases) { Text($0.title).tag($0) } }
                    .controlSize(.small)
            }
            if model.style.layout != .ticker {
                Picker("对齐", selection: $model.style.alignment) { ForEach(LyricAlignment.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
            }
        }
    }
}
