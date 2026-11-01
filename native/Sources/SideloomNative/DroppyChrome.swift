// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) Jordy Spruit (Droppy). All rights reserved.
// Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app
// Adapted for Slip from DroppyCode/UI/Chrome/Chrome.swift and WindowChrome.swift.
// Modified: neutral system appearance, accessibility, and Slip navigation.

import AppKit
import QuartzCore
import SwiftUI

enum Chrome {
    static let windowCornerRadius: CGFloat = 26
    static let sheetInset: CGFloat = 0
    static let trafficLightDiameter: CGFloat = 14
    static let trafficLightSpacing: CGFloat = 9
    static var trafficLightPitch: CGFloat { trafficLightDiameter + trafficLightSpacing }
    static let trafficLightLeading: CGFloat = 18
    static let trafficLightTop: CGFloat = 16
    static let chromeHorizontalPadding: CGFloat = 14
    static let chromeTopPadding: CGFloat = 12
    static let capsuleHeight: CGFloat = 32
    static let primaryText = Color(nsColor: .labelColor)
    static func overlay(_ opacity: Double) -> Color { primaryText.opacity(opacity) }
    static let secondaryText = primaryText.opacity(0.7)
    static var glassTint: Color { ThemeManager.spec.surface }
    static var accent: Color { ThemeManager.spec.accent ?? Color(nsColor: .controlAccentColor) }
    static let iconFont: Font = .system(.callout, weight: .semibold)
    static let inlineIconFont: Font = .system(.subheadline, weight: .semibold)
    static let capsuleContentHeight: CGFloat = 28
    static let capsuleVerticalPadding: CGFloat = 2
    static let capsuleHorizontalPadding: CGFloat = 12
    static let iconCapsuleInnerPadding: CGFloat = 3
    static let dividerHeight: CGFloat = 14
    static var trafficLightsWidth: CGFloat { trafficLightDiameter * 3 + trafficLightSpacing * 2 }
    static let trafficLightClearance: CGFloat = 10
    static let rowHeight: CGFloat = 28
    static let rowCornerRadius: CGFloat = 7
    static let rowHorizontalPadding: CGFloat = 8
    static let iconSize: CGFloat = 20
    static let symbolSize: CGFloat = 14
    static let listInset: CGFloat = 10
    static let cardCornerRadius: CGFloat = 16
    static let sectionHeaderSpacing: CGFloat = 10
    static let rowControlTrailingPadding: CGFloat = 10
    static var panelSlide: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.18) : .spring(response: 0.32, dampingFraction: 0.9)
    }
    static var hover: Animation { .easeOut(duration: 0.1) }
}

extension View {
    func chromeGlassCircle() -> some View {
        modifier(ChromeGlassSurface(shape: .circle))
    }

    func chromeGlassFieldCapsule() -> some View {
        modifier(ChromeGlassSurface(shape: .capsule, isInteractive: false))
    }

    func detailSheet() -> some View {
        modifier(DetailSheetModifier())
    }

    func chromeGlassCapsule() -> some View {
        modifier(ChromeGlassSurface(shape: .capsule))
    }

    func floatingGlass<S: InsettableShape>(
        _ shape: S,
        tint: Color? = nil,
        rim: Color? = nil,
        isInteractive: Bool = false,
        hiddenRimBottom: CGFloat = 0
    ) -> some View {
        modifier(FloatingGlassSurface(shape: shape, tint: tint, rim: rim, isInteractive: isInteractive, hiddenRimBottom: hiddenRimBottom))
    }
}


/// Sets up the hosting window the way Droppy's settings window is built: a transparent title bar over
/// a clear window, a SwiftUI glass pane underneath, and AppKit's own traffic lights pinned to the chrome,
/// with the title bar kept reaching down to them so they take their clicks wherever they are pinned.
struct WindowChromeConfigurator: NSViewRepresentable {
    var sidebarVisible = true
    var sidebarDragging = false
    var performanceMode = false

    func makeNSView(context: Context) -> WindowChromeProbeView {
        let view = WindowChromeProbeView()
        view.performanceMode = performanceMode
        return view
    }

    func updateNSView(_ nsView: WindowChromeProbeView, context: Context) {
        nsView.sidebarDragging = sidebarDragging
        nsView.sidebarVisible = sidebarVisible
        nsView.performanceMode = performanceMode
    }
}

final class WindowChromeProbeView: NSView {
    var sidebarDragging = false
    var performanceMode = false {
        didSet {
            guard performanceMode != oldValue, let window else { return }
            WindowChrome.setPerformanceMode(performanceMode, on: window)
        }
    }
    var sidebarVisible = true {
        didSet {
            guard sidebarVisible != oldValue, let window, !window.styleMask.contains(.fullScreen) else { return }
            scheduleTrafficLightPlacement(animated: true)
        }
    }

    /// The title bar whose height this view keeps (see `WindowChrome.fitTitlebar`), or nil until
    /// the view is in a window.
    private weak var titlebarContainer: NSView?
    /// The window the didEndLiveResize and fullscreen observers belong to, so moving windows never stack them.
    private weak var observedWindow: NSWindow?
    /// A fit is queued for after AppKit's current layout pass.
    private var titlebarFitPending = false
    private var trafficLightPlacementPending = false
    private var pendingPlacementAnimated = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let titlebarContainer {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: titlebarContainer)
            self.titlebarContainer = nil
        }
        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didEndLiveResizeNotification, object: observedWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.willEnterFullScreenNotification, object: observedWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didEnterFullScreenNotification, object: observedWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didExitFullScreenNotification, object: observedWindow)
            self.observedWindow = nil
        }
        guard let window else { return }
        WindowChrome.configure(window)
        WindowChrome.setPerformanceMode(performanceMode, on: window)
        if window.styleMask.contains(.fullScreen) {
            WindowChrome.resetTrafficLights(on: window)
        } else {
            scheduleTrafficLightPlacement(animated: false)
        }
        // The probe's previous window keeps its own observer; moving windows register fresh.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidEndLiveResize), name: NSWindow.didEndLiveResizeNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillEnterFullScreen), name: NSWindow.willEnterFullScreenNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidEnterFullScreen), name: NSWindow.didEnterFullScreenNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidExitFullScreen), name: NSWindow.didExitFullScreenNotification, object: window
        )
        observedWindow = window
        // AppKit tiles the title bar back to its own height when the window resizes, and with
        // that the buttons level with the chrome are out of its reach again. It says so through
        // the container's frame, and the fit goes back on.
        guard let container = WindowChrome.titlebarContainer(of: window) else { return }
        container.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(titlebarFrameDidChange), name: NSView.frameDidChangeNotification, object: container
        )
        titlebarContainer = container
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// These calls arrive while SwiftUI renders the window, and forcing the title bar's layout
    /// there is a re-entrant layout AppKit skips; placing the buttons on the next turn lets
    /// that pass run. Requests in one turn merge, animated only if every one of them was.
    private func scheduleTrafficLightPlacement(animated: Bool) {
        pendingPlacementAnimated = trafficLightPlacementPending ? pendingPlacementAnimated && animated : animated
        guard !trafficLightPlacementPending else { return }
        trafficLightPlacementPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            trafficLightPlacementPending = false
            guard let window else { return }
            WindowChrome.placeTrafficLights(
                on: window,
                sidebarVisible: sidebarVisible,
                animated: pendingPlacementAnimated && !window.inLiveResize && !sidebarDragging
            )
        }
    }

    /// Runs inside AppKit's own tiling of the title bar; the fit waits for it to finish, so the
    /// container is never resized halfway through a pass that is laying out its subviews.
    /// Cheap per frame during a live resize: a container that already has the wanted
    /// height queues nothing, and the fit itself never lays out or draws synchronously.
    @objc private func titlebarFrameDidChange(_ notification: Notification) {
        guard let container = notification.object as? NSView,
              let window,
              !window.styleMask.contains(.fullScreen),
              container.frame.height < WindowChrome.titlebarHeight,
              !titlebarFitPending else { return }
        titlebarFitPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            titlebarFitPending = false
            if let currentWindow = self.window, !currentWindow.styleMask.contains(.fullScreen) {
                WindowChrome.fitTitlebar(of: currentWindow)
            }
        }
    }

    /// One final unanimated placement once the window settles, so the buttons end up
    /// correct after following the drag without animations.
    @objc private func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !window.styleMask.contains(.fullScreen) else { return }
        WindowChrome.placeTrafficLights(on: window, sidebarVisible: sidebarVisible, animated: false)
        WindowChrome.fitTitlebar(of: window)
    }

    @objc private func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        WindowChrome.resetTrafficLights(on: window)
    }

    @objc private func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        WindowChrome.resetTrafficLights(on: window)
    }

    @objc private func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        WindowChrome.placeTrafficLights(on: window, sidebarVisible: sidebarVisible, animated: false)
        WindowChrome.fitTitlebar(of: window)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
enum WindowChrome {
    private static let leadingIdentifier = "droppycode.trafficLight.leading"
    private static let topIdentifier = "droppycode.trafficLight.top"
    private static let widthIdentifier = "droppycode.trafficLight.width"
    private static let heightIdentifier = "droppycode.trafficLight.height"
    /// Windows `configure` has already set up. Weak, so a closed window drops out on its own.
    private static let configuredWindows = NSHashTable<NSWindow>.weakObjects()

    static func configure(_ window: NSWindow) {
        // Idempotent: viewDidMoveToWindow fires on every reorder, so the setup pays once.
        if configuredWindows.contains(window) { return }
        configuredWindows.add(window)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // A focused window draws a separator under the title bar that cuts through the rounded corner.
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.invalidateShadow()
        // AppKit owns the key view loop, rebuilt only when Tab navigation asks for it.
        // Left off, SwiftUI rebuilds the loop itself, synchronously, every time a
        // focusable view or an AppKit view in the window changes shape: it walks every
        // focus item in reading order, and on macOS 26 that walk never ended inside the
        // composer's follow-up queue tab, so the main thread stood still until a force
        // quit (the Sept 15 2026 freezes, `FocusBridge.updateDefaultKeyViewLoop` at the
        // top of every sample). With this on, SwiftUI only marks the loop dirty and keeps
        // its focus items by the finite, group-based route; nothing is rebuilt during
        // layout. Full Keyboard Access is what makes Tab move between controls at all,
        // and the loop is still rebuilt for it, just on demand.
        window.autorecalculatesKeyViewLoop = true
    }

    /// Keep AppKit's clear, shadowed window; SwiftUI owns the opaque fill and rounded corners.
    /// Refresh the system shadow when performance mode changes the fill.
    static func setPerformanceMode(_ performanceMode: Bool, on window: NSWindow) {
        window.invalidateShadow()
    }

    /// Where the buttons sit with the sidebar hidden: level with the chat's chrome capsules,
    /// which then step aside for them, and inset like the chrome is from the sheet's edge.
    static var collapsedTrafficLightTop: CGFloat {
        Chrome.sheetInset + Chrome.chromeTopPadding + (Chrome.capsuleHeight - Chrome.trafficLightDiameter) / 2
    }

    /// How far down the title bar reaches: to the bottom of the chrome row, so the buttons are
    /// inside it in either placement. AppKit only hands a click or a hover to a button within the
    /// title bar's own bounds, and its own bar stops short of buttons level with the chrome; the
    /// clicks fell through to the pane underneath. Being transparent, the bar shows nothing of
    /// its size; what changes is that the row's gaps drag the window, as a title bar's do, while
    /// the controls on it never do. Every chrome control carries a `NoWindowDragArea` behind its
    /// content (and native controls refuse the drag on their own), so a press starting on the zoom
    /// slider or any button, menu or field works only that control and leaves the window in place.
    static var titlebarHeight: CGFloat {
        Chrome.sheetInset + Chrome.chromeTopPadding + Chrome.capsuleHeight
    }

    /// The view AppKit sizes the title bar with: the buttons' bar and its accessories together.
    static func titlebarContainer(of window: NSWindow) -> NSView? {
        window.standardWindowButton(.closeButton)?.superview?.superview
    }

    /// Reaches the title bar down to `titlebarHeight`, keeping its top edge where it is. The
    /// buttons' bar fills the container, so it grows with it and the pinned buttons come inside.
    /// Never lays out synchronously: the fit lands on the frame and AppKit's own pass lays
    /// it out, so a notification fired mid-tiling costs one frame assignment.
    static func fitTitlebar(of window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        guard let container = titlebarContainer(of: window), let themeFrame = container.superview else { return }
        var fitted = container.frame
        guard fitted.height < titlebarHeight else { return }
        if themeFrame.isFlipped {
            fitted.size.height = titlebarHeight
        } else {
            fitted.origin.y = fitted.maxY - titlebarHeight
            fitted.size.height = titlebarHeight
        }
        container.frame = fitted
    }

    /// Restores standard window button positioning so AppKit can layout the buttons
    /// natively in full-screen mode without conflicting Auto Layout constraints.
    static func resetTrafficLights(on window: NSWindow) {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in types {
            guard let button = window.standardWindowButton(type) else { continue }
            if let titlebar = button.superview {
                let toRemove = titlebar.constraints.filter { constraint in
                    (constraint.firstItem as? NSView === button || constraint.secondItem as? NSView === button) &&
                    (constraint.identifier == leadingIdentifier || constraint.identifier == topIdentifier)
                }
                NSLayoutConstraint.deactivate(toRemove)
            }
            let buttonConstraints = button.constraints.filter { constraint in
                constraint.identifier == widthIdentifier || constraint.identifier == heightIdentifier
            }
            NSLayoutConstraint.deactivate(buttonConstraints)
            button.translatesAutoresizingMaskIntoConstraints = true
        }
        window.standardWindowButton(.closeButton)?.superview?.needsLayout = true
        window.standardWindowButton(.closeButton)?.superview?.layoutSubtreeIfNeeded()
    }

    /// Pins the native buttons with constraints, since the title bar's own layout pass resets
    /// frames. Beside the sidebar they sit in its top corner; with it hidden they move over
    /// to the chat's chrome row and down to its centre line, with the slide the chrome makes.
    static func placeTrafficLights(on window: NSWindow, sidebarVisible: Bool, animated: Bool) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let leading = sidebarVisible ? Chrome.trafficLightLeading : Chrome.sheetInset + Chrome.chromeHorizontalPadding
        let top = sidebarVisible ? Chrome.trafficLightTop : collapsedTrafficLightTop
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview else { return }
        fitTitlebar(of: window)
        var changed = false
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in types.enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            button.isHidden = false
            let x = leading + CGFloat(index) * Chrome.trafficLightPitch
            if button.translatesAutoresizingMaskIntoConstraints {
                button.translatesAutoresizingMaskIntoConstraints = false
                let oldTitlebarConstraints = titlebar.constraints.filter { constraint in
                    (constraint.firstItem as? NSView === button || constraint.secondItem as? NSView === button) &&
                    (constraint.identifier == leadingIdentifier || constraint.identifier == topIdentifier)
                }
                NSLayoutConstraint.deactivate(oldTitlebarConstraints)
                let oldButtonConstraints = button.constraints.filter { constraint in
                    constraint.identifier == widthIdentifier || constraint.identifier == heightIdentifier
                }
                NSLayoutConstraint.deactivate(oldButtonConstraints)

                let leadingConstraint = button.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor, constant: x)
                leadingConstraint.identifier = leadingIdentifier
                let topConstraint = button.topAnchor.constraint(equalTo: titlebar.topAnchor, constant: top)
                topConstraint.identifier = topIdentifier
                let widthConstraint = button.widthAnchor.constraint(equalToConstant: Chrome.trafficLightDiameter)
                widthConstraint.identifier = widthIdentifier
                let heightConstraint = button.heightAnchor.constraint(equalToConstant: Chrome.trafficLightDiameter)
                heightConstraint.identifier = heightIdentifier
                NSLayoutConstraint.activate([
                    leadingConstraint,
                    topConstraint,
                    widthConstraint,
                    heightConstraint,
                ])
                changed = true
            } else {
                for constraint in titlebar.constraints where constraint.firstItem as? NSView === button {
                    let target: CGFloat? = switch constraint.identifier {
                    case leadingIdentifier: x
                    case topIdentifier: top
                    default: nil
                    }
                    guard let target, constraint.constant != target else { continue }
                    constraint.constant = target
                    changed = true
                }
            }
        }
        guard changed else { return }
        // Never animated mid-resize: a fresh group every frame is what lagged the buttons.
        guard animated, !window.inLiveResize else {
            titlebar.layoutSubtreeIfNeeded()
            return
        }
        // The same run as Chrome.panelSlide, so the buttons and the chrome row that makes
        // room for them arrive together. A plain ease-out spends the run gliding; a curve
        // that is nearly done after its first few frames reads as the buttons popping over.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.18 : 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            titlebar.layoutSubtreeIfNeeded()
        }
    }
}


extension Chrome {
    /// The theme wash over a floating surface's glass. Light enough that the blurred
    /// content reads through; the glass's own blur, not the wash, carries legibility.
    static func floatingGlassWash(isDark: Bool) -> Color {
        glassTint.opacity(isDark ? 0.15 : 0.35)
    }

    /// The hairline round a floating surface: a translucent cool slate, which sits on glass
    /// more naturally than the neutral separator.
    static func floatingGlassRim(isDark: Bool) -> Color {
        isDark
            ? Color(hue: 210 / 360, saturation: 0.18, brightness: 0.82).opacity(0.09)
            : Color(hue: 210 / 360, saturation: 0.30, brightness: 0.38).opacity(0.10)
    }
}

private struct FloatingGlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let rim: Color?
    let isInteractive: Bool
    let hiddenRimBottom: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("performanceMode") private var configuredPerformanceMode = false
    private var performanceMode: Bool { configuredPerformanceMode || contrast == .increased }

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        let edge = shape
            .strokeBorder(contrast == .increased ? Chrome.overlay(0.28) : rim ?? Chrome.floatingGlassRim(isDark: isDark), lineWidth: 1)
            .mask(alignment: .top) { Rectangle().padding(.bottom, hiddenRimBottom) }
        if reduceTransparency || performanceMode {
            content
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .clipShape(shape)
                .overlay { edge }
        } else {
            // No base under the glass: a fill behind it is what the glass samples, and an
            // opaque one turned every floating surface a flat grey.
            content
                .glassEffect(glass(isDark: isDark), in: shape)
                .overlay { edge }
        }
    }

    private func glass(isDark: Bool) -> Glass {
        let wash = tint ?? Chrome.floatingGlassWash(isDark: isDark)
        return isInteractive ? .regular.tint(wash).interactive() : .regular.tint(wash)
    }
}

/// A control's surface: interactive Liquid Glass, or, inside a glass panel, the panel's
/// flat control fill, a shade brighter under the pointer the way the glass would be.
fileprivate struct ChromeGlassSurface: ViewModifier {
    enum Kind { case capsule, circle }
    let shape: Kind
    /// Whether the glass answers a press; off for a field that takes the caret instead.
    var isInteractive = true

    init(shape: Kind, isInteractive: Bool = true) {
        self.shape = shape
        self.isInteractive = isInteractive
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isOnGlassPanel) private var isOnGlassPanel
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("performanceMode") private var configuredPerformanceMode = false
    private var performanceMode: Bool { configuredPerformanceMode || contrast == .increased }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovered = false

    func body(content: Content) -> some View {
        switch shape {
        case .capsule:
            surface(content, in: Capsule(style: .continuous))
        case .circle:
            surface(content, in: Circle())
        }
    }

    @ViewBuilder
    private func surface<S: InsettableShape>(_ content: Content, in shape: S) -> some View {
        if isOnGlassPanel && !reduceTransparency && !performanceMode {
            content
                .background(shape.fill(Chrome.panelControlFill(isDark: colorScheme == .dark, hovered: isHovered)))
                .contentShape(shape)
                .onHover { isHovered = $0 }
                .animation(Chrome.hover, value: isHovered)
        } else if reduceTransparency || performanceMode {
            content
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .contentShape(shape)
                .overlay { shape.strokeBorder(Chrome.overlay(contrast == .increased ? 0.28 : 0.10), lineWidth: 1) }
                .onHover { isHovered = $0 }
                .animation(performanceMode ? nil : Chrome.hover, value: isHovered)
        } else {
            if isInteractive {
                content.glassEffect(.regular.tint(Chrome.glassTint.opacity(0.3)).interactive(), in: shape)
            } else {
                content.glassEffect(.regular.tint(Chrome.glassTint.opacity(0.3)), in: shape)
            }
        }
    }
}


// The installed Droppy Code 1.7.0 uses SwiftUI Liquid Glass here. Newer
// upstream revisions replaced it with a heavier NSVisualEffectView material.
// Keep the 1.7.0 renderer below verbatim apart from its name.
struct WindowBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("performanceMode") private var performanceMode = false
    let opacity: Double
    var wallpaper: NSImage? = nil

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Chrome.windowCornerRadius, style: .continuous)
    }

    var body: some View {
        if performanceMode || reduceTransparency || contrast == .increased {
            shape.fill(colorScheme == .dark ? Color.black : Color.white)
                .overlay { shape.fill(Chrome.glassTint.opacity(0.12)) }
                .overlay { shape.strokeBorder(Chrome.overlay(0.14), lineWidth: 1) }
        } else {
            Droppy17WindowBackdrop(opacity: opacity, wallpaper: wallpaper)
        }
    }
}

/// One shaped surface for the whole window: glass or a solid fill, a legibility tint and a hairline.
private struct Droppy17WindowBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    /// The backdrop setting, 0 for bare glass and 1 for a solid base.
    let opacity: Double
    /// The user's wallpaper, painted edge to edge at the transparency setting's own opacity; nil for the stock glass.
    var wallpaper: NSImage? = nil

    /// The scrim over the glass for a backdrop setting: the stock scrim at the
    /// midpoint, none at 0, a solid base at 1, linear either side.
    static func scrim(for opacity: Double, isDark: Bool) -> Double {
        let stock = isDark ? 0.26 : 0.18
        let t = min(max(opacity, 0), 1)
        return t <= 0.5 ? stock * (t / 0.5) : stock + (1 - stock) * ((t - 0.5) / 0.5)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.windowCornerRadius, style: .continuous)
        let isDark = colorScheme == .dark
        // At the solid end of the slider the scrim covers the glass completely, and a
        // Liquid Glass surface the size of the window is a full-window sample on every
        // frame anything over it moves. There it draws as a plain fill instead; the
        // scrim, the tint and the hairline stay exactly as they are.
        let isSolid = opacity >= 0.98
        Group {
            if let wallpaper {
                // The picture rides over the desktop rather than in place of it: the
                // transparency setting is the picture's own opacity, so a clear window
                // shows the desktop through the picture and a solid one shows the picture
                // alone. No scrim in this branch: the scrim is the window's base colour,
                // and the picture is what that base is when one is set.
                shape.fill(.clear)
                    .overlay {
                        Image(nsImage: wallpaper)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .opacity(opacity)
                    }
                    .clipShape(shape)
                    .overlay {
                        if !isSolid {
                            shape
                                .fill(.clear)
                                .glassEffect(in: shape)
                        }
                    }
                    .transition(.opacity)
            } else if isSolid {
                shape.fill(isDark ? Color.black : Color.white)
            } else {
                shape
                    .fill(.clear)
                    .glassEffect(in: shape)
                    .overlay {
                        shape
                            .fill(isDark ? Color.black : Color.white)
                            .opacity(Self.scrim(for: opacity, isDark: isDark))
                    }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: wallpaper != nil)
        .overlay {
            shape.fill(Chrome.glassTint.opacity(0.12))
        }
        // The hairline sits on the glass as well as on the solid fill, the way Droppy's
        // settings window draws its edge: on a clear window the glass rim alone reads as
        // a second line outside the curve.
        .overlay {
            shape.strokeBorder(Chrome.overlay(0.14), lineWidth: 1)
        }
    }
}

/// The chrome row sits inside the title bar's reach (see `WindowChrome.titlebarHeight`), where
/// AppKit moves the window for any view that lets it. Native controls refuse on their own, but a
/// control SwiftUI renders itself — a drag track, say — lands on the shared hosting view, which
/// lets the window move: dragging such a control moved the window with it. This view sits
/// behind the control's content, so it wins the hit test for presses no narrower control claims and
/// refuses the window drag for them; the presses themselves travel on to SwiftUI, so gestures,
/// popovers and buttons work exactly as before. Empty chrome around the controls has no such view
/// behind it, and still drags the window like a title bar.
struct NoWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NoWindowDragView {
        NoWindowDragView(frame: .zero)
    }

    func updateNSView(_ nsView: NoWindowDragView, context: Context) {}
}

final class NoWindowDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A press here works the control, never the window.
    override var mouseDownCanMoveWindow: Bool { false }

    // The view draws nothing and keeps nothing: it only takes the hit so the window does not
    // drag. Each press travels on to the superview, which routes it to the control under the
    // pointer the way a directly dispatched press would.
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }

    override func mouseDragged(with event: NSEvent) { superview?.mouseDragged(with: event) }

    override func mouseUp(with event: NSEvent) { superview?.mouseUp(with: event) }

    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }

    override func rightMouseUp(with event: NSEvent) { superview?.rightMouseUp(with: event) }
}

private struct DetailSheetModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background {
            Rectangle().fill(colorScheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.3))
            Rectangle().fill(Chrome.glassTint.opacity(colorScheme == .dark ? 0.22 : 0.16))
        }
    }
}

extension EnvironmentValues {
    @Entry var isOnGlassPanel = false
}

extension Chrome {
    static func panelControlFill(isDark: Bool, hovered: Bool = false) -> Color {
        glassTint.opacity(hovered ? 0.36 : 0.2)
    }
}
