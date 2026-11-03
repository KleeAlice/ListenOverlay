import AppKit
import Combine
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    let navigation = ControlNavigation()
    private var window: NSWindow!
    private var overlay: OverlayController!
    private var statusItem: NSStatusItem!
    private var observers = Set<AnyCancellable>()
    private var pageObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar app; `--regular` gives it a Dock icon (used for UI checks).
        NSApp.setActivationPolicy(CommandLine.arguments.contains("--regular") ? .regular : .accessory)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "听见"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(srgbRed: 0.05, green: 0.063, blue: 0.082, alpha: 1)
        window.contentMinSize = NSSize(width: 900, height: 640)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("ListenOverlayControl")
        if !window.setFrameUsingName("ListenOverlayControl") { window.center() }

        overlay = OverlayController(model: model, openControls: { [weak self] in self?.showWindow() })
        model.overlayChanged = { [weak self] in self?.overlay.update() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "听见")
        statusItem.button?.toolTip = "听见 · 桌面歌词"
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        installMainMenu()

        pageObserver = NotificationCenter.default.addObserver(forName: .openControlPage, object: nil, queue: .main) { [weak self] note in
            guard let page = note.object as? ControlPage else { return }
            Task { @MainActor in self?.navigation.page = page }
        }
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--simulate"), index + 1 < arguments.count { simulate(arguments[index + 1]) }
        if let index = arguments.firstIndex(of: "--style"), index + 1 < arguments.count, let preset = LyricPreset(rawValue: arguments[index + 1]) {
            model.style = preset.style.with(fontSize: model.style.fontSize, opacity: 1)
        }
        if arguments.contains("--demo") { model.showDemo() }
        if let index = arguments.firstIndex(of: "--player"), index + 1 < arguments.count, let player = MiniPlayerStyle(rawValue: arguments[index + 1]) {
            model.overlay.miniPlayer = player
        }
        if arguments.contains("--no-lyrics") { model.style.opacity = 0 }
        if arguments.contains("--no-glow") { model.style.glow = 0; model.style.shadow = false }
        if let index = arguments.firstIndex(of: "--fps"), index + 1 < arguments.count, let fps = Int(arguments[index + 1]) { model.overlay.frameRate = fps }
        if let index = arguments.firstIndex(of: "--capture-ui"), index + 1 < arguments.count {
            UICapture.run(into: URL(fileURLWithPath: arguments[index + 1]), window: window, overlay: overlay, navigation: navigation)
        }
        if arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { print("PASS: application window and overlay launched"); NSApp.terminate(nil) }
        }
        if !arguments.contains("--background") { showWindow() }
    }

    /// Debug: pretend a player reports "title|artist|album|duration|position".
    private func simulate(_ spec: String) {
        let parts = spec.components(separatedBy: "|")
        guard parts.count >= 5, let duration = Double(parts[3]), let position = Double(parts[4]) else { return }
        model.simulate(TrackObservation(key: "simulated:\(parts[0])|\(parts[1])", title: parts[0], artist: parts[1],
                                        album: parts[2].isEmpty ? nil : parts[2], duration: duration, position: position, date: Date(),
                                        isPlaying: true, source: .nowPlaying(bundle: "debug", app: "模拟播放"), netEaseID: nil))
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(title: "听见", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "听见")
        appMenu.addItem(ClosureMenuItem("打开听见", key: ",") { [weak self] in self?.showWindow() })
        appMenu.addItem(.separator())
        appMenu.addItem(ClosureMenuItem("退出听见", key: "q") { NSApp.terminate(nil) })
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc func showWindow() {
        // The window's views exist only while it is open, so a closed window costs nothing.
        if window.contentView == nil || !(window.contentView is NSHostingView<ControlView>) {
            window.contentView = NSHostingView(rootView: ControlView(model: model, navigation: navigation))
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.window.contentView = NSView() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

extension AppDelegate: NSMenuDelegate {
    /// The status menu is rebuilt on open so every check mark is current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let track = model.track {
            let title = NSMenuItem(title: "\(model.display(track.title)) — \(model.display(track.artist))", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("打开听见…") { [weak self] in self?.showWindow() })
        let visible = ClosureMenuItem("显示桌面歌词") { [weak self] in self?.model.overlay.visible.toggle() }
        visible.state = model.overlay.visible ? .on : .off
        menu.addItem(visible)
        let locked = ClosureMenuItem("锁定歌词（鼠标穿透）") { [weak self] in self?.model.overlay.locked.toggle() }
        locked.state = model.overlay.locked ? .on : .off
        menu.addItem(locked)
        let styles = NSMenu()
        for preset in LyricPreset.allCases {
            let item = ClosureMenuItem(preset.title) { [weak self] in
                guard let self else { return }
                self.model.style = preset.style.with(fontSize: self.model.style.fontSize, opacity: max(0.3, self.model.style.opacity))
            }
            item.state = model.style.preset == preset ? .on : .off
            styles.addItem(item)
        }
        let stylesItem = NSMenuItem(title: "歌词样式", action: nil, keyEquivalent: "")
        stylesItem.submenu = styles
        menu.addItem(stylesItem)
        let timing = NSMenu()
        timing.addItem(ClosureMenuItem("歌词提前 0.5 秒") { [weak self] in self?.model.nudgeOffset(0.5) })
        timing.addItem(ClosureMenuItem("歌词延后 0.5 秒") { [weak self] in self?.model.nudgeOffset(-0.5) })
        timing.addItem(ClosureMenuItem("恢复 0 秒") { [weak self] in self?.model.lyricOffset = 0 })
        let timingItem = NSMenuItem(title: "歌词时间（\(String(format: "%+.1f", model.lyricOffset)) 秒）", action: nil, keyEquivalent: "")
        timingItem.submenu = timing
        menu.addItem(timingItem)
        menu.addItem(ClosureMenuItem("把歌词移回屏幕上方") { [weak self] in self?.overlay.resetPosition(.top); self?.model.overlay.visible = true })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("退出听见", key: "q") { NSApp.terminate(nil) })
    }
}

extension AppModel {
    /// Debug entry used by `--simulate`; behaves like a player reading.
    func simulate(_ observation: TrackObservation) { receiveExternal(observation) }
}

/// Renders the control window pages and overlay panels to PNG for review
/// (no screen recording needed: views draw themselves into bitmaps).
@MainActor enum UICapture {
    static func run(into folder: URL, window: NSWindow, overlay: OverlayController, navigation: ControlNavigation) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pages = ControlPage.allCases
        func shoot(_ view: NSView?, _ name: String) {
            guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
        }
        func step(_ index: Int) {
            guard index < pages.count else {
                shoot(overlay.lyricsPanel.contentView, "overlay-lyrics")
                shoot(overlay.playerPanel.contentView, "overlay-player")
                hovered(MiniPlayerStyle.allCases.filter { $0 != .hidden })
                return
            }
            navigation.page = pages[index]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                shoot(window.contentView, "page-\(index)-\(pages[index].rawValue)")
                step(index + 1)
            }
        }
        // Each mini player under the mouse, in its panel as sized for hover (clipping would show here).
        func hovered(_ styles: [MiniPlayerStyle]) {
            guard let style = styles.first else {
                print("CAPTURED \(folder.path)")
                NSApp.terminate(nil)
                return
            }
            overlay.preparePlayerSnapshot(style)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                overlay.hoverPlayerForSnapshot()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    shoot(overlay.playerPanel.contentView, "overlay-player-\(style.rawValue)-hover")
                    hovered(Array(styles.dropFirst()))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { step(0) }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
