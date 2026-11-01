import AppKit
import SwiftUI

/// Real AppKit traffic-light buttons, independent of a title-bar frame. The plain
/// window lets the glass surface own its outline without a second native curve.
struct NativeWindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> NativeWindowControlsView { NativeWindowControlsView() }
    func updateNSView(_ nsView: NativeWindowControlsView, context: Context) {}
}

final class NativeWindowControlsView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let styles: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let actions: [(NSWindow.ButtonType, Selector)] = [
            (.closeButton, #selector(closeWindow)),
            (.miniaturizeButton, #selector(minimizeWindow)),
            (.zoomButton, #selector(zoomWindow)),
        ]
        for (index, entry) in actions.enumerated() {
            guard let button = NSWindow.standardWindowButton(entry.0, for: styles) else { continue }
            button.target = self
            button.action = entry.1
            button.frame = NSRect(x: CGFloat(index) * Chrome.trafficLightPitch, y: 0,
                                  width: Chrome.trafficLightDiameter, height: Chrome.trafficLightDiameter)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { nil }

    @objc private func closeWindow() { window?.close() }
    @objc private func minimizeWindow() { window?.miniaturize(nil) }
    @objc private func zoomWindow() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            window?.zoom(nil)
        } else {
            window?.toggleFullScreen(nil)
        }
    }
}

struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragRegionView { WindowDragRegionView() }
    func updateNSView(_ nsView: WindowDragRegionView, context: Context) {}
}

final class WindowDragRegionView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window?.miniaturize(nil) }
            else if action != "None" { window?.zoom(nil) }
        } else {
            window?.performDrag(with: event)
        }
    }
}
