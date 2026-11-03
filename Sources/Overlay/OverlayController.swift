import AppKit
import Combine
import SwiftUI

@MainActor final class OverlayLayout: ObservableObject {
    @Published var width: CGFloat = 820
    @Published var animating = true
}

struct OverlayLyricsRoot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var layout: OverlayLayout

    var body: some View {
        LyricStageView(track: model.overlayTrack, playhead: model.overlayPlayhead, style: model.style,
                       offset: model.showingCaptions ? 0 : model.lyricOffset, width: layout.width, frameRate: Double(model.overlay.frameRate),
                       animating: layout.animating)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("听见桌面歌词")
    }
}

/// Appears above the lyrics on hover: size, style, lock, settings, hide.
struct OverlayToolbarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hover: OverlayHover

    var body: some View {
        HStack(spacing: 3) {
            if hover.locked {
                tool("lock.open.fill", .unlock, title: "解锁歌词")
            } else {
                tool("textformat.size.smaller", .smaller)
                tool("textformat.size.larger", .larger)
                Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 16).padding(.horizontal, 3)
                tool("paintpalette.fill", .nextStyle, title: model.style.preset.title)
                tool("lock.fill", .lock)
                tool("slider.horizontal.3", .settings)
                tool("eye.slash.fill", .hide)
            }
        }
        .padding(4)
        .background(Capsule().fill(.black.opacity(0.42)))
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .padding(6)
    }

    private func tool(_ symbol: String, _ action: OverlayAction, title: String? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            if let title { Text(title).font(.system(size: 11.5, weight: .medium)) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, title == nil ? 0 : 9)
        .frame(minWidth: 28, minHeight: 26)
        .background(.white.opacity(0.1), in: Capsule())
        .overlayHotspot(action)
    }
}

@MainActor final class OverlayController {
    let lyricsPanel = OverlayPanel.make(title: "听见桌面歌词")
    let toolbarPanel = OverlayPanel.make(title: "听见歌词工具条")
    let playerPanel = OverlayPanel.make(title: "听见小播放器")
    let hover = OverlayHover()
    private let layout = OverlayLayout()
    private var toolbarHost: NSHostingView<AnyView>!
    private var playerHost: NSHostingView<AnyView>!
    private let model: AppModel
    private let openControls: () -> Void
    private var poll: Timer?
    private var hoverUntil = Date.distantPast
    /// The player card redraws a moment after its hover state flips; keep measuring until its new size is in.
    private var refitPlayerUntil = Date.distantPast
    private var lockHoverSince: Date?
    private var lyricsSize = CGSize.zero
    private var placedFor = ""
    private var screenObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private var observers = Set<AnyCancellable>()
    /// Text sits below this much transparent space inside the lyrics panel.
    private var topInset: CGFloat {
        let style = model.style
        return style.effectPadding + (style.layout == .stack ? LyricStageMetrics.lineHeight(style) : 0)
    }

    init(model: AppModel, openControls: @escaping () -> Void) {
        self.model = model
        self.openControls = openControls
        // Above the Dock, below the menu bar, so animations never paint over menus.
        let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        for panel in [lyricsPanel, toolbarPanel, playerPanel] {
            panel.level = level
            panel.onOpenControls = openControls
            panel.onAction = { [weak self] action in self?.perform(action) }
            panel.contextMenu = { [weak self] in self?.menu() }
        }
        let lyricsHost = NSHostingView(rootView: OverlayLyricsRoot(model: model, layout: layout))
        toolbarHost = NSHostingView(rootView: AnyView(OverlayToolbarView(model: model, hover: hover)
            .onPreferenceChange(OverlayHotspotKey.self) { [weak self] spots in self?.toolbarPanel.hotspots = spots }))
        playerHost = NSHostingView(rootView: AnyView(MiniPlayerView(model: model, hover: hover)
            .onPreferenceChange(OverlayHotspotKey.self) { [weak self] spots in self?.playerPanel.hotspots = spots }))
        // Panels are sized explicitly; the hosting views must not resize their windows.
        lyricsHost.sizingOptions = []; toolbarHost.sizingOptions = []; playerHost.sizingOptions = []
        lyricsPanel.contentView = lyricsHost; toolbarPanel.contentView = toolbarHost; playerPanel.contentView = playerHost
        toolbarPanel.draggable = false
        lyricsPanel.onMove = { [weak self] delta in self?.move([self?.playerPanel, self?.toolbarPanel], by: delta) }
        playerPanel.onMove = { [weak self] delta in self?.move([self?.lyricsPanel, self?.toolbarPanel], by: delta) }
        lyricsPanel.onDragEnded = { [weak self] in self?.rememberPosition() }
        playerPanel.onDragEnded = { [weak self] in self?.rememberPosition() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update(forcePosition: true) }
        }
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: lyricsPanel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyVisibility() }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMouse() }
        }
        model.$pausedSince.combineLatest(model.$stage).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.update() }.store(in: &observers)
        update(forcePosition: true)
    }

    // MARK: Layout

    private var visibleFrame: NSRect {
        (lyricsPanel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    func update(forcePosition: Bool = false) {
        let settings = model.overlay
        let visible = visibleFrame
        let width = (min(1400, max(360, visible.width * settings.widthFraction)) / 2).rounded() * 2
        if layout.width != width { layout.width = width }
        let size = LyricStageMetrics.size(model.style, width: width)
        if size != lyricsSize {
            let anchorTop = lyricsPanel.frame.maxY
            lyricsSize = size
            lyricsPanel.setContentSize(size)
            if settings.placement == .custom, !forcePosition {
                lyricsPanel.setFrameOrigin(NSPoint(x: lyricsPanel.frame.minX, y: anchorTop - size.height))
            }
        }
        fitPlayer()
        let key = "\(settings.placement.rawValue)|\(Int(width))|\(Int(size.height))|\(settings.miniPlayer.rawValue)|\(model.style.layout.rawValue)"
        if forcePosition || key != placedFor { place(); placedFor = key }

        applyVisibility(forcePosition: forcePosition)
    }

    private func applyVisibility(forcePosition: Bool = false) {
        let settings = model.overlay
        let paused = model.pausedSince.map { Date().timeIntervalSince($0) > 3 } ?? false
        let showLyrics = settings.visible && model.style.opacity > 0.01
            && !(settings.hideWhenPaused && paused && !model.showingCaptions)
            && !(settings.hideWhenNoLyrics && model.track != nil && model.stage.lines.isEmpty && !model.showingCaptions)
        let showPlayer = settings.visible && settings.miniPlayer != .hidden && !(settings.hideWhenPaused && paused)
        for (panel, shown) in [(lyricsPanel, showLyrics), (playerPanel, showPlayer)] {
            if shown { if !panel.isVisible || forcePosition { panel.orderFrontRegardless() } }
            else if panel.isVisible { panel.orderOut(nil) }
        }
        if !showLyrics, toolbarPanel.isVisible { toolbarPanel.orderOut(nil) }
        if hover.playerShown != showPlayer { hover.playerShown = showPlayer }
        let animating = showLyrics && lyricsPanel.occlusionState.contains(.visible)
        if layout.animating != animating { layout.animating = animating }
    }

    /// Ideal SwiftUI size; hosting views only report it while intrinsic sizing is on.
    private func idealSize(_ host: NSHostingView<AnyView>) -> CGSize {
        host.sizingOptions = [.intrinsicContentSize]
        let size = host.fittingSize
        host.sizingOptions = []
        return size
    }

    private func fitPlayer() {
        guard let playerHost else { return }
        let size = idealSize(playerHost)
        guard size.width > 1, size != playerPanel.frame.size else { return }
        let centre = playerPanel.frame.midX, top = playerPanel.frame.maxY
        playerPanel.setContentSize(size)
        if playerPanel.frame.width > 1, top > 0 { playerPanel.setFrameOrigin(NSPoint(x: centre - size.width / 2, y: top - size.height)) }
        placePlayer()
    }

    private func place() {
        let settings = model.overlay, visible = visibleFrame
        let size = lyricsPanel.frame.size
        var origin: NSPoint
        switch settings.placement {
        case .top:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - 12 + topInset - size.height)
        case .bottom:
            let player = settings.miniPlayer == .hidden ? 0 : playerPanel.frame.height
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 10 + player - model.style.effectPadding * 0.6)
        case .custom:
            origin = NSPoint(x: settings.customX ?? visible.midX - size.width / 2, y: settings.customY ?? visible.maxY - size.height)
            // Keep the text itself on screen after a display change.
            origin.x = min(max(origin.x, visible.minX - size.width * 0.4), visible.maxX - size.width * 0.6)
            origin.y = min(max(origin.y, visible.minY - size.height * 0.3), visible.maxY - topInset - 20)
        }
        lyricsPanel.setFrameOrigin(origin)
        placePlayer()
    }

    private func placePlayer() {
        let lyrics = lyricsPanel.frame, size = playerPanel.frame.size
        let pad = model.style.effectPadding
        let x: CGFloat
        switch model.style.alignment {
        case .leading: x = lyrics.minX + pad - 10
        case .center: x = lyrics.midX - size.width / 2
        case .trailing: x = lyrics.maxX - pad - size.width + 10
        }
        playerPanel.setFrameOrigin(NSPoint(x: x, y: lyrics.minY + pad * 0.6 - size.height))
    }

    private func move(_ panels: [OverlayPanel?], by delta: NSPoint) {
        for panel in panels.compactMap({ $0 }) {
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX + delta.x, y: panel.frame.minY + delta.y))
        }
    }

    private func rememberPosition() {
        var settings = model.overlay
        settings.placement = .custom
        settings.customX = lyricsPanel.frame.minX; settings.customY = lyricsPanel.frame.minY
        placedFor = "\(OverlayPlacement.custom.rawValue)|\(Int(layout.width))|\(Int(lyricsSize.height))|\(settings.miniPlayer.rawValue)|\(model.style.layout.rawValue)"
        model.overlay = settings
    }

    /// Snapshots only: stop following the pointer and settle on one player style, not hovered.
    func preparePlayerSnapshot(_ style: MiniPlayerStyle) {
        poll?.invalidate()
        hover.player = false
        model.overlay.miniPlayer = style
        update()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.fitPlayer() }
    }

    /// Snapshots only: the pointer arrives on the player (with polling stopped, only the first re-measure runs).
    func hoverPlayerForSnapshot() { setPlayerHover(true, at: Date()) }

    /// Hover adds controls to the player card, but SwiftUI redraws it only on its next pass, so measuring
    /// at once would keep the old size and clip the card. Measure right after that pass and on the next few polls.
    private func setPlayerHover(_ hovered: Bool, at now: Date) {
        hover.player = hovered
        DispatchQueue.main.async { [weak self] in self?.fitPlayer() }
        refitPlayerUntil = now.addingTimeInterval(0.6)
    }

    func resetPosition(_ placement: OverlayPlacement) {
        model.overlay.placement = placement
        update(forcePosition: true)
    }

    // MARK: Pointer

    /// The words currently on screen, in lyrics-panel coordinates (top-left origin).
    private func currentTextRect(at now: Date) -> CGRect {
        let time = model.overlayPlayhead.position(at: now) + (model.showingCaptions ? 0 : model.lyricOffset)
        return LyricStagePainter(track: model.overlayTrack, time: time, clock: 0, style: model.style, width: layout.width).textRect()
    }

    private func screenRect(_ rect: CGRect, in panel: NSPanel) -> CGRect {
        guard !rect.isNull, let height = panel.contentView?.bounds.height else { return .null }
        return panel.convertToScreen(CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height))
    }

    private func pollMouse() {
        let mouse = NSEvent.mouseLocation, now = Date()
        let settings = model.overlay
        // Only work out where the words are when the pointer is near the lyrics.
        let near = lyricsPanel.isVisible && lyricsPanel.frame.insetBy(dx: -24, dy: -24).contains(mouse)
        let text = near || toolbarPanel.isVisible ? screenRect(currentTextRect(at: now), in: lyricsPanel) : .null
        let overText = !text.isNull && text.insetBy(dx: -12, dy: -8).contains(mouse)
        let overToolbar = toolbarPanel.isVisible && toolbarPanel.frame.insetBy(dx: -4, dy: -6).contains(mouse)
        let overPlayer = playerPanel.isVisible && playerPanel.frame.insetBy(dx: 8, dy: 8).contains(mouse)
        let locked = settings.locked
        if overText || overToolbar { hoverUntil = now.addingTimeInterval(0.45) }
        let lyricsHover = now < hoverUntil
        if locked, overText { lockHoverSince = lockHoverSince ?? now } else if !overToolbar { lockHoverSince = nil }

        if hover.locked != locked { hover.locked = locked }
        if hover.lyrics != lyricsHover { hover.lyrics = lyricsHover }
        if hover.player != (overPlayer && !locked) { setPlayerHover(overPlayer && !locked, at: now) }
        if now < refitPlayerUntil { fitPlayer() }

        let lyricsIgnores = locked || !(overText || lyricsPanel.isDragging)
        if !lyricsPanel.isPressed, lyricsPanel.ignoresMouseEvents != lyricsIgnores { lyricsPanel.ignoresMouseEvents = lyricsIgnores }
        if !playerPanel.isPressed, playerPanel.ignoresMouseEvents != locked { playerPanel.ignoresMouseEvents = locked }

        let showToolbar = lyricsPanel.isVisible && !lyricsPanel.isDragging && !playerPanel.isDragging && (locked
            ? (lockHoverSince.map { now.timeIntervalSince($0) > 0.6 } ?? false) || overToolbar
            : lyricsHover && settings.showToolbarOnHover)
        if showToolbar {
            let size = idealSize(toolbarHost)
            if size.width > 1, size != toolbarPanel.frame.size { toolbarPanel.setContentSize(size) }
            let anchor = text.isNull ? lyricsPanel.frame : text
            let panelSize = toolbarPanel.frame.size
            let above = anchor.maxY + panelSize.height - 4 < visibleFrame.maxY
            let origin = NSPoint(x: anchor.midX - panelSize.width / 2, y: above ? anchor.maxY - 2 : anchor.minY - panelSize.height + 2)
            if !toolbarPanel.isVisible || abs(toolbarPanel.frame.minX - origin.x) > 1 || abs(toolbarPanel.frame.minY - origin.y) > 1 {
                toolbarPanel.setFrameOrigin(origin)
            }
            if !toolbarPanel.isVisible { toolbarPanel.orderFrontRegardless() }
        } else if toolbarPanel.isVisible, !toolbarPanel.isPressed {
            toolbarPanel.orderOut(nil)
        }
        if settings.hideWhenPaused { applyVisibility() }
    }

    // MARK: Actions

    func perform(_ action: OverlayAction) {
        switch action {
        case .smaller: model.style.fontSize = max(18, model.style.fontSize - 2)
        case .larger: model.style.fontSize = min(64, model.style.fontSize + 2)
        case .nextStyle:
            let all = LyricPreset.allCases
            let next = all[((all.firstIndex(of: model.style.preset) ?? 0) + 1) % all.count]
            model.style = next.style.with(fontSize: model.style.fontSize, opacity: model.style.opacity)
        case .lock: model.overlay.locked = true; lockHoverSince = nil
        case .unlock: model.overlay.locked = false
        case .settings: openControls()
        case .hide: model.overlay.visible = false
        case .offsetMinus: model.nudgeOffset(-0.5)
        case .offsetPlus: model.nudgeOffset(0.5)
        case .restart: model.restartManual()
        case .playPause: model.toggleManualPause()
        case .hidePlayer: model.overlay.miniPlayer = .hidden
        }
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("打开听见…") { [weak self] in self?.openControls() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(model.overlay.locked ? "解锁歌词" : "锁定歌词（鼠标穿透）") { [weak self] in
            self?.perform(self?.model.overlay.locked == true ? .unlock : .lock)
        })
        let styles = NSMenu()
        for preset in LyricPreset.allCases {
            let item = ClosureMenuItem(preset.title) { [weak self] in
                guard let self else { return }
                self.model.style = preset.style.with(fontSize: self.model.style.fontSize, opacity: self.model.style.opacity)
            }
            item.state = model.style.preset == preset ? .on : .off
            styles.addItem(item)
        }
        menu.addItem(submenu("歌词样式", styles))
        let players = NSMenu()
        for style in MiniPlayerStyle.allCases {
            let item = ClosureMenuItem(style.title) { [weak self] in self?.model.overlay.miniPlayer = style }
            item.state = model.overlay.miniPlayer == style ? .on : .off
            players.addItem(item)
        }
        menu.addItem(submenu("小播放器", players))
        let timing = NSMenu()
        timing.addItem(ClosureMenuItem("歌词提前 0.5 秒") { [weak self] in self?.model.nudgeOffset(0.5) })
        timing.addItem(ClosureMenuItem("歌词延后 0.5 秒") { [weak self] in self?.model.nudgeOffset(-0.5) })
        timing.addItem(ClosureMenuItem("恢复 0 秒") { [weak self] in self?.model.lyricOffset = 0 })
        menu.addItem(submenu("歌词时间（当前 \(String(format: "%+.1f", model.lyricOffset)) 秒）", timing))
        let size = NSMenu()
        size.addItem(ClosureMenuItem("放大") { [weak self] in self?.perform(.larger) })
        size.addItem(ClosureMenuItem("缩小") { [weak self] in self?.perform(.smaller) })
        menu.addItem(submenu("字号", size))
        let position = NSMenu()
        for placement in [OverlayPlacement.top, .bottom] {
            position.addItem(ClosureMenuItem(placement.title) { [weak self] in self?.resetPosition(placement) })
        }
        menu.addItem(submenu("位置", position))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("隐藏桌面歌词") { [weak self] in self?.perform(.hide) })
        return menu
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func run() { handler() }
}
