// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Jordy Spruit (Droppy)
// Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app
// Modified from FloatingSidebarPanel.swift for Slip navigation and accessibility.

import AppKit
import SwiftUI

/// Droppy's floating panel geometry and native drag handles, with Slip's navigation.
struct FloatingWorkspacePanel<Content: View>: View {
    let area: CGSize
    let close: () -> Void
    @ViewBuilder var content: Content

    init(area: CGSize, close: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.area = area
        self.close = close
        self.content = content()
    }
    @EnvironmentObject private var appearance: AppearanceController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("navigationPanelX") private var storedX = 12.0
    @AppStorage("navigationPanelY") private var storedY = 76.0
    @AppStorage("navigationPanelWidth") private var storedWidth = 300.0
    @AppStorage("navigationPanelHeight") private var storedHeight = 560.0
    @State private var dragOrigin: CGPoint?
    @State private var grab: CGPoint?
    @State private var resizeStart: CGSize?

    private static var margin: CGFloat { 12 }
    private var solid: Bool { appearance.performanceMode || reduceTransparency || contrast == .increased }

    var body: some View {
        let size = CGSize(
            width: min(max(240, storedWidth), max(240, area.width - Self.margin * 2)),
            height: min(max(320, storedHeight), max(320, area.height - Self.margin * 2))
        )
        let rest = clamp(CGPoint(x: storedX, y: storedY), size: size)
        let origin = dragOrigin ?? rest
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        content
            .padding(.top, 44)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .top) {
                HStack(alignment: .top, spacing: 8) {
                    Text("Slip")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Chrome.primaryText)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .padding(.vertical, 2)
                        .chromeGlassCapsule()
                        .overlay { dragHandle(rest: rest, size: size) }
                        .padding(.top, 12).padding(.leading, 14)
                    dragHandle(rest: rest, size: size)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .help("Drag to move navigation")
                    ChromeCircleButton(symbol: "xmark", help: "Close navigation panel") {
                        appearance.selectionFeedback()
                        close()
                    }
                    .padding(.top, 12).padding(.trailing, 14)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Chrome.secondaryText.opacity(0.6))
                    .frame(width: 20, height: 20)
                    .overlay {
                        PanelDragHandle(onDrag: { translation in
                            let start = resizeStart ?? size
                            resizeStart = start
                            storedWidth = min(max(240, start.width + translation.width), area.width - origin.x - Self.margin)
                            storedHeight = min(max(320, start.height + translation.height), area.height - origin.y - Self.margin)
                        }, onDragEnd: { resizeStart = nil; appearance.selectionFeedback() }, cursor: .crosshair, dragCursor: .crosshair)
                    }
                    .padding(4)
                    .help("Drag to resize navigation")
            }
            .environment(\.isOnGlassPanel, true)
            .background { panelSurface(shape) }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Chrome.overlay(contrast == .increased ? 0.3 : 0.14), lineWidth: 1).allowsHitTesting(false) }
            .background {
                shape.fill((colorScheme == .dark ? Color.black : Color.white).opacity(colorScheme == .dark ? 0.12 : 0.18))
                    .shadow(color: solid ? .clear : .black.opacity(colorScheme == .dark ? 0.4 : 0.2), radius: solid ? 0 : 24, y: solid ? 0 : 10)
            }
            .contentShape(shape)
            .offset(x: origin.x, y: origin.y)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(dragOrigin == nil && resizeStart == nil && appearance.motionAllowed && !reduceMotion ? Chrome.panelSlide : nil, value: origin)
    }

    @ViewBuilder
    private func panelSurface(_ shape: RoundedRectangle) -> some View {
        if solid {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else {
            shape.fill(.clear)
                .glassEffect(.regular, in: shape)
                .overlay { shape.fill(Chrome.glassTint.opacity(colorScheme == .dark ? 0.1 : 0.08)) }
        }
    }

    private func dragHandle(rest: CGPoint, size: CGSize) -> some View {
        PanelDragHandle(onDrag: { translation in
            let start = grab ?? rest
            grab = start
            dragOrigin = clamp(CGPoint(x: start.x + translation.width, y: start.y + translation.height), size: size)
        }, onDragEnd: {
            if let dragOrigin { storedX = dragOrigin.x; storedY = dragOrigin.y }
            dragOrigin = nil
            grab = nil
            appearance.selectionFeedback()
        })
    }

    private func clamp(_ origin: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(max(Self.margin, origin.x), max(Self.margin, area.width - size.width - Self.margin)),
                y: min(max(Self.margin, origin.y), max(Self.margin, area.height - size.height - Self.margin)))
    }
}
