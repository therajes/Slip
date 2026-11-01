// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Jordy Spruit (Droppy)
// Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app
// Modified by Slip: native sideloading interface, controls and compatibility.

import AppKit
import SwiftUI

enum SlipInterfaceAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

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

    @Published var enhancedMotion: Bool {
        didSet { UserDefaults.standard.set(enhancedMotion, forKey: "enhancedMotion") }
    }

    @Published var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "workspaceTheme")
            apply()
        }
    }
    @Published var backdropOpacity: Double {
        didSet { UserDefaults.standard.set(backdropOpacity, forKey: "backdropOpacity") }
    }
    @Published var performanceMode: Bool {
        didSet { UserDefaults.standard.set(performanceMode, forKey: "performanceMode") }
    }
    @Published var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: "hapticsEnabled") }
    }

    init() {
        let legacyAppearance = SlipInterfaceAppearance(
            rawValue: UserDefaults.standard.string(forKey: "interfaceAppearance") ?? ""
        ) ?? .system
        interfaceAppearance = legacyAppearance
        enhancedMotion = UserDefaults.standard.object(forKey: "enhancedMotion") as? Bool ?? true

        theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "workspaceTheme") ?? "")
            ?? (legacyAppearance == .dark ? .dark : legacyAppearance == .light ? .light : .system)
        if !UserDefaults.standard.bool(forKey: "droppyStockBackdropV3") {
            // Restore Droppy's stock material and midpoint scrim once after the
            // earlier clear-window experiment. Later slider choices persist.
            UserDefaults.standard.set(0.5, forKey: "backdropOpacity")
            UserDefaults.standard.set(true, forKey: "droppyStockBackdropV3")
        }
        backdropOpacity = UserDefaults.standard.object(forKey: "backdropOpacity") as? Double ?? 0.5
        performanceMode = UserDefaults.standard.bool(forKey: "performanceMode")
        hapticsEnabled = UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true

    }

    func apply() {
        ThemeManager.current = theme
        switch theme.scheme {
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        default: NSApplication.shared.appearance = nil
        }
    }

    func selectionFeedback() {
        guard hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func completionFeedback() {
        guard hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    var motionAllowed: Bool {
        enhancedMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

struct AppearanceSettingsView: View {
    @EnvironmentObject private var appearance: AppearanceController

    var body: some View {
        WorkspacePage {
            PageHeader(eyebrow: "PERSONALIZE", title: "Make Slip yours", subtitle: "The look and feel of your workspace, just how you like it.")
            GroupBox {
                VStack(spacing: 0) {
                    ChromeRow(title: "Theme", detail: appearance.theme.detail) {
                        Menu {
                            ForEach(AppTheme.allCases) { theme in
                                Button {
                                    appearance.theme = theme
                                    appearance.selectionFeedback()
                                } label: {
                                    Label(theme.displayName, systemImage: appearance.theme == theme ? "checkmark" : "circle")
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                appearance.theme.swatch.frame(width: 15, height: 15)
                                Text(appearance.theme.displayName)
                            }
                        }
                        .fixedSize()
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Window backdrop")
                            Spacer()
                            Text(appearance.backdropOpacity, format: .percent.precision(.fractionLength(0)))
                                .foregroundStyle(Chrome.secondaryText).monospacedDigit()
                        }
                        Slider(value: $appearance.backdropOpacity, in: 0...1) { editing in
                            if !editing { appearance.selectionFeedback() }
                        }
                        HStack {
                            Text("Clear glass")
                            Spacer()
                            Button("Reset") {
                                appearance.backdropOpacity = 0.5
                                appearance.selectionFeedback()
                            }
                            Spacer()
                            Text("Solid")
                        }
                        .font(.caption).foregroundStyle(Chrome.secondaryText)
                    }
                    .padding(.vertical, 14).padding(.horizontal, 16)
                    Divider()
                    ChromeRow(title: "App icon", detail: "Default, Dark, Clear and Tinted, including light and dark variants.") {
                        Label("Follows macOS", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(Chrome.secondaryText).fixedSize()
                    }
                }
            } label: { Label("Appearance", systemImage: "paintpalette") }
            GroupBox {
                VStack(spacing: 0) {
                    ChromeRow(title: "Smooth animations", detail: "Gentle movement that follows Reduce Motion.") {
                        Toggle("Smooth animations", isOn: $appearance.enhancedMotion).labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    ChromeRow(title: "Haptic feedback", detail: "Subtle feedback on a supported trackpad.") {
                        Toggle("Haptic feedback", isOn: $appearance.hapticsEnabled).labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    ChromeRow(title: "Performance mode", detail: "Solid surfaces with less rendering work.") {
                        Toggle("Performance mode", isOn: $appearance.performanceMode).labelsHidden().toggleStyle(.switch)
                    }
                }
            } label: { Label("Feel", systemImage: "hand.draw") }
            GroupBox {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Slip").font(.system(size: 15, weight: .semibold))
                        Text("A native home for your iPhone apps.")
                            .font(.caption).foregroundStyle(Chrome.secondaryText)
                    }
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                        .font(.caption).foregroundStyle(Chrome.secondaryText)
                }
                .padding(.bottom, 14)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Interface adapted and modified by Slip.")
                    Link("Droppy Code by Jordy Spruit (Droppy)", destination: URL(string: "https://getdroppycode.app")!)
                    Text("Slip is not affiliated with or endorsed by Droppy. This adapted native interface is licensed under GNU AGPL v3 with upstream additional terms.")
                        .foregroundStyle(Chrome.secondaryText)
                    HStack(spacing: 12) {
                        Button("License") { openNotice("License", extension: "txt") }
                        Button("Third-party notices") { openNotice("ThirdPartyNotices", extension: "txt") }
                    }
                    .padding(.top, 4)
                }
                .font(.caption).padding(.top, 14)
            } label: { Label("About Slip", systemImage: "info.circle") }
        }
    }

    private func openNotice(_ name: String, extension fileExtension: String) {
        if let url = Bundle.main.url(forResource: name, withExtension: fileExtension) { NSWorkspace.shared.open(url) }
    }
}
