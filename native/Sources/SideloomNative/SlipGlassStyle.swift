import SwiftUI

struct SlipBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [Color.accentColor.opacity(0.12), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 540
            )
            RadialGradient(
                colors: [Color.indigo.opacity(0.06), .clear],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: 620
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
        .padding(16)
        .modifier(SlipGlassSurfaceModifier(tint: nil, interactive: false, cornerRadius: 20))
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
