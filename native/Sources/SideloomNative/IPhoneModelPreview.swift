import SwiftUI

struct IPhoneModelPreview: View {
    let device: DeviceInfo

    private var tint: Color {
        guard let raw = device.deviceColor?.trimmingCharacters(in: CharacterSet(charactersIn: "#")),
              raw.count == 6,
              let value = UInt64(raw, radix: 16) else { return .gray }
        return Color(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.16))
                .frame(width: 68, height: 68)
                .blur(radius: 12)

            ZStack {
                RoundedRectangle(cornerRadius: device.isLargeDisplayModel ? 14.5 : 13.5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.92), tint.opacity(0.70), .black.opacity(0.76)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: device.isLargeDisplayModel ? 12.5 : 11.5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.08, green: 0.13, blue: 0.24), Color(red: 0.18, green: 0.07, blue: 0.27), Color(red: 0.02, green: 0.04, blue: 0.09)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .padding(2.6)
                    .overlay(alignment: .top) {
                        if device.usesDynamicIsland {
                            Capsule()
                                .fill(.black)
                                .frame(width: 14, height: 4.8)
                                .padding(.top, 5.2)
                        } else {
                            UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5)
                                .fill(.black)
                                .frame(width: 18, height: 6)
                                .padding(.top, 2.4)
                        }
                    }
                Circle()
                    .fill(Color.cyan.opacity(0.58))
                    .frame(width: 17, height: 17)
                    .blur(radius: 7)
                    .offset(x: 7, y: 14)
            }
            .frame(width: device.isLargeDisplayModel ? 43 : 40, height: 76)
            .overlay(alignment: .trailing) {
                Capsule().fill(.white.opacity(0.45)).frame(width: 1.4, height: 13).offset(x: 1.3, y: -13)
            }
            .overlay(alignment: .leading) {
                VStack(spacing: 4) {
                    Capsule().fill(.white.opacity(0.40)).frame(width: 1.3, height: 8)
                    Capsule().fill(.white.opacity(0.40)).frame(width: 1.3, height: 11)
                }
                .offset(x: -1.2, y: -10)
            }
            .shadow(color: .black.opacity(0.32), radius: 7, y: 4)
        }
        .frame(width: 64, height: 82)
        .help([device.marketingName, device.productType].compactMap { $0 }.joined(separator: " · "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connected \(device.marketingName)")
    }
}
