// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Jordy Spruit (Droppy)
// Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app
// Modified by Slip: native sideloading interface, controls and compatibility.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum CustomizationPane: String, CaseIterable, Identifiable {
    case identity = "Identity"
    case extensions = "Extensions"
    case advanced = "Advanced"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .identity: "app.badge"
        case .extensions: "puzzlepiece.extension"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

struct InstallView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showURLImporter = false
    @State private var remoteIPAURL = ""
    @State private var dropActive = false
    @State private var customizationPane: CustomizationPane = .identity

    private var ipaType: UTType { UTType(filenameExtension: "ipa") ?? .archive }
    private var motion: Bool { appearance.motionAllowed && !reduceMotion }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ipaCard
                        .frame(minHeight: model.ipa == nil ? max(260, geometry.size.height - 95) : 0)

                    if model.ipa != nil {
                        if let notice = model.ipaPreparationNotice {
                            Label(notice, systemImage: "info.circle")
                                .font(.callout).foregroundStyle(Chrome.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !model.postProvisionChecks.isEmpty { SigningReadinessPanel(preflight: .init(schemaVersion: 1, checks: model.postProvisionChecks)) }
                        statusRibbon
                        if let preflight = model.ipa?.preflight { SigningReadinessPanel(preflight: preflight) }
                        appIDPlannerCard
                        customizationCard
                            .disabled(model.isInstalling || model.isRunningInstallQueue || model.isImportingLibrary || model.isRestoringWorkspace)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if model.ipa == nil, let notice = model.libraryNotice {
                        HStack(spacing: 12) {
                            Label(notice, systemImage: "info.circle").font(.callout)
                            Spacer()
                            Button("Open Library") { NotificationCenter.default.post(name: .showLibrary, object: nil) }
                                .buttonStyle(WorkspaceActionButtonStyle())
                        }
                    }

                    DeviceHealthPanel().environmentObject(model)
                    readinessCard
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .background(SlipBackdrop())
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.workspaceIsBusy, urls.contains(where: { $0.isFileURL && $0.pathExtension.lowercased() == "ipa" }) else { return false }
            Task { await model.importIPAs(urls) }
            return true
        } isTargeted: { dropActive = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionDock }
        .animation(motion ? .smooth(duration: 0.28) : nil, value: model.ipa)
        .animation(motion ? .snappy(duration: 0.24) : nil, value: dropActive)
        .onChange(of: dropActive) { _, active in if active { appearance.selectionFeedback() } }
        .onChange(of: model.ipa) { _, ipa in if ipa != nil { appearance.completionFeedback() } }

        .alert("Download IPA", isPresented: $showURLImporter) {
            TextField("https://example.com/App.ipa", text: $remoteIPAURL)
            Button("Cancel", role: .cancel) { remoteIPAURL = "" }
            Button("Download") {
                let input = remoteIPAURL
                remoteIPAURL = ""
                Task { await model.downloadIPA(from: input) }
            }
            .disabled(remoteIPAURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Slip retries transient failures and validates the archive before it becomes installable.")
        }
    }

    private func homeActionIcon(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button {
            appearance.selectionFeedback()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Chrome.primaryText)
                .frame(width: 84, height: 84)
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .slipGlassSurface(interactive: true, cornerRadius: 22)
        }
        .buttonStyle(.plain)
        .disabled(model.workspaceIsBusy)
        .help(title)
        .accessibilityLabel(title)
    }

    private var statusRibbon: some View {
        HStack(spacing: 16) {
            Label(
                model.selectedDevice.map { "\($0.connectionType) · iOS \($0.version)" } ?? "No iPhone",
                systemImage: model.selectedDevice?.connectionType.lowercased() == "network" ? "wifi" : "iphone"
            )
            Label(
                model.ipa.map { Int64($0.sizeBytes).formatted(.byteCount(style: .file)) } ?? "No IPA",
                systemImage: "shippingbox"
            )
            Label(model.selectedAccount.isEmpty ? "No account" : "Account ready", systemImage: "person.badge.key")
            Spacer(minLength: 0)
            if model.customizationCount > 0 {
                Text("\(model.customizationCount) changes")
                    .foregroundStyle(Color.accentColor)
                    .transition(.opacity)
            }
        }
        .font(.caption)
        .foregroundStyle(Color.primary.opacity(0.7))
    }

    private var ipaCard: some View {
        ZStack {
            if let ipa = model.ipa {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ipaIconPreview(for: ipa)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ipa.appName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Text(ipa.bundleId).font(.caption.monospaced()).foregroundStyle(Color.primary.opacity(0.7)).lineLimit(1)
                        }
                        Spacer()
                        Menu {
                            Button("Choose Another…") { chooseIPAs() }
                            Button("Download from URL…") { showURLImporter = true }
                            Divider()
                            Button("Remove IPA", role: .destructive) { model.clearIPA() }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .disabled(model.workspaceIsBusy)
                    }
                    HStack(spacing: 18) {
                        metric(ipa.version, "Version")
                        metric(ipa.minimumOsVersion ?? "—", "Minimum iOS")
                        metric("\(model.effectiveAppIDCost)", "App IDs")
                        Spacer()
                        if let duration = model.inspectionDuration {
                            Label("Inspected in \(duration.formatted(.number.precision(.fractionLength(2)))) s", systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }
            } else {
                VStack(spacing: 18) {
                    if let device = model.selectedDevice {
                        IPhoneModelPreview(device: device)
                            .id(device.udid + device.connectionType)
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                            .resizable().frame(width: 88, height: 88)
                    }
                    VStack(spacing: 9) {
                        Text(model.isInspecting ? "Inspecting your app…" : "Your iPhone. Your apps.")
                            .font(.system(size: 30, weight: .semibold))
                        Text(model.selectedDevice.map { "\($0.displayName) is connected. Drop an IPA to make it yours." }
                             ?? "A calm, native home for your iPhone apps.")
                            .font(.system(size: 14))
                            .foregroundStyle(Chrome.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    HStack(spacing: 18) {
                        homeActionIcon("doc.zipper", title: "Choose an IPA") {
                            chooseIPAs()
                        }
                        homeActionIcon("link", title: "From URL") {
                            showURLImporter = true
                        }
                    }
                    .padding(.vertical, 4)
                    Text("Or drop an IPA anywhere in this workspace.")
                        .font(.system(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                    if model.isInspecting && !model.isDownloading {
                        ProgressView("Checking archive…")
                            .controlSize(.small)
                    }
                }
                .padding(28)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(model.ipa == nil ? 0 : 16)
        .background {
            if model.ipa != nil {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Chrome.overlay(0.03))
            }
        }
        .background(dropActive ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            if dropActive {
                RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.workspaceIsBusy, urls.contains(where: { $0.isFileURL && $0.pathExtension.lowercased() == "ipa" }) else { return false }
            Task { await model.importIPAs(urls) }
            return true
        } isTargeted: { dropActive = $0 }
    }

    @ViewBuilder
    private func ipaIconPreview(for ipa: IpaInfo) -> some View {
        if let url = model.ipaIconURL {
            CachedIPAIcon(url: url, name: ipa.appName)
        } else {
            SlipSymbolTile(
                symbol: model.isInspecting ? "sparkle.magnifyingglass" : (ipa.encryptionStatus == "Encrypted" ? "lock.fill" : "app.dashed"),
                tint: ipa.encryptionStatus == "Encrypted" ? .orange : Chrome.accent,
                size: 52
            )
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.callout.weight(.semibold)).contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(Color.primary.opacity(0.7))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var customizationCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Picker("Customization", selection: $customizationPane) {
                        ForEach(CustomizationPane.allCases) { pane in
                            Label(pane.rawValue, systemImage: pane.symbol).tag(pane)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 470)
                    Spacer()
                    Button("Reset") { model.resetCustomizations() }
                        .disabled(model.customizationCount == 0)
                }

                Group {
                    switch customizationPane {
                    case .identity: identityCustomization
                    case .extensions: extensionCustomization
                    case .advanced: advancedCustomization
                    }
                }
                .id(customizationPane)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
                .animation(motion ? .smooth(duration: 0.22) : nil, value: customizationPane)
            }
        } label: {
            HStack {
                Label("Customize", systemImage: "slider.horizontal.3")
                Spacer()
                if model.customizationCount > 0 {
                    Text("\(model.customizationCount) changes").font(.caption).foregroundStyle(.tint)
                }
            }
        }
    }

    private var identityCustomization: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 13) {
            GridRow {
                Text("Home Screen name")
                TextField(model.ipa?.appName ?? "App name", text: $model.customName)
            }
            GridRow {
                Text("Bundle ID")
                TextField(model.ipa?.bundleId ?? "com.example.app", text: $model.customBundleID)
                    .font(.body.monospaced())
            }
            GridRow {
                Text("App icon")
                HStack {
                    if let url = model.customIconURL, let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFill().frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text(model.customIconURL?.lastPathComponent ?? "Keep original icon")
                        .foregroundStyle(model.customIconURL == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer()
                    if model.customIconURL != nil { Button("Clear") { model.customIconURL = nil } }
                    Button("Choose…") { chooseIcon() }
                }
            }
        }
    }

    private var extensionCustomization: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Embedded extensions").fontWeight(.semibold)
                    Text("Only kept extensions consume App IDs and are signed.").font(.caption).foregroundStyle(Color.primary.opacity(0.7))
                }
                Spacer()
                Button("Remove All") { model.removedExtensions = Set(model.ipa?.extensions.map(\.path) ?? []) }
                Button("Keep All") { model.removedExtensions.removeAll() }
            }
            if model.ipa?.extensions.isEmpty != false {
                ContentUnavailableView("No Extensions", systemImage: "puzzlepiece.extension", description: Text("This IPA uses one App ID."))
                    .frame(minHeight: 90)
            } else {
                ForEach(model.ipa?.extensions ?? []) { item in
                    Toggle(isOn: Binding(
                        get: { !model.removedExtensions.contains(item.path) },
                        set: { keep in
                            if keep { model.removedExtensions.remove(item.path) }
                            else { model.removedExtensions.insert(item.path) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                            Text(item.extensionPoint ?? item.bundleId).font(.caption.monospaced()).foregroundStyle(Color.primary.opacity(0.7))
                        }
                    }
                }
            }
        }
    }

    private var advancedCustomization: some View {
        VStack(alignment: .leading, spacing: 15) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow {
                    Text("Minimum iOS")
                    TextField(model.ipa?.minimumOsVersion ?? "Unchanged", text: $model.minimumOSVersion)
                        .frame(maxWidth: 180)
                }
            }
            Toggle("Remove supported-device model restriction", isOn: $model.removeSupportedDevices)
            Toggle("Enable Files and Finder document sharing", isOn: $model.enableFileSharing)
            Toggle("Request increased-memory entitlement", isOn: $model.increasedMemoryLimit)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Info.plist overrides").fontWeight(.semibold)
                    Text("Typed, top-level values; identity-critical keys are protected.").font(.caption).foregroundStyle(Color.primary.opacity(0.7))
                }
                Spacer()
                Button { model.addPlistOverride() } label: { Label("Add Key", systemImage: "plus") }
            }
            ForEach($model.plistOverrides) { $item in
                HStack(spacing: 10) {
                    TextField("Key", text: $item.key).font(.body.monospaced())
                    Picker("Type", selection: $item.valueType) {
                        ForEach(["String", "Boolean", "Integer", "Real"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                    TextField(item.valueType == "Boolean" ? "true or false" : "Value", text: $item.value)
                    Button(role: .destructive) { model.removePlistOverride(item.id) } label: {
                        Image(systemName: "minus.circle")
                            .slipDimensionalSymbol(strength: 0.72)
                    }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private var appIDPlannerCard: some View {
        let plan = model.appIDPlan
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(plan.summary).font(.callout.weight(.semibold))
                    Spacer()
                    Button("Check with Apple") { Task { await model.manageAccount() } }
                        .disabled(model.workspaceIsBusy || model.selectedAccount.isEmpty)
                }
                Text("Includes this workspace and ready queue entries for the selected account; shared IDs count once.")
                    .font(.caption).foregroundStyle(Chrome.secondaryText)
                if let checkedAt = plan.checkedAt {
                    Text("Apple registrations checked \(checkedAt.formatted(date: .abbreviated, time: .shortened)). Counts are a plan, not a reservation.")
                        .font(.caption).foregroundStyle(Chrome.secondaryText)
                } else {
                    Text("Estimate: account registrations have not been checked. All IDs are counted as new until you check with Apple.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(plan.resourceState).font(.caption).foregroundStyle(Chrome.secondaryText)
                if let remaining = plan.remaining {
                    Text("Apple last reported \(remaining) available. \(plan.newCount > remaining ? "Remove optional extensions or wait for quota to renew." : "Availability can change before signing.")")
                        .font(.caption).foregroundStyle(plan.newCount > remaining ? Color.orange : Chrome.secondaryText)
                } else {
                    Text("Apple has not confirmed available quota; the number of registered IDs does not prove remaining capacity.")
                        .font(.caption).foregroundStyle(Chrome.secondaryText)
                }
                DisclosureGroup("App IDs and optional extensions") {
                    ForEach(plan.entries) { entry in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name + (entry.optional ? " · Optional extension" : ""))
                                Text(entry.bundleID).font(.caption.monospaced()).foregroundStyle(Chrome.secondaryText)
                            }
                            Spacer()
                            Text(entry.reused ? "Reuse" : "New ID").foregroundStyle(entry.reused ? Color.green : Color.orange)
                        }.font(.caption).padding(.vertical, 3)
                    }
                }
                if let error = model.resourcesError {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
        } label: { Label("App ID planner", systemImage: "square.stack.3d.up") }
    }

    private var readinessCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.installReadiness) { issue in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: issue.symbol)
                            .foregroundStyle(color(for: issue.level))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title).font(.caption.weight(.medium))
                            Text(issue.detail).font(.caption).foregroundStyle(Color.primary.opacity(0.7))
                        }
                        Spacer()
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label(model.blockingInstallIssue?.title ?? "Ready to sign and install", systemImage: model.blockingInstallIssue == nil ? "checkmark.shield" : "info.circle")
                .font(.caption)
                .foregroundStyle(model.blockingInstallIssue == nil ? Color.green : Color.primary.opacity(0.7))
        }
        .tint(.secondary)
    }

    private func color(for level: SlipIssueLevel) -> Color {
        switch level {
        case .ready: .green
        case .warning: .orange
        case .blocking: .red
        }
    }

    private var actionDock: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.isInstalling {
                HStack(spacing: 8) {
                    Image(systemName: model.ipa == nil ? "shippingbox" : "app.badge.checkmark")
                        .foregroundStyle(Chrome.secondaryText)
                    Text(model.ipa.map { "\($0.appName) is ready to personalize and sign." } ?? "Choose an IPA, then sign and install it on your iPhone.")
                        .font(.system(size: 13))
                        .foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let device = model.selectedDevice {
                        DeviceConnectionGlyph(device: device, height: 18)
                        Text(device.connectionType.caseInsensitiveCompare("Network") == .orderedSame ? "Wi-Fi" : device.connectionType).font(.caption).foregroundStyle(Chrome.secondaryText)
                    }
                }
            }
            if let error = model.errorMessage {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        model.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.primary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss error")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.red.opacity(0.25), lineWidth: 1)
                )
            }

            if model.isDownloading {
                DownloadProgressContent(progress: model.operationProgress, inspecting: model.isInspecting, motion: motion) { model.cancelDownload() }
                if model.downloadProgress?.canPause == true && !model.isInspecting {
                    Button("Pause Download") { model.pauseDownload() }
                }
            } else if model.pausedDownload != nil {
                HStack {
                    Label("Download paused · partial file preserved", systemImage: "pause.circle")
                    Spacer()
                    Button("Resume Download") { Task { await model.resumeDownload() } }
                    Button("Cancel Download", role: .destructive) { model.cancelDownload() }
                }
            } else if model.isInstalling {
                if model.showTwoFactor {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(Color.accentColor)
                        Text("Apple 2FA:")
                            .font(.subheadline.bold())
                        TextField("000000", text: $model.verificationCode)
                            .textFieldStyle(.roundedBorder)
                            .font(.headline.monospacedDigit())
                            .frame(width: 120)
                            .onSubmit {
                                let clean = model.verificationCode.filter { $0.isASCII && $0.isNumber }
                                if clean.count == 6 {
                                    model.submitTwoFactor(clean)
                                }
                            }
                        Button("Submit Code") {
                            let clean = model.verificationCode.filter { $0.isASCII && $0.isNumber }
                            model.submitTwoFactor(clean)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.verificationCode.filter { $0.isASCII && $0.isNumber }.count != 6)

                        Button("Resend") {
                            model.resendTwoFactor()
                        }
                        .controlSize(.small)

                        Button("Cancel", role: .cancel) {
                            model.submitTwoFactor(nil)
                        }
                        .controlSize(.small)
                    }
                } else {
                    InstallProgressContent(progress: model.operationProgress) { model.cancelInstall() }
                }
            } else if model.isRunningInstallQueue || model.isImportingLibrary || model.isRestoringWorkspace {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(model.isRunningInstallQueue ? "Preparing next app…" : model.isImportingLibrary ? "Adding apps to your library…" : "Restoring workspace…")
                    Spacer()
                    if model.isRunningInstallQueue { Button("Stop Queue") { model.stopInstallQueue() } }
                }
            } else {
                HStack(spacing: 10) {
                    if model.accounts.isEmpty {
                        Button { NotificationCenter.default.post(name: .showAccounts, object: nil) } label: {
                            Label("Add Apple Account", systemImage: "person.badge.plus")
                                .foregroundStyle(.primary)
                        }
                    } else {
                        Picker("Apple Account", selection: $model.selectedAccount) {
                            ForEach(model.accounts, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .onChange(of: model.selectedAccount) { _, value in model.chooseAccount(value) }
                    }

                    Toggle("Keep refreshed", isOn: $model.keepAutomaticallyRefreshed)
                        .toggleStyle(.switch)
                        .help("Refresh about 24 hours before the free seven-day profile expires")
                    Spacer()
                    Button { model.saveWorkspaceToQueue() } label: {
                        Label(model.reviewingQueueID == nil ? "Queue" : "Save to Queue", systemImage: "text.badge.plus")
                    }
                    .help(model.reviewingQueueID == nil ? "Add reviewed app to installation queue" : "Save reviewed choices to queue")
                    .accessibilityLabel(model.reviewingQueueID == nil ? "Add to Queue" : "Save to Queue")
                    .disabled(!model.canInstall)
                    if let refreshingName = model.currentlyRefreshingAppName {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Refreshing \(refreshingName)…")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.primary.opacity(0.7))
                        }
                    }
                    Button { exportIPA() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        .disabled(!model.canExport || model.isExporting)
                    Button { appearance.selectionFeedback(); model.install() } label: {
                        Label(
                            model.currentlyRefreshingAppName != nil ? "App Refreshing…" : "Sign & Install",
                            systemImage: model.currentlyRefreshingAppName != nil ? "arrow.triangle.2.circlepath" : "arrow.down.app.fill"
                        )
                    }
                        .slipProminentButton()
                        .controlSize(.regular)
                        .disabled(!model.canInstall)
                        .help(model.blockingInstallIssue.map { "\($0.title): \($0.detail)" } ?? "Sign and install on the selected iPhone")
                }
            }
            if let notice = model.authenticationNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: 860)
        .slipGlassSurface(cornerRadius: 22)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .animation(motion ? .snappy(duration: 0.25) : nil, value: model.isInstalling)
    }

    private func chooseIPAs() {
        guard !model.workspaceIsBusy else { return }
        Task {
            let urls = await WorkspaceFilePicker.ipas()
            if !urls.isEmpty { await model.importIPAs(urls) }
        }
    }

    private func chooseIcon() {
        guard !model.workspaceIsBusy else { return }
        Task { if let url = await WorkspaceFilePicker.image() { model.customIconURL = url } }
    }

    private func exportIPA() {
        guard let ipa = model.ipa else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ipaType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(ipa.appName)-Slip.ipa"
        panel.title = "Export Prepared IPA"
        panel.prompt = "Export"
        if panel.runModal() == .OK, let url = panel.url { model.exportModifiedIPA(to: url) }
    }
}

private struct CachedIPAIcon: View {
    let url: URL
    let name: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high).scaledToFill() }
            else { Image(systemName: "app.dashed").font(.title).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.8) }
        .accessibilityLabel("\(name) app icon")
        .task(id: url) {
            image = nil
            let decoded = await ThumbnailCache.shared.image(file: url)
            if !Task.isCancelled { image = decoded }
        }
    }
}

private struct DownloadProgressContent: View {
    @ObservedObject var progress: OperationProgress
    let inspecting: Bool
    let motion: Bool
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(inspecting ? "Checking downloaded IPA…" : "Downloading IPA")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if let fraction = progress.download?.fraction, !inspecting {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit()).foregroundStyle(Chrome.secondaryText)
                }
                Button("Cancel", action: cancel).buttonStyle(WorkspaceActionButtonStyle())
            }
            if let fraction = progress.download?.fraction, !inspecting {
                ProgressView(value: fraction)
                    .animation(motion ? .linear(duration: 0.15) : nil, value: fraction)
            } else { ProgressView().progressViewStyle(.linear) }
            if let detail = progress.download?.detail {
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(Chrome.secondaryText).lineLimit(1)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct InstallProgressContent: View {
    @ObservedObject var progress: OperationProgress
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(progress.stage).fontWeight(.semibold)
            ProgressView(value: progress.fraction).frame(maxWidth: .infinity)
            Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit()).foregroundStyle(Chrome.secondaryText).contentTransition(.numericText())
            Button("Cancel", role: .destructive, action: cancel)
        }
    }
}
