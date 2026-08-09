import SwiftUI

struct SlipBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            RadialGradient(
                colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.10), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 620
            )
            RadialGradient(
                colors: [Color.cyan.opacity(colorScheme == .dark ? 0.08 : 0.05), .clear],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: 700
            )
            LinearGradient(
                colors: [.white.opacity(colorScheme == .dark ? 0.015 : 0.16), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

private struct SlipGlassSurfaceModifier: ViewModifier {
    let tint: Color?
    let interactive: Bool
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                Glass.regular.tint(tint).interactive(interactive),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content.background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }
}

struct SlipGlassGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            configuration.content
        }
        .padding(18)
        .modifier(SlipGlassSurfaceModifier(tint: nil, interactive: false, cornerRadius: 24))
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
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

struct SlipStatusPill: View {
    let title: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .slipGlassSurface(tint: tint.opacity(0.10), cornerRadius: 999)
    }
}

struct SlipSymbolTile: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .slipGlassSurface(tint: tint.opacity(0.10), interactive: true, cornerRadius: size * 0.32)
    }
}

private struct SlipGlassControlsModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct SlipProminentButtonModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

extension View {
    func slipGlassSurface(
        tint: Color? = nil,
        interactive: Bool = false,
        cornerRadius: CGFloat = 20
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
}
