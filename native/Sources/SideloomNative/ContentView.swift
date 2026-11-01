// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) Jordy Spruit (Droppy). All rights reserved.
// Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app
// Adapted for Slip from DroppyCode/UI/Chrome/Chrome.swift and WindowChrome.swift.
// Modified: neutral system appearance, accessibility, and Slip navigation.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum WorkspaceSection: String, CaseIterable, Identifiable {
    case install = "Install"
    case autoRefresh = "Auto Refresh"
    case deviceApps = "iPhone Apps"
    case accounts = "Apple Accounts"
    case activity = "Activity"
    case library = "App Library"
    case settings = "Settings"

    var id: String { rawValue }
    var shortcut: KeyEquivalent { KeyEquivalent(Character(String(shortcutNumber))) }
    var shortcutNumber: Int { Self.allCases.firstIndex(of: self)! + 1 }
    var symbol: String {
        switch self {
        case .install: "square.and.arrow.down"
        case .autoRefresh: "arrow.clockwise"
        case .deviceApps: "square.grid.2x2"
        case .accounts: "person.crop.circle"
        case .activity: "waveform.path.ecg"
        case .library: "square.stack.3d.up"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceController
    @State private var section: WorkspaceSection = .install
    @State private var selectedCertificates: Set<String> = []
    @State private var search = ""
    @State private var showDevices = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("workspacePanelVisible") private var panelVisible = true

    private var motion: Bool { appearance.motionAllowed && !reduceMotion }

    private var navigation: [WorkspaceSection] {
        WorkspaceSection.allCases.filter { $0 != .settings && (search.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(search)) }
    }

    private var pageTitle: String {
        section == .install ? model.ipa?.appName ?? "New installation" : section.rawValue
    }

    private var effectiveAccent: Color {
        appearance.theme.spec.accent ?? Color(nsColor: .controlAccentColor)
    }

    private var workspaceContent: some View {
        VStack(spacing: 0) {
            chromeRow
            page
                .id(section)
                .transition(.opacity.combined(with: .offset(y: 6)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .labelStyle(SlipDimensionalLabelStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func floatingPanel(area: CGSize) -> some View {
        if panelVisible {
            FloatingWorkspacePanel(area: area, close: { panelVisible = false }) {
                navigationPanelContent
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            .zIndex(10)
        }
    }

    private var workspaceSurface: some View {
        GeometryReader { geometry in
            workspaceContent
                .overlay(alignment: .topLeading) {
                    floatingPanel(area: geometry.size)
                }
        }
        .background(SlipWindowBackdrop())
        .background(WindowChromeConfigurator(sidebarVisible: false, performanceMode: appearance.performanceMode))
        .clipShape(RoundedRectangle(cornerRadius: Chrome.windowCornerRadius, style: .continuous))
        .ignoresSafeArea()
        .groupBoxStyle(SlipGlassGroupBoxStyle())
        .slipGlassControls()
        .tint(effectiveAccent)
        .accentColor(effectiveAccent)
        .animation(motion ? Chrome.panelSlide : nil, value: panelVisible)
        .animation(motion ? .easeInOut(duration: 0.2) : nil, value: section)
        .onChange(of: section) { _, _ in appearance.selectionFeedback() }
        .onChange(of: model.currentStage) { _, stage in handleStageChange(stage) }
        .background { keyboardShortcuts }
    }

    private var keyboardShortcuts: some View {
        ForEach(WorkspaceSection.allCases) { item in
            Button(item.rawValue) { section = item }
                .keyboardShortcut(item.shortcut, modifiers: .command)
                .hidden()
        }
    }

    private var errorMessageBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    @ViewBuilder
    private var modalOverlays: some View {
        if model.showTwoFactor && !model.isLoggingIn {
            TwoFactorModalOverlay(code: $model.verificationCode, details: model.twoFactorDetails,
                                  isBusy: model.isSubmittingTwoFactor, errorMessage: model.twoFactorError,
                                  statusMessage: model.twoFactorStatus) { code in
                model.submitTwoFactor(code)
            } onResend: { model.resendTwoFactor() }
            onCancel: { model.submitTwoFactor(nil) }
            onChooseMethod: { model.selectTwoFactorMethod(numberID: $0) }
        }
        if model.showCertificates {
            CertificatesModalOverlay(certificates: model.certificates, selectedCertificates: $selectedCertificates) {
                model.submitCertificates($0)
            } onCancel: { model.submitCertificates(nil) }
        }
        if model.showAppIDExhausted {
            AppIDExhaustedOverlay {
                model.dismissAppIDExhausted()
            } onDismiss: {
                model.showAppIDExhausted = false
            }
        }
    }

    var body: some View {
        workspaceSurface
        .preferredColorScheme(appearance.theme.scheme)
        .onReceive(NotificationCenter.default.publisher(for: .showAccounts)) { _ in panelVisible = false; section = .accounts }
        .onReceive(NotificationCenter.default.publisher(for: .showSlipSettings)) { _ in panelVisible = false; section = .settings }
        .onReceive(NotificationCenter.default.publisher(for: .showInstall)) { _ in panelVisible = false; section = .install }
        .onReceive(NotificationCenter.default.publisher(for: .showLibrary)) { _ in panelVisible = false; section = .library }
        .onReceive(NotificationCenter.default.publisher(for: .openIPA)) { _ in openIPA() }
        .onOpenURL(perform: handleOpenURL)
        .onReceive(NotificationCenter.default.publisher(for: .slipOpenURL)) { notification in
            if let urls = notification.object as? [URL] {
                let files = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "ipa" }
                if !files.isEmpty { Task { await model.importIPAs(files) } }
                else if let url = urls.first { handleOpenURL(url) }
            } else if let url = notification.object as? URL { handleOpenURL(url) }
        }
        .alert("Slip", isPresented: errorMessageBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .overlay { modalOverlays }
        .onChange(of: model.showCertificates) { _, _ in selectedCertificates.removeAll() }
        .onChange(of: model.showAppIDExhausted) { _, showing in if showing { NSApp.activate(ignoringOtherApps: true) } }
        .onChange(of: model.authentication.challengeSequence) { _, sequence in
            guard model.isLoggingIn, sequence > 0 else { return }
            section = .accounts
            panelVisible = false
        }
        .onChange(of: model.authentication.phase) { _, phase in handleAuthPhaseChange(phase) }
        .onChange(of: model.showTwoFactor) { _, isShowing in
            if isShowing {
                if model.isLoggingIn { section = .accounts; panelVisible = false }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func handleStageChange(_ stage: String) {
        if stage == "Installed" || stage == "Exported" {
            appearance.completionFeedback()
        }
    }

    private func handleAuthPhaseChange(_ phase: AuthenticationFlow.Phase) {
        if phase == .failed && !model.isInstalling && !model.isManagingAccount {
            section = .accounts
            panelVisible = false
        }
    }

    private func handleOpenURL(_ url: URL) {
        panelVisible = false
        section = .install
        if url.pathExtension.lowercased() == "ipa" && url.isFileURL {
            Task { await model.importIPAs([url]) }
            return
        }
        guard url.scheme?.lowercased() == "slip",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let remote = components.queryItems?.first(where: { $0.name == "url" })?.value else { return }
        Task { await model.downloadIPA(from: remote) }
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .install: InstallView()
        case .autoRefresh: AutoRefreshView()
        case .deviceApps: DeviceAppsView()
        case .accounts: AccountsView()
        case .activity: ActivityView()
        case .library: AppLibraryView()
        case .settings: AppearanceSettingsView()
        }
    }

    private var navigationPanelContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSearchField(text: $search, prompt: "Search Slip")
                .padding(.horizontal, Chrome.listInset)
                .padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    sidebarHeading("Workspace")
                    ForEach(navigation) { item in
                        SidebarRow(title: item.rawValue, isSelected: section == item, accessoryWidth: 26, action: { section = item; panelVisible = false }) {
                            SidebarIconBadge { SidebarSymbol(item.symbol) }
                        } accessory: { hovered in
                            Text(badge(for: item, hovered: hovered))
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(Chrome.secondaryText)
                                .frame(width: 24)
                        }
                        .help("\(item.rawValue) (⌘\(item.shortcutNumber))")
                    }
                    if search.isEmpty {
                        sidebarHeading("Devices").padding(.top, 18)
                        if model.devices.isEmpty {
                            HStack(spacing: 8) {
                                SidebarSymbol("iphone.slash")
                                Text("Connect your iPhone").font(.system(size: 12))
                            }
                            .foregroundStyle(Chrome.secondaryText)
                            .padding(.horizontal, 8).padding(.vertical, 8)
                        } else {
                            ForEach(model.devices) { device in
                                SidebarRow(title: device.displayName, isSelected: false, accessoryWidth: 12, action: {
                                    model.selectedDevice = device
                                    section = .deviceApps
                                    panelVisible = false
                                }) {
                                    DeviceConnectionGlyph(device: device, height: 20)
                                } accessory: { _ in
                                    Circle().fill(model.selectedDevice == device ? Color.green : Color.secondary.opacity(0.4))
                                        .frame(width: 5, height: 5)
                                }
                                .help("\(device.marketingName) · iOS \(device.version) · \(device.connectionType)")
                            }
                        }
                        if !model.managedInstallations.isEmpty {
                            sidebarHeading("Kept refreshed").padding(.top, 18)
                            ForEach(model.managedInstallations.prefix(8)) { item in
                                SidebarRow(title: item.appName, action: { section = .autoRefresh; panelVisible = false }) {
                                    SidebarIconBadge { SidebarSymbol(item.enabled ? "arrow.clockwise.circle" : "pause.circle") }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Chrome.listInset)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            VStack(spacing: 1) {
                SidebarRow(title: "Open IPA…", action: openIPA) {
                    SidebarIconBadge { SidebarSymbol("plus") }
                }
                SidebarRow(title: "Settings", isSelected: section == .settings, action: { section = .settings; panelVisible = false }) {
                    SidebarIconBadge { SidebarSymbol("gearshape") }
                }
            }
            .padding(.horizontal, Chrome.listInset)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity)
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Chrome.secondaryText)
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 6)
    }

    private func badge(for item: WorkspaceSection, hovered: Bool) -> String {
        if hovered { return "⌘\(item.shortcutNumber)" }
        switch item {
        case .autoRefresh: return model.managedInstallations.isEmpty ? "" : "\(model.managedInstallations.count)"
        case .accounts: return model.accounts.isEmpty ? "" : "\(model.accounts.count)"
        case .library: return model.library.apps.isEmpty ? "" : "\(model.library.apps.count)"
        default: return ""
        }
    }

    private var chromeRow: some View {
        SlipGlassContainer(spacing: 2) {
            HStack(spacing: 10) {
                ChromeCircleButton(symbol: "list.bullet", help: "Toggle navigation panel (⌘⇧S)") { appearance.selectionFeedback(); panelVisible.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                ChromeCircleButton(symbol: "tray.and.arrow.down", help: "Open IPA (⌘O)", action: openIPA)
                deviceMenu
                Text(pageTitle)
                    .font(.system(.title3, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ChromeCapsule {
                    ChromeIconButton(symbol: "arrow.clockwise", isEnabled: !model.isRefreshing, help: "Refresh devices (⌘R)") {
                        Task { await model.refreshDevices() }
                    }
                    ChromeDivider()
                    ChromeIconButton(symbol: "waveform.path.ecg", isActive: section == .activity, help: "Activity") { section = .activity }
                    ChromeDivider()
                    ChromeIconButton(symbol: "gearshape", isActive: section == .settings, help: "Settings (⌘,)") { section = .settings }
                }
            }
        }
        .padding(.leading, Chrome.trafficLightsWidth + Chrome.trafficLightClearance)
        .padding(.horizontal, Chrome.chromeHorizontalPadding)
        .padding(.top, Chrome.chromeTopPadding)
        .padding(.bottom, 16)
        .background(WindowDragRegion())
    }

    private var deviceMenu: some View {
        Button {
            appearance.selectionFeedback()
            showDevices.toggle()
        } label: {
            HStack(spacing: 6) {
                DeviceConnectionGlyph(device: model.selectedDevice, height: 20)
                Text(model.selectedDevice?.marketingName ?? "No iPhone").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(Chrome.inlineIconFont)
            .foregroundStyle(Chrome.primaryText)
            .padding(.horizontal, 12)
            .frame(height: Chrome.capsuleHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .chromeGlassCapsule()
        .background(NoWindowDragArea())
        .disabled(model.workspaceIsBusy)
        .help(model.selectedDevice.map { "\($0.displayName) · iOS \($0.version) · \($0.connectionType)" } ?? "Connect your iPhone")
        .accessibilityLabel("Choose iPhone")
        .popover(isPresented: $showDevices, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your iPhones")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                if model.devices.isEmpty {
                    Text("Unlock your iPhone, connect USB, and tap Trust.")
                        .font(.callout).foregroundStyle(Chrome.secondaryText).padding(10)
                }
                ForEach(model.devices) { device in
                    Button {
                        model.selectedDevice = device
                        appearance.selectionFeedback()
                        showDevices = false
                    } label: {
                        HStack(spacing: 10) {
                            DeviceConnectionGlyph(device: device, height: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.displayName).font(.system(size: 13, weight: .medium))
                                Text("\(device.marketingName) · iOS \(device.version) · \(device.connectionType == "Network" ? "Wi-Fi" : device.connectionType)")
                                    .font(.system(size: 11)).foregroundStyle(Chrome.secondaryText)
                            }
                            Spacer(minLength: 12)
                            if model.selectedDevice == device {
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(10)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                        .background(RoundedRectangle(cornerRadius: 10).fill(Chrome.overlay(model.selectedDevice == device ? 0.08 : 0)))
                    }
                    .buttonStyle(.plain)
                }
                Divider().padding(.vertical, 4)
                if model.devices.contains(where: { $0.connectionType.caseInsensitiveCompare("Network") == .orderedSame }) {
                    Label("Trusted Wi-Fi is ready", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(Chrome.secondaryText).padding(8)
                } else {
                    Button(model.isEnablingWiFi ? "Enabling Wi-Fi…" : "Enable Wi-Fi connection") {
                        appearance.selectionFeedback()
                        Task { await model.enableWiFiConnection() }
                    }
                    .disabled(model.isEnablingWiFi || model.selectedDevice?.connectionType.caseInsensitiveCompare("USB") != .orderedSame)
                    .padding(8)
                }
            }
            .padding(8)
            .frame(minWidth: 280)
        }
    }

    private func openIPA() {
        guard !model.workspaceIsBusy else { return }
        panelVisible = false
        section = .install
        Task {
            let urls = await WorkspaceFilePicker.ipas()
            if !urls.isEmpty { await model.importIPAs(urls) }
        }
    }
}

extension Notification.Name {
    static let showSlipSettings = Notification.Name("SlipShowSettings")
    static let showInstall = Notification.Name("SlipShowInstall")
}

private struct ModalScrim: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Color.black.opacity(reduceTransparency || contrast == .increased ? 0.32 : colorScheme == .dark ? 0.26 : 0.14)
            .ignoresSafeArea()
    }
}

private struct TwoFactorModalOverlay: View {
    @Binding var code: String
    let details: TwoFactorDetails?
    let isBusy: Bool
    let errorMessage: String?
    let statusMessage: String
    let onSubmit: (String) -> Void
    let onResend: () -> Void
    let onCancel: () -> Void
    let onChooseMethod: (UInt32?) -> Void
    @FocusState private var isFieldFocused: Bool

    private var cleanCode: String {
        code.filter { $0.isASCII && $0.isNumber }
    }

    private var smsDestination: String {
        if let selectedID = details?.selectedNumberId,
           let number = details?.numbers?.first(where: { $0.id == selectedID }) {
            return "Enter the code sent by SMS to \(number.displayNumber)."
        }
        return "Enter the code sent to your trusted phone by SMS."
    }

    var body: some View {
        ZStack {
            ModalScrim()

            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Verification")
                            .font(.title2.bold())
                        Text(details?.sms == true ? "Check your trusted phone for Apple's verification code." : "Check your iPhone, iPad, or Mac for the Apple Account verification prompt.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = errorMessage, !message.isEmpty {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
                if details?.unknown == true {
                    Text("Choose where Apple should send your verification code.")
                        .font(.subheadline)
                    Button("Send to Trusted Apple Devices") { onChooseMethod(nil) }
                        .disabled(isBusy)
                    ForEach(details?.numbers ?? []) { number in
                        Button("Send SMS to \(number.displayNumber)") { onChooseMethod(number.id) }
                    }
                    .disabled(isBusy)
                } else {
                if details?.sms == true {
                    Text(smsDestination).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    TextField("000000", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 180, height: 44)
                        .focused($isFieldFocused)
                        .textContentType(.oneTimeCode)
                        .disabled(isBusy)
                        .accessibilityLabel("Apple verification code")
                        .onSubmit {
                            if cleanCode.count == 6 && !isBusy {
                                onSubmit(cleanCode)
                            }
                        }
                        .onChange(of: code) { _, newValue in
                            let filtered = newValue.filter { $0.isASCII && $0.isNumber }
                            if filtered.count > 6 {
                                code = String(filtered.prefix(6))
                            } else if filtered != newValue {
                                code = filtered
                            }
                        }

                    Button("Resend Code") {
                        onResend()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .disabled(isBusy)
                }

                }
                if isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(statusMessage.isEmpty ? "Waiting for Apple…" : statusMessage)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Cancel", role: .cancel) {
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button("Continue") {
                        onSubmit(cleanCode)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(cleanCode.count != 6 || details?.unknown == true || isBusy)
                }
            }
            .padding(28)
            .frame(width: 460)
            .slipGlassSurface(cornerRadius: 18)
            .shadow(color: .black.opacity(0.20), radius: 24, x: 0, y: 12)
        }
        .onAppear {
            isFieldFocused = true
            NSApp.activate(ignoringOtherApps: true)
        }
        .onChange(of: isBusy) { _, busy in
            if !busy { isFieldFocused = true }
        }
    }
}

private struct CertificatesModalOverlay: View {
    let certificates: [CertificateInfo]
    @Binding var selectedCertificates: Set<String>
    let onSubmit: ([String]) -> Void
    let onCancel: () -> Void
    @State private var pendingRevocation: CertificateRevocationPlan?

    init(
        certificates: [CertificateInfo],
        selectedCertificates: Binding<Set<String>>,
        onSubmit: @escaping ([String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.certificates = certificates
        self._selectedCertificates = selectedCertificates
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    private var availableSerials: Set<String> {
        Set(CertificateRevocationPlan.availableSerialNumbers(in: certificates))
    }

    var body: some View {
        ZStack {
            ModalScrim()

            VStack(alignment: .leading, spacing: 18) {
                Label("Free a development certificate", systemImage: "key.fill")
                    .font(.title2.bold())
                Text("Apple has reached its certificate limit. Select certificates to revoke. Apps signed with them may stop opening and must be signed and installed again, including apps signed by other tools.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                List(certificates.filter { $0.serialNumber?.isEmpty == false }, selection: $selectedCertificates) { certificate in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(certificate.name ?? "Development certificate")
                            .font(.body.weight(.medium))
                        Text([certificate.machineName, certificate.serialNumber].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(certificate.serialNumber ?? "")
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack {
                    Button("Select All") { selectedCertificates = availableSerials }
                        .disabled(availableSerials.isEmpty || selectedCertificates == availableSerials)
                    Button("Clear Selection") { selectedCertificates.removeAll() }
                        .disabled(selectedCertificates.isEmpty)
                    Spacer()
                    Text("\(selectedCertificates.intersection(availableSerials).count) of \(availableSerials.count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Revoke All…", role: .destructive) {
                        pendingRevocation = CertificateRevocationPlan(certificates: certificates, selection: availableSerials, includesAll: true)
                    }
                    .disabled(availableSerials.isEmpty)
                    Button("Revoke Selected…", role: .destructive) {
                        pendingRevocation = CertificateRevocationPlan(certificates: certificates, selection: selectedCertificates)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedCertificates.isEmpty || !selectedCertificates.isSubset(of: availableSerials))
                }
            }
            .padding(28)
            .frame(width: 480)
            .slipGlassSurface(cornerRadius: 18)
            .shadow(color: .black.opacity(0.20), radius: 24, x: 0, y: 12)
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
        .confirmationDialog(pendingRevocation?.title ?? "Revoke development certificates?", isPresented: Binding(
            get: { pendingRevocation != nil }, set: { if !$0 { pendingRevocation = nil } }
        ), titleVisibility: .visible) {
            Button(pendingRevocation?.confirmationAction ?? "Revoke Certificates", role: .destructive) {
                guard let plan = pendingRevocation else { return }
                pendingRevocation = nil
                onSubmit(plan.serialNumbers)
            }
            Button("Keep Certificates", role: .cancel) { pendingRevocation = nil }
        } message: {
            Text(pendingRevocation?.confirmationMessage ?? "")
        }
    }
}

private struct AppIDExhaustedOverlay: View {
    let onGoToAccounts: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            ModalScrim()
            VStack(alignment: .leading, spacing: 18) {
                Label("App IDs consumed", systemImage: "square.stack.3d.up.trianglebadge.exclamationmark")
                    .font(.title2.bold())
                Text("Your free Apple Account has used all available App IDs for this seven-day period. Each app and kept extension needs one ID. You can remove optional extensions to reduce the count, wait for Apple's quota to reset, or manage existing App IDs in Apple Accounts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
                    Text("Free accounts allow up to 10 App IDs per seven-day rolling window. Deleting an App ID does not immediately restore the quota.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("Dismiss", role: .cancel, action: onDismiss).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Go to Apple Accounts") { onGoToAccounts() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(28)
            .frame(width: 440)
            .slipGlassSurface(cornerRadius: 18)
            .shadow(color: .black.opacity(0.20), radius: 24, x: 0, y: 12)
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

extension Notification.Name {
    static let showAccounts = Notification.Name("SlipShowAccounts")
}

struct PageHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
