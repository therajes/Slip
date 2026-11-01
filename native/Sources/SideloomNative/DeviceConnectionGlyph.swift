import SwiftUI

/// A single connection language everywhere: wireless lives on the display;
/// a wired connection has its connector outside the phone.
struct DeviceConnectionGlyph: View {
    var device: DeviceInfo?
    var height: CGFloat = 24
    @EnvironmentObject private var appearance: AppearanceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var wireless: Bool { device?.connectionType.caseInsensitiveCompare("Network") == .orderedSame }
    private var connected: Bool { device != nil }
    private var phoneWidth: CGFloat { height * 0.52 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: height * 0.13, style: .continuous)
                .strokeBorder(connected ? Color.primary.opacity(0.9) : Color.secondary.opacity(0.5), lineWidth: max(1, height * 0.05))
                .frame(width: phoneWidth, height: height)
            Capsule()
                .fill(Color.primary.opacity(0.75))
                .frame(width: phoneWidth * 0.38, height: max(1, height * 0.055))
                .offset(y: -height * 0.35)
            Capsule()
                .fill(Color.primary.opacity(0.5))
                .frame(width: phoneWidth * 0.42, height: 1)
                .offset(y: height * 0.37)
            if wireless {
                Image(systemName: "wifi")
                    .font(.system(size: height * 0.28, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            } else if connected {
                Circle().fill(Color.green).frame(width: height * 0.14, height: height * 0.14)
                Image(systemName: "cable.connector")
                    .font(.system(size: height * 0.43, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                    .padding(1)
                    .background(Chrome.glassTint.opacity(0.8), in: Capsule())
                    .offset(x: height * 0.32, y: height * 0.33)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .frame(width: height * 0.94, height: height + 2)
        .animation(appearance.motionAllowed && !reduceMotion ? .spring(response: 0.4, dampingFraction: 0.82) : nil, value: device?.connectionType)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(device.map { "\($0.marketingName), connected over \($0.connectionType.caseInsensitiveCompare("Network") == .orderedSame ? "Wi-Fi" : $0.connectionType)" } ?? "No iPhone connected")
    }
}
