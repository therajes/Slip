import SwiftUI

struct IPhoneModelPreview: View {
    let device: DeviceInfo
    @EnvironmentObject private var appearance: AppearanceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var connectionAnimated = false

    private var usesNetwork: Bool {
        device.connectionType.caseInsensitiveCompare("Network") == .orderedSame
    }

    private var motionAllowed: Bool { appearance.motionAllowed && !reduceMotion }
    private var phoneWidth: CGFloat { device.isLargeDisplayModel ? 43 : 40 }
    private var phoneHeight: CGFloat { 76 }
    private var outerRadius: CGFloat { device.isLargeDisplayModel ? 14.5 : 13.5 }
    private var innerRadius: CGFloat { device.isLargeDisplayModel ? 12.2 : 11.3 }

    var body: some View {
        ZStack {
            previewHalo

            if !usesNetwork {
                usbConnector
                    .offset(y: connectionAnimated ? 40 : 51)
                    .opacity(connectionAnimated ? 1 : 0)
                    .scaleEffect(connectionAnimated ? 1 : 0.92, anchor: .top)
                    .zIndex(0)
            }

            phone
                .offset(y: -4)
                .scaleEffect(connectionAnimated || !motionAllowed ? 1 : 0.985)
                .zIndex(1)

            if usesNetwork {
                networkIndicator
                    .offset(y: 4)
                    .zIndex(2)
            }
        }
        .frame(width: 68, height: 92)
        .help([device.marketingName, device.productType].compactMap { $0 }.joined(separator: " · "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connected \(device.marketingName) over \(device.connectionType)")
        .onAppear { restartConnectionAnimation() }
        .onChange(of: device.connectionType) { _, _ in restartConnectionAnimation() }
        .onChange(of: appearance.enhancedMotion) { _, _ in restartConnectionAnimation() }
        .onChange(of: reduceMotion) { _, _ in restartConnectionAnimation() }
    }

    private var previewHalo: some View {
        Ellipse()
            .fill(.white.opacity(colorScheme == .dark ? 0.055 : 0.12))
            .frame(width: 59, height: 76)
            .blur(radius: 13)
            .offset(y: -3)
            .accessibilityHidden(true)
    }

    private var phone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                .fill(.white.opacity(colorScheme == .dark ? 0.055 : 0.20))

            if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                    .fill(.clear)
                    .glassEffect(
                        .regular.tint(.white.opacity(colorScheme == .dark ? 0.045 : 0.12)).interactive(),
                        in: RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                    )
            } else {
                RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }

            // The display intentionally stays empty. Its only visual treatment is
            // a neutral sheet of glass so the preview reads like a system icon.
            RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                .fill(colorScheme == .dark ? .black.opacity(0.18) : .white.opacity(0.12))
                .padding(2.7)
                .overlay(alignment: .top) {
                    cameraCutout
                }

            RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.46), .white.opacity(0.05), .white.opacity(0.22)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.55
                )
                .padding(2.7)

            RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.82), .white.opacity(0.12), .white.opacity(0.48)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.85
                )
        }
        .frame(width: phoneWidth, height: phoneHeight)
        .overlay(alignment: .trailing) {
            Capsule()
                .fill(.white.opacity(0.38))
                .frame(width: 1.25, height: 13)
                .offset(x: 1.1, y: -13)
        }
        .overlay(alignment: .leading) {
            VStack(spacing: 4) {
                Capsule().fill(.white.opacity(0.34)).frame(width: 1.2, height: 8)
                Capsule().fill(.white.opacity(0.34)).frame(width: 1.2, height: 11)
            }
            .offset(x: -1, y: -10)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.42 : 0.22), radius: 8, y: 5)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var cameraCutout: some View {
        if device.usesDynamicIsland {
            Capsule()
                .fill(cameraCutoutFill)
                .frame(width: 14, height: 4.8)
                .overlay { Capsule().stroke(.white.opacity(0.34), lineWidth: 0.45) }
                .padding(.top, 5.2)
        } else {
            UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5)
                .fill(cameraCutoutFill)
                .frame(width: 18, height: 6)
                .overlay {
                    UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5)
                        .stroke(.white.opacity(0.30), lineWidth: 0.45)
                }
                .padding(.top, 2.4)
        }
    }

    private var cameraCutoutFill: LinearGradient {
        LinearGradient(
            colors: [.white.opacity(0.68), .white.opacity(0.18), .white.opacity(0.42)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var usbConnector: some View {
        VStack(spacing: -0.6) {
            RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                .fill(.regularMaterial)
                .frame(width: 10, height: 6.5)
                .overlay {
                    RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                        .stroke(.white.opacity(0.55), lineWidth: 0.65)
                }
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(.black.opacity(0.32))
                        .frame(width: 5.5, height: 1.2)
                        .padding(.top, 1.2)
                }
            Capsule()
                .fill(.secondary.opacity(0.46))
                .frame(width: 2.3, height: 17)
        }
        .shadow(color: .black.opacity(0.24), radius: 2, y: 1)
        .accessibilityHidden(true)
    }

    private var networkIndicator: some View {
        ZStack {
            connectionGlassBadge
                .scaleEffect(connectionAnimated ? 1.05 : 0.94)
                .opacity(connectionAnimated ? 1 : 0.72)

            Image(systemName: "wifi")
                .font(.system(size: 12, weight: .semibold))
                .slipDimensionalSymbol(strength: 0.72)
                .foregroundStyle(.primary.opacity(0.86))
                .scaleEffect(connectionAnimated ? 1 : 0.94)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var connectionGlassBadge: some View {
        if #available(macOS 26.0, *) {
            Circle()
                .fill(.clear)
                .frame(width: 24, height: 24)
                .glassEffect(.regular.tint(.white.opacity(0.06)).interactive(), in: Circle())
        } else {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 24, height: 24)
                .overlay { Circle().stroke(.white.opacity(0.24), lineWidth: 0.7) }
        }
    }

    private func restartConnectionAnimation() {
        connectionAnimated = !motionAllowed
        guard motionAllowed else { return }

        if usesNetwork {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                connectionAnimated = true
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.58, dampingFraction: 0.76)) {
                    connectionAnimated = true
                }
            }
        }
    }
}
