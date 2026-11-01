// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) Jordy Spruit (Droppy). All rights reserved.
// Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app
// Adapted for Slip from DroppyCode/UI/Chrome/Chrome.swift and WindowChrome.swift.
// Modified: neutral system appearance, accessibility, and Slip navigation.

import AppKit
import SwiftUI

private struct SlipDimensionalSymbolModifier: ViewModifier {
    let strength: CGFloat

    func body(content: Content) -> some View {
        content.symbolRenderingMode(.hierarchical)
    }
}

struct SlipDimensionalLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .modifier(SlipDimensionalSymbolModifier(strength: 0.82))
            configuration.title
        }
    }
}

struct SlipWindowBackdrop: View {
    @EnvironmentObject private var appearance: AppearanceController
    var body: some View {
        WindowBackdrop(opacity: appearance.backdropOpacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct SlipBackdrop: View {
    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct SlipGlassSurfaceModifier: ViewModifier {
    let tint: Color?
    let interactive: Bool
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if interactive && cornerRadius >= 999 && tint == nil {
            content.chromeGlassCapsule()
        } else {
            content.floatingGlass(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                tint: tint,
                isInteractive: interactive
            )
        }
    }
}

struct SlipGlassGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: Chrome.sectionHeaderSpacing) {
            configuration.label
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Chrome.secondaryText)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous).fill(Chrome.overlay(0.03)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SlipGlassContainer<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        GlassEffectContainer(spacing: spacing) { content }
    }
}

struct SlipStatusPill: View {
    let title: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Label(title, systemImage: symbol)
            .labelStyle(SlipDimensionalLabelStyle())
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .slipGlassSurface(cornerRadius: 999)
    }
}

struct SlipSymbolTile: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .slipDimensionalSymbol(strength: 1.15)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .slipGlassSurface(cornerRadius: min(12, size * 0.28))
    }
}

private struct SlipGlassControlsModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        content.buttonStyle(.glass)
    }
}

private struct SlipProminentButtonModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        content.foregroundStyle(.white).buttonStyle(.glassProminent).tint(Chrome.accent)
    }
}

extension View {
    func slipGlassSurface(
        tint: Color? = nil,
        interactive: Bool = false,
        cornerRadius: CGFloat = 16
    ) -> some View {
        modifier(
            SlipGlassSurfaceModifier(
                tint: tint,
                interactive: interactive,
                cornerRadius: cornerRadius
            )
        )
    }

    func slipGlassControls() -> some View {
        modifier(SlipGlassControlsModifier())
    }

    func slipProminentButton() -> some View {
        modifier(SlipProminentButtonModifier())
    }

    func slipDimensionalSymbol(strength: CGFloat = 1) -> some View {
        modifier(SlipDimensionalSymbolModifier(strength: strength))
    }
}
