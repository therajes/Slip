// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Jordy Spruit (Droppy)
// Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app
// Modified by Slip: native sideloading workspace, compatibility and accessibility.

import AppKit
import SwiftUI

struct ChromeCapsule<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, Chrome.iconCapsuleInnerPadding)
        .padding(.vertical, Chrome.capsuleVerticalPadding)
        .chromeGlassCapsule()
        // The capsule is a control wherever it sits: presses on it work the control and
        // never drag the window.
        .background { NoWindowDragArea() }
    }
}

struct ChromeDivider: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 0.5, style: .continuous)
            .fill(Chrome.primaryText.opacity(0.22))
            .frame(width: 1, height: Chrome.dividerHeight)
            .accessibilityHidden(true)
    }
}

struct ChromeIconLabel: View {
    let symbol: String
    var isEnabled = true
    var isActive = false
    var isHovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(Chrome.iconFont)
            .foregroundStyle(foreground)
            .frame(width: Chrome.capsuleContentHeight, height: Chrome.capsuleContentHeight)
            .contentShape(.rect)
    }

    private var foreground: Color {
        guard isEnabled else { return Chrome.primaryText.opacity(0.32) }
        if isActive { return Chrome.primaryText }
        return Chrome.primaryText.opacity(isHovering ? 1 : 0.92)
    }
}

/// The surrounding capsule owns the glass; its segments only need a quiet
/// selection wash and press response, without another glass or circular bezel.
private struct ChromeSegmentButtonStyle: ButtonStyle {
    var isActive: Bool
    var isHovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("enhancedMotion") private var enhancedMotion = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Chrome.overlay(configuration.isPressed ? 0.14 : isActive ? 0.08 : isHovering ? 0.05 : 0))
                    .padding(2)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && enhancedMotion && !reduceMotion ? 0.94 : 1)
            .animation(enhancedMotion && !reduceMotion ? Chrome.hover : nil, value: configuration.isPressed)
            .animation(enhancedMotion && !reduceMotion ? Chrome.hover : nil, value: isActive)
    }
}

struct ChromeIconButton: View {
    let symbol: String
    var isEnabled = true
    var isActive = false
    let help: String
    let action: () -> Void

    init(symbol: String, isEnabled: Bool = true, isActive: Bool = false, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.isEnabled = isEnabled
        self.isActive = isActive
        self.help = help
        self.action = action
    }

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ChromeIconLabel(symbol: symbol, isEnabled: isEnabled, isActive: isActive, isHovering: isHovering)
        }
        .buttonStyle(ChromeSegmentButtonStyle(isActive: isActive, isHovering: isHovering))
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .background { NoWindowDragArea() }
    }
}



/// A round glass button the height of a chrome capsule.
struct ChromeCircleButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    // Explicit init needed so Swift 6 doesn't synthesise a private memberwise init
    // that includes the @State property, making external call sites inaccessible.
    init(symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Chrome.iconFont)
                .foregroundStyle(Chrome.primaryText.opacity(isHovering ? 1 : 0.92))
                .frame(width: Chrome.capsuleHeight, height: Chrome.capsuleHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .chromeGlassCircle()
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .help(help)
        .accessibilityLabel(Text(help))
        .background { NoWindowDragArea() }
    }
}


struct SidebarSymbol: View {
    let name: String
    var scale: CGFloat = 1

    init(_ name: String, scale: CGFloat = 1) {
        self.name = name
        self.scale = scale
    }

    var body: some View {
        Image(systemName: name)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: Chrome.symbolSize * scale, height: Chrome.symbolSize * scale)
            .symbolRenderingMode(.monochrome)
    }
}

/// A sidebar glyph on its own: a provider logo or an SF Symbol, with nothing drawn behind it.
struct SidebarIconBadge<Glyph: View>: View {
    @ViewBuilder var glyph: Glyph

    var body: some View {
        glyph
            .foregroundStyle(Chrome.primaryText.opacity(0.92))
            .frame(width: Chrome.iconSize, height: Chrome.iconSize)
    }
}

struct SidebarRow<Icon: View, Accessory: View>: View {
    let title: String
    let isSelected: Bool
    let isEmphasized: Bool
    let accessoryWidth: CGFloat
    let action: () -> Void
    let icon: Icon
    let accessory: (Bool) -> Accessory

    @State private var isHovering = false

    init(
        title: String,
        isSelected: Bool = false,
        isEmphasized: Bool = false,
        accessoryWidth: CGFloat = 0,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder accessory: @escaping (Bool) -> Accessory
    ) {
        self.title = title
        self.isSelected = isSelected
        self.isEmphasized = isEmphasized
        self.accessoryWidth = accessoryWidth
        self.action = action
        self.icon = icon()
        self.accessory = accessory
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 8) {
                icon
                    .frame(width: Chrome.iconSize, alignment: .center)
                Text(verbatim: title)
                    .font(.system(.body, weight: isSelected || isEmphasized ? .medium : .regular))
                    .foregroundStyle(Chrome.primaryText.opacity(isSelected ? 1 : 0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
            }
            .padding(.leading, Chrome.rowHorizontalPadding)
            .padding(.trailing, Chrome.rowHorizontalPadding + accessoryWidth)
            .frame(height: Chrome.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { shape.fill(fill).animation(Chrome.hover, value: isSelected) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            accessory(isHovering)
                .padding(.trailing, 6)
        }
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var fill: Color {
        if isSelected { return Chrome.overlay(0.12) }
        if isHovering { return Chrome.overlay(0.06) }
        return .clear
    }
}

extension SidebarRow where Accessory == EmptyView {
    init(
        title: String,
        isSelected: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) {
        self.init(title: title, isSelected: isSelected, action: action, icon: icon) { _ in EmptyView() }
    }
}

struct RowAccessoryIcon: View {
    let symbol: String

    init(_ symbol: String) {
        self.symbol = symbol
    }

    var body: some View {
        Image(systemName: symbol)
            .font(Chrome.inlineIconFont)
            .foregroundStyle(Chrome.secondaryText)
            .frame(width: 20, height: 20)
            .contentShape(.rect)
    }
}

struct SidebarSearchField: View {
    @Binding var text: String
    var prompt = "Search"
    var onSubmit: () -> Void = {}
    /// Up and down walk the results, one step per press. Last, so a bare trailing closure
    /// still means `onSubmit`. Left out where there is no list under the field, and the
    /// arrows are then the field's own again.
    var onMove: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(.callout, weight: .medium))
                .foregroundStyle(Chrome.secondaryText.opacity(0.85))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .frame(maxWidth: .infinity)
                .onSubmit(onSubmit)
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(.callout))
                        .foregroundStyle(Chrome.secondaryText.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background {
            Capsule(style: .continuous).fill(Chrome.overlay(0.07))
        }
        .contentShape(Capsule(style: .continuous))
        // Escape empties the field, the way the chrome's search capsule does.
        .onExitCommand { text = "" }
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        guard let onMove else { return .ignored }
        onMove(offset)
        return .handled
    }
}



struct ChromeCard<Content: View>: View {
    /// Use lazy only for cards that list a long, uniform, growing collection.
    /// Variable-height rows at the visible bottom edge can rebuild without end.
    var lazy = false
    @ViewBuilder var content: Content

    var body: some View {
        // The card uses a filled shape instead of a clip, avoiding a mask while scrolling.
        Group {
            if lazy {
                LazyVStack(alignment: .leading, spacing: 0) { content }
            } else {
                VStack(alignment: .leading, spacing: 0) { content }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous)
                .fill(Chrome.overlay(0.03))
        )
    }
}

struct ChromeSection<Content: View>: View {
    let title: String
    /// Sits right after the title: an info button, a count.
    var accessory: AnyView? = nil
    /// Sits at the header's far right: a control for the whole section, out of its cards.
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionHeaderSpacing) {
            HStack(spacing: 4) {
                Text(verbatim: title)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                if let accessory { accessory }
                if let trailing {
                    Spacer(minLength: 8)
                    trailing
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChromeRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(.body))
                    .foregroundStyle(Chrome.primaryText)
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.system(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.leading, 16)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 11)
    }
}

struct ChromeRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 16)
    }
}

/// The same readable content width and spacing used by Apple Accounts.
struct WorkspacePage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .padding(28)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .buttonStyle(WorkspaceActionButtonStyle())
    }
}

/// Draw the label explicitly instead of relying on a native glass button's
/// automatic foreground, which can resolve black inside dark hosted views.
struct WorkspaceActionButtonStyle: ButtonStyle {
    var isSelected = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(configuration.role == .destructive ? Color.red : colorScheme == .dark ? .white : .black)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .chromeGlassCapsule()
            .overlay {
                if isSelected {
                    Capsule().strokeBorder(Chrome.overlay(0.3), lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

struct WorkspaceEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Chrome.primaryText)
                .frame(width: 76, height: 76)
                .slipGlassSurface(cornerRadius: 22)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(title).font(.system(size: 22, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Chrome.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 390)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
        .padding(.horizontal, 20)
    }
}

