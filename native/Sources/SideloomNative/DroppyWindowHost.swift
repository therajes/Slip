// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Jordy Spruit (Droppy)
// Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app
// Copied from DroppyCode/App/Window/WindowManager.swift.
// Slip adaptation: application name, content injection and window subclass.

import AppKit
import SwiftUI

@MainActor
enum SlipWindowHost {
    static func make<Content: View>(size: NSSize, @ViewBuilder content: () -> Content) -> SlipWindow {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView, .resizable]
        let frame = NSRect(origin: .zero, size: size)
        let window = SlipWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        window.title = "Slip"
        window.isReleasedWhenClosed = false
        window.animationBehavior = .documentWindow
        window.tabbingMode = .disallowed
        WindowChrome.configure(window)

        let hosting = FrameHostingView(rootView: AnyView(content()))
        hosting.frame = frame
        let container = NSView(frame: frame)
        container.addSubview(hosting)
        window.contentView = container
        return window
    }
}

/// Droppy's frame-driven host, placed inside a plain AppKit content container.
final class FrameHostingView: NSHostingView<AnyView> {
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
        safeAreaRegions = []
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        !isHiddenOrHasHiddenAncestor && super.performKeyEquivalent(with: event)
    }
}
