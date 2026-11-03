import AppKit
import SwiftUI

/// Buttons inside overlay panels. The panel resolves clicks itself, so they
/// work in a non-activating window without stealing focus from the player.
enum OverlayAction: String, CaseIterable {
    case smaller, larger, nextStyle, lock, unlock, settings, hide, offsetMinus, offsetPlus, restart, playPause, hidePlayer
}

struct OverlayHotspot: Equatable {
    let action: OverlayAction
    /// SwiftUI global coordinates (top-left origin of the panel content).
    let rect: CGRect
}

struct OverlayHotspotKey: PreferenceKey {
    static let defaultValue: [OverlayHotspot] = []
    static func reduce(value: inout [OverlayHotspot], nextValue: () -> [OverlayHotspot]) { value += nextValue() }
}

extension View {
    func overlayHotspot(_ action: OverlayAction) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: OverlayHotspotKey.self, value: [OverlayHotspot(action: action, rect: proxy.frame(in: .global))])
        })
    }
}

/// Borderless, transparent, non-activating panel: drag to move, double-click
/// to open 听见, click hotspots for actions, right-click for a quick menu.
final class OverlayPanel: NSPanel {
    var onOpenControls: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var onAction: ((OverlayAction) -> Void)?
    var contextMenu: (() -> NSMenu?)?
    var hotspots: [OverlayHotspot] = []
    var draggable = true
    var isDragging: Bool { press?.dragged == true }
    /// A press is in progress; mouse handling must not be switched off under it.
    var isPressed: Bool { press != nil || pressedAction != nil }
    private struct Press {
        let screenPoint: NSPoint
        let windowOrigin: NSPoint
        let clicks: Int
        var dragged = false
    }
    private var press: Press?
    private var pressedAction: OverlayAction?

    override var ignoresMouseEvents: Bool { didSet { if ignoresMouseEvents { press = nil; pressedAction = nil } } }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func make(title: String) -> OverlayPanel {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.setAccessibilityTitle(title)
        return panel
    }

    private func hotspot(at event: NSEvent) -> OverlayAction? {
        guard let height = contentView?.bounds.height else { return nil }
        let p = event.locationInWindow
        let flipped = CGPoint(x: p.x, y: height - p.y)
        return hotspots.last { $0.rect.insetBy(dx: -3, dy: -3).contains(flipped) }?.action
    }

    override func sendEvent(_ event: NSEvent) {
        guard !ignoresMouseEvents else { press = nil; return }
        switch event.type {
        case .leftMouseDown:
            if let action = hotspot(at: event) { pressedAction = action; press = nil; return }
            press = Press(screenPoint: convertPoint(toScreen: event.locationInWindow), windowOrigin: frame.origin, clicks: event.clickCount)
            return
        case .leftMouseDragged:
            guard pressedAction == nil, draggable, var value = press else { return }
            let point = convertPoint(toScreen: event.locationInWindow)
            let dx = point.x - value.screenPoint.x, dy = point.y - value.screenPoint.y
            if !value.dragged && hypot(dx, dy) < 3 { return }
            value.dragged = true; press = value
            let origin = frame.origin
            setFrameOrigin(NSPoint(x: value.windowOrigin.x + dx, y: value.windowOrigin.y + dy))
            onMove?(NSPoint(x: frame.minX - origin.x, y: frame.minY - origin.y))
            return
        case .leftMouseUp:
            if let action = pressedAction {
                pressedAction = nil
                if hotspot(at: event) == action { onAction?(action) }
                return
            }
            let completed = press
            press = nil
            if let completed {
                if completed.dragged { onDragEnded?() }
                else if completed.clicks == 2 { onOpenControls?() }
            }
            return
        case .rightMouseDown:
            if let menu = contextMenu?(), let view = contentView {
                NSMenu.popUpContextMenu(menu, with: event, for: view)
            }
            return
        default: break
        }
        super.sendEvent(event)
    }
}
