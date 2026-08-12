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
    @State private var showIPAImporter = false
    @State private var showIconImporter = false
    @State private var showURLImporter = false
    @State private var remoteIPAURL = ""
    @State private var dropActive = false
    @State private var customizationPane: CustomizationPane = .identity

    private var ipaType: UTType { UTType(filenameExtension: "ipa") ?? .archive }
    private var motion: Bool { appearance.motionAllowed && !reduceMotion }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    eyebrow: "IPHONE SIDELOADER",
                    title: "Install",
                    subtitle: "Inspect, personalize, sign, and transfer—with every requirement checked first."
                )
                .padding(.horizontal, -28)
                .padding(.top, -22)

                statusRibbon

                SlipGlassContainer {
                    HStack(alignment: .top, spacing: 18) {
                        deviceCard
                        ipaCard
                    }
                }

                if model.ipa != nil {
                    customizationCard
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                readinessCard
            }
            .padding(28)
            .padding(.bottom, 92)
        }
        .scrollIndicators(.hidden)
        .background(SlipBackdrop())
        .safeAreaInset(edge: .bottom, spacing: 0) { actionDock }
        .animation(motion ? .smooth(duration: 0.28) : nil, value: model.ipa)
        .animation(motion ? .snappy(duration: 0.24) : nil, value: dropActive)
        .fileImporter(isPresented: $showIPAImporter, allowedContentTypes: [ipaType]) { result in
            if case .success(let url) = result { Task { await model.loadIPA(url) } }
        }
        .fileImporter(isPresented: $showIconImporter, allowedContentTypes: [.png, .jpeg]) { result in
            if case .success(let url) = result { model.customIconURL = url }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openIPA)) { _ in
            showIPAImporter = true
        }
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

    private var statusRibbon: some View {
        HStack(spacing: 10) {
            SlipStatusPill(
                title: model.selectedDevice.map { "\($0.connectionType) · iOS \($0.version)" } ?? "No iPhone",
                symbol: model.selectedDevice?.connectionType.lowercased() == "network" ? "wifi" : "iphone",
                tint: model.selectedDevice == nil ? .secondary : .green
            )
            SlipStatusPill(
                title: model.ipa.map { Int64($0.sizeBytes).formatted(.byteCount(style: .file)) } ?? "No IPA",
                symbol: "shippingbox",
                tint: model.ipa == nil ? .secondary : .blue
            )
            SlipStatusPill(
                title: model.selectedAccount.isEmpty ? "No account" : "Account ready",
                symbol: "person.badge.key",
                tint: model.selectedAccount.isEmpty ? .secondary : .purple
            )
            if model.customizationCount > 0 {
                SlipStatusPill(title: "\(model.customizationCount) changes", symbol: "slider.horizontal.3", tint: .cyan)
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer()
        }
    }

    private var deviceCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    if let device = model.selectedDevice {
                        IPhoneModelPreview(device: device)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    } else {
                        SlipSymbolTile(symbol: "iphone.gen3", tint: .secondary, size: 52)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        if let device = model.selectedDevice {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(device.displayName)
                                    .font(.title3.weight(.semibold))
                                    .lineLimit(1)
                                if device.showsModelBesideName {
                                    Text("(\(device.marketingName))")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        } else {
                            Text("Connect an iPhone")
                                .font(.title3.weight(.semibold))
                        }
                        Text(model.selectedDevice.map { "\($0.connectionType) connection · iOS \($0.version)" } ?? "Unlock, connect USB, and tap Trust.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await model.refreshDevices() }
                    } label: {
                        if model.isRefreshing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise").slipDimensionalSymbol() }
                    }
                    .help("Refresh iPhones")
                    .disabled(model.isRefreshing || model.isInstalling)
                }

                if !model.devices.isEmpty {
                    Picker("Destination", selection: $model.selectedDevice) {
                        ForEach(model.devices) { device in
                            Text("\(device.displayName)\(device.showsModelBesideName ? " (\(device.marketingName))" : "") · \(device.connectionType)").tag(Optional(device))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }

                Divider()

                if model.devices.contains(where: { $0.connectionType.caseInsensitiveCompare("Network") == .orderedSame }) {
                    Label("Trusted Wi‑Fi is ready; use USB when speed matters.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    HStack {
                        Label("Pair Wi‑Fi while connected by USB.", systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Enable Wi‑Fi") { Task { await model.enableWiFiConnection() } }
                            .disabled(model.isEnablingWiFi || model.selectedDevice?.connectionType.caseInsensitiveCompare("USB") != .orderedSame)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 174, alignment: .top)
        } label: {
            Label("Destination", systemImage: "cable.connector")
        }
        .frame(maxWidth: .infinity)
    }

    private var ipaCard: some View {
        GroupBox {
            ZStack {
                if let ipa = model.ipa {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack(spacing: 14) {
                            ipaIconPreview(for: ipa)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(ipa.appName).font(.title3.weight(.semibold)).lineLimit(1)
                                Text(ipa.bundleId).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Menu {
                                Button("Choose Another…") { showIPAImporter = true }
                                Button("Download from URL…") { showURLImporter = true }
                                Divider()
                                Button("Remove IPA", role: .destructive) { model.clearIPA() }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .slipDimensionalSymbol()
                            }
                            .menuStyle(.borderlessButton)
                        }
                        HStack(spacing: 9) {
                            metric(ipa.version, "Version")
                            metric(ipa.minimumOsVersion ?? "—", "Minimum iOS")
                            metric("\(model.effectiveAppIDCost)", "App IDs")
                        }
                        if let duration = model.inspectionDuration {
                            Label("Inspected in \(duration.formatted(.number.precision(.fractionLength(2)))) seconds", systemImage: "bolt.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: model.isInspecting ? "sparkle.magnifyingglass" : "square.and.arrow.down.on.square")
                            .font(.system(size: 34, weight: .light))
                            .slipDimensionalSymbol(strength: 1.18)
                            .foregroundStyle(dropActive ? Color.accentColor : .secondary)
                            .scaleEffect(dropActive ? 1.12 : 1)
                        Text(model.isInspecting ? "Inspecting IPA…" : "Drop an IPA")
                            .font(.title3.weight(.semibold))
                        Text("Local, private, and validated before signing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Choose IPA…") { showIPAImporter = true }
                            Button("From URL…") { showURLImporter = true }
                        }
                        if model.isDownloading { ProgressView("Downloading…").controlSize(.small) }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 174)
            .padding(4)
            .background(dropActive ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 17))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { $0.pathExtension.lowercased() == "ipa" }) else { return false }
                Task { await model.loadIPA(url) }
                return true
            } isTargeted: { dropActive = $0 }
        } label: {
            Label("IPA", systemImage: "shippingbox")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func ipaIconPreview(for ipa: IpaInfo) -> some View {
        if let url = model.ipaIconURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.20), radius: 7, y: 3)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .accessibilityLabel("\(ipa.appName) app icon")
        } else {
            SlipSymbolTile(
                symbol: model.isInspecting ? "sparkle.magnifyingglass" : (ipa.encryptionStatus == "Encrypted" ? "lock.fill" : "app.dashed"),
                tint: ipa.encryptionStatus == "Encrypted" ? .orange : .blue,
                size: 52
            )
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.callout.weight(.semibold)).contentTransition(.numericText())
            Text(label).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private var customizationCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 18) {
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
                    Button("Choose…") { showIconImporter = true }
                }
            }
        }
    }

    private var extensionCustomization: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Embedded extensions").fontWeight(.semibold)
                    Text("Only kept extensions consume App IDs and are signed.").font(.caption).foregroundStyle(.secondary)
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
                            Text(item.extensionPoint ?? item.bundleId).font(.caption.monospaced()).foregroundStyle(.secondary)
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
                    Text("Typed, top-level values; identity-critical keys are protected.").font(.caption).foregroundStyle(.secondary)
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

    private var readinessCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.installReadiness) { issue in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: issue.symbol)
                            .slipDimensionalSymbol(strength: 0.82)
                            .foregroundStyle(color(for: issue.level))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title).fontWeight(.semibold)
                            Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
            }
        } label: {
            Label("Preflight", systemImage: model.blockingInstallIssue == nil ? "checkmark.shield" : "exclamationmark.shield")
        }
    }

    private func color(for level: SlipIssueLevel) -> Color {
        switch level {
        case .ready: .green
        case .warning: .orange
        case .blocking: .red
        }
    }

    private var actionDock: some View {
        VStack(spacing: 10) {
            if model.isInstalling {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(model.currentStage).fontWeight(.semibold)
                    ProgressView(value: model.overallProgress).frame(maxWidth: .infinity)
                    Text(model.overallProgress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).contentTransition(.numericText())
                    Button("Cancel", role: .destructive) { model.cancelInstall() }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        if model.accounts.isEmpty {
                            Button { NotificationCenter.default.post(name: .showAccounts, object: nil) } label: {
                                Label("Add Apple Account", systemImage: "person.badge.plus")
                            }
                        } else {
                            Picker("Apple Account", selection: $model.selectedAccount) {
                                ForEach(model.accounts, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 250)
                            .onChange(of: model.selectedAccount) { _, value in model.chooseAccount(value) }
                        }

                        Toggle("Auto Refresh", isOn: $model.keepAutomaticallyRefreshed)
                            .toggleStyle(.switch)
                            .help("Refresh about 24 hours before the free seven-day profile expires")
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        Button { exportIPA() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                            .fixedSize(horizontal: true, vertical: false)
                            .disabled(!model.canExport || model.isExporting)
                        Button { model.install() } label: { Label("Sign & Install", systemImage: "arrow.down.app.fill") }
                            .slipProminentButton()
                            .controlSize(.large)
                            .fixedSize(horizontal: true, vertical: false)
                            .disabled(!model.canInstall)
                            .help(model.blockingInstallIssue.map { "\($0.title): \($0.detail)" } ?? "Sign and install on the selected iPhone")
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .slipGlassSurface(tint: Color.accentColor.opacity(0.08), interactive: true, cornerRadius: 24)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .animation(motion ? .snappy(duration: 0.25) : nil, value: model.isInstalling)
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
