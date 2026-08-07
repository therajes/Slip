import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InstallView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showIPAImporter = false
    @State private var showIconImporter = false
    @State private var showURLImporter = false
    @State private var remoteIPAURL = ""
    @State private var dropActive = false

    private var ipaType: UTType { UTType(filenameExtension: "ipa") ?? .archive }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    eyebrow: "NATIVE IPA INSTALLER",
                    title: "Install",
                    subtitle: "Prepare, sign, and stream an IPA directly to your iPhone."
                )
                .padding(.horizontal, -28)
                .padding(.top, -24)

                deviceSection
                ipaSection
                if model.ipa != nil { customizationSection }
                installSection
            }
            .padding(28)
        }
        .background(SlipBackdrop())
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
        } message: {
            Text("Slip retries downloads three times and keeps the verified IPA locally for Auto Refresh.")
        }
    }

    private var deviceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                        .frame(width: 42)
                    if model.devices.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("No iPhone detected").fontWeight(.semibold)
                            Text("Unlock your iPhone, connect USB, and tap Trust if asked.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Device", selection: $model.selectedDevice) {
                            ForEach(model.devices) { device in
                                Text("\(device.name) · \(device.connectionType) · iOS \(device.version)")
                                    .tag(Optional(device))
                            }
                        }
                        .labelsHidden()
                    }
                    Spacer()
                    Button {
                        Task { await model.refreshDevices() }
                    } label: {
                        if model.isRefreshing { ProgressView().controlSize(.small) }
                        else { Label("Refresh", systemImage: "arrow.clockwise") }
                    }
                    .disabled(model.isRefreshing || model.isInstalling)
                }

                Divider()

                if model.devices.contains(where: { $0.connectionType.caseInsensitiveCompare("Network") == .orderedSame }) {
                    Label("Wi‑Fi connection is available. Auto Refresh will prefer it.", systemImage: "wifi")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    HStack(spacing: 10) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Apple’s trusted Wi‑Fi connection while the iPhone is attached by USB.")
                                Text("Use a shared router or another device’s hotspot—this iPhone’s own Personal Hotspot cannot be its network connection.")
                                    .foregroundStyle(.tertiary)
                            }
                        } icon: {
                            Image(systemName: "wifi.exclamationmark")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            model.copySelectedUDID()
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .help("Copy UDID")
                        Button {
                            Task { await model.enableWiFiConnection() }
                        } label: {
                            if model.isEnablingWiFi {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Enable Wi‑Fi Connection")
                            }
                        }
                        .disabled(
                            model.isEnablingWiFi ||
                            model.selectedDevice?.connectionType.caseInsensitiveCompare("USB") != .orderedSame
                        )
                    }
                }
            }
            .padding(10)
        } label: {
            Label("1 · Destination", systemImage: "cable.connector")
        }
    }

    private var ipaSection: some View {
        GroupBox {
            VStack(spacing: 14) {
                if let ipa = model.ipa {
                    HStack(spacing: 16) {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(.tint.opacity(0.14))
                            .frame(width: 64, height: 64)
                            .overlay(Image(systemName: "app.dashed").font(.system(size: 28)).foregroundStyle(.tint))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(ipa.appName).font(.title3.bold())
                            Text("\(ipa.bundleId) · \(ipa.version) (\(ipa.buildVersion))")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Text(Int64(ipa.sizeBytes).formatted(.byteCount(style: .file)))
                                Text("Minimum iOS \(ipa.minimumOsVersion ?? "Unknown")")
                                Label(ipa.encryptionStatus, systemImage: ipa.encryptionStatus == "Encrypted" ? "lock.fill" : "lock.open.fill")
                                    .foregroundStyle(ipa.encryptionStatus == "Encrypted" ? .orange : .secondary)
                                Text("\(ipa.appIdCost) App ID\(ipa.appIdCost == 1 ? "" : "s")")
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Choose Another…") { showIPAImporter = true }
                    }
                    if !ipa.warnings.isEmpty {
                        Divider()
                        ForEach(ipa.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(dropActive ? Color.accentColor : .secondary)
                        Text(model.isInspecting ? "Inspecting IPA…" : "Drop an IPA here")
                            .font(.title3.weight(.semibold))
                        Text("The file stays on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Choose IPA…") { showIPAImporter = true }
                            Button("From URL…") { showURLImporter = true }
                        }
                        if model.isDownloading {
                            ProgressView("Downloading…")
                                .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 170)
                }
            }
            .padding(10)
            .background(dropActive ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { $0.pathExtension.lowercased() == "ipa" }) else { return false }
                Task { await model.loadIPA(url) }
                return true
            } isTargeted: { dropActive = $0 }
        } label: {
            Label("2 · IPA", systemImage: "shippingbox")
        }
    }

    private var customizationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow {
                        Text("App name")
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
                            Text(model.customIconURL?.lastPathComponent ?? "Original icon")
                                .foregroundStyle(model.customIconURL == nil ? .secondary : .primary)
                            Spacer()
                            if model.customIconURL != nil {
                                Button("Clear") { model.customIconURL = nil }
                            }
                            Button("Choose…") { showIconImporter = true }
                        }
                    }
                }

                if let extensions = model.ipa?.extensions, !extensions.isEmpty {
                    Divider()
                    HStack {
                        VStack(alignment: .leading) {
                            Text("App extensions").fontWeight(.semibold)
                            Text("Removed by default to preserve your free App ID quota.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove All") { model.removedExtensions = Set(extensions.map(\.path)) }
                        Button("Keep All") { model.removedExtensions.removeAll() }
                    }
                    ForEach(extensions) { item in
                        Toggle(isOn: Binding(
                            get: { !model.removedExtensions.contains(item.path) },
                            set: { keep in
                                if keep { model.removedExtensions.remove(item.path) }
                                else { model.removedExtensions.insert(item.path) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                Text(item.bundleId).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Divider()

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                            GridRow {
                                Text("Minimum iOS")
                                TextField(model.ipa?.minimumOsVersion ?? "Unchanged", text: $model.minimumOSVersion)
                                    .frame(maxWidth: 180)
                            }
                        }

                        Toggle("Remove supported-device model restriction", isOn: $model.removeSupportedDevices)
                        Toggle("Enable Files and Finder document sharing", isOn: $model.enableFileSharing)
                        Toggle("Request increased memory entitlement", isOn: $model.increasedMemoryLimit)

                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Info.plist overrides").fontWeight(.semibold)
                                Text("Add typed top-level keys. Export first when testing unfamiliar changes.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                model.addPlistOverride()
                            } label: {
                                Label("Add Key", systemImage: "plus")
                            }
                        }

                        ForEach($model.plistOverrides) { $item in
                            HStack(spacing: 10) {
                                TextField("Key", text: $item.key)
                                    .font(.body.monospaced())
                                Picker("Type", selection: $item.valueType) {
                                    ForEach(["String", "Boolean", "Integer", "Real"], id: \.self) {
                                        Text($0).tag($0)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 110)
                                TextField(item.valueType == "Boolean" ? "true or false" : "Value", text: $item.value)
                                Button(role: .destructive) {
                                    model.removePlistOverride(item.id)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.top, 12)
                } label: {
                    Label("Advanced IPA options", systemImage: "wrench.and.screwdriver")
                        .fontWeight(.semibold)
                }
            }
            .padding(10)
        } label: {
            Label("3 · Customize", systemImage: "slider.horizontal.3")
        }
    }

    private var installSection: some View {
        GroupBox {
            VStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.selectedAccount.isEmpty ? "No Apple Account selected" : model.selectedAccount)
                            .fontWeight(.semibold)
                        Text(model.isInstalling ? model.currentStage : "Credentials are retrieved from macOS Keychain only when installation starts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isInstalling {
                        Button("Cancel", role: .destructive) { model.cancelInstall() }
                    } else {
                        Button {
                            exportIPA()
                        } label: {
                            if model.isExporting {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Export IPA…", systemImage: "square.and.arrow.up")
                            }
                        }
                        .disabled(model.ipa == nil || model.isExporting)
                        Button("Sign & Install") { model.install() }
                            .slipProminentButton()
                            .controlSize(.large)
                            .disabled(model.ipa == nil || model.selectedDevice == nil || model.selectedAccount.isEmpty)
                    }
                }
                if model.isInstalling {
                    ProgressView(value: model.overallProgress)
                        .animation(.smooth, value: model.overallProgress)
                }
                Toggle(isOn: $model.keepAutomaticallyRefreshed) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep refreshed automatically")
                        Text("After a successful install, renew on day 6 whenever this Mac can reach your iPhone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(model.isInstalling)
            }
            .padding(10)
        } label: {
            Label(model.ipa == nil ? "3 · Sign and install" : "4 · Sign and install", systemImage: "checkmark.shield")
        }
    }

    private func exportIPA() {
        guard let ipa = model.ipa else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ipaType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(ipa.appName)-Slip.ipa"
        panel.title = "Export Modified IPA"
        panel.prompt = "Export"
        if panel.runModal() == .OK, let url = panel.url {
            model.exportModifiedIPA(to: url)
        }
    }
}
