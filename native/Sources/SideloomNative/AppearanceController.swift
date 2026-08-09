import AppKit
import SwiftUI

enum SlipInterfaceAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }
}

enum SlipIconAppearance: String, CaseIterable, Identifiable {
    case automatic = "Automatic Glass"
    case light = "Light Glass"
    case dark = "Dark Glass"

    var id: String { rawValue }
}

@MainActor
final class AppearanceController: ObservableObject {
    @Published var interfaceAppearance: SlipInterfaceAppearance {
        didSet {
            UserDefaults.standard.set(interfaceAppearance.rawValue, forKey: "interfaceAppearance")
            apply()
        }
    }

    @Published var iconAppearance: SlipIconAppearance {
        didSet {
            UserDefaults.standard.set(iconAppearance.rawValue, forKey: "iconAppearance")
            refreshIcon()
        }
    }

    @Published var enhancedMotion: Bool {
        didSet { UserDefaults.standard.set(enhancedMotion, forKey: "enhancedMotion") }
    }

    private var systemAppearanceObserver: NSObjectProtocol?

    init() {
        interfaceAppearance = SlipInterfaceAppearance(
            rawValue: UserDefaults.standard.string(forKey: "interfaceAppearance") ?? ""
        ) ?? .system
        iconAppearance = SlipIconAppearance(
            rawValue: UserDefaults.standard.string(forKey: "iconAppearance") ?? ""
        ) ?? .automatic
        enhancedMotion = UserDefaults.standard.object(forKey: "enhancedMotion") as? Bool ?? true

        systemAppearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshIcon() }
        }
    }

    func apply() {
        switch interfaceAppearance {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        refreshIcon()
    }

    func refreshIcon() {
        // In Automatic mode macOS owns the Dock/Launchpad appearance. Setting
        // applicationIconImage here makes the system apply its Dark Glass
        // treatment a second time, which destroys contrast on dark Docks.
        guard iconAppearance != .automatic else {
            NSApplication.shared.applicationIconImage = nil
            return
        }

        let selected: SlipIconAppearance
        selected = iconAppearance

        let fileName = selected == .dark ? "SlipAppIcon-Dark" : "SlipAppIcon-Light"
        if let url = Bundle.main.url(forResource: fileName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 512, height: 512)
            NSApplication.shared.applicationIconImage = image
        } else if let adaptive = NSImage(named: "SlipAppIcon") {
            NSApplication.shared.applicationIconImage = adaptive
        }
    }

    var motionAllowed: Bool {
        enhancedMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

struct AppearanceSettingsView: View {
    @EnvironmentObject private var appearance: AppearanceController

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Interface", selection: $appearance.interfaceAppearance) {
                    ForEach(SlipInterfaceAppearance.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("App icon", selection: $appearance.iconAppearance) {
                    ForEach(SlipIconAppearance.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Enhanced native motion", isOn: $appearance.enhancedMotion)
            }
            Section {
                Text("Automatic Glass lets macOS apply the current system icon appearance without double-processing it. Reduce Motion in System Settings always takes priority over Slip animations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(22)
        .frame(width: 470, height: 260)
    }
}
