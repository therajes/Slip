import AppKit
import SwiftUI

private enum SidebarSection: String, CaseIterable, Identifiable {
    case install = "Install"
    case autoRefresh = "Auto Refresh"
    case deviceApps = "iPhone Apps"
    case accounts = "Apple Accounts"
    case activity = "Activity"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .install: "square.and.arrow.down"
        case .autoRefresh: "arrow.clockwise.circle"
        case .deviceApps: "square.grid.2x2"
        case .accounts: "person.badge.key"
        case .activity: "waveform.path.ecg"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var section: SidebarSection? = .install
    @State private var twoFactorCode = ""
    @State private var selectedCertificates: Set<String> = []

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Image(systemName: model.devices.isEmpty ? "iphone.slash" : "iphone")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.selectedDevice?.name ?? "No iPhone")
                            .font(.caption.weight(.semibold))
                        Text(model.selectedDevice?.connectionType ?? "Connect with USB")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(.ultraThinMaterial)
            }
        } detail: {
            switch section ?? .install {
            case .install: InstallView()
            case .autoRefresh: AutoRefreshView()
            case .deviceApps: DeviceAppsView()
            case .accounts: AccountsView()
            case .activity: ActivityView()
            }
        }
        .groupBoxStyle(SlipGlassGroupBoxStyle())
        .slipGlassControls()
        .onOpenURL { url in
            if url.pathExtension.lowercased() == "ipa" && url.isFileURL {
                Task { await model.loadIPA(url) }
                return
            }
            if url.scheme?.lowercased() == "slip",
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let remote = components.queryItems?.first(where: { $0.name == "url" })?.value {
                Task { await model.downloadIPA(from: remote) }
            }
        }
        .alert("Slip", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .sheet(isPresented: $model.showTwoFactor) {
            VStack(alignment: .leading, spacing: 18) {
                Label("Apple verification", systemImage: "checkmark.shield")
                    .font(.title2.bold())
                Text("Enter the six-digit verification code sent by Apple.")
                    .foregroundStyle(.secondary)
                TextField("000000", text: $twoFactorCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2.monospacedDigit())
                    .frame(width: 180)
                HStack {
                    Button("Cancel", role: .cancel) { model.submitTwoFactor(nil) }
                    Spacer()
                    Button("Continue") {
                        model.submitTwoFactor(twoFactorCode)
                        twoFactorCode = ""
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(twoFactorCode.count != 6)
                }
            }
            .padding(28)
            .frame(width: 420)
        }
        .sheet(isPresented: $model.showCertificates) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Free a development certificate")
                    .font(.title2.bold())
                Text("Apple has reached its certificate limit. Select certificates Slip may revoke.")
                    .foregroundStyle(.secondary)
                List(model.certificates, selection: $selectedCertificates) { certificate in
                    VStack(alignment: .leading) {
                        Text(certificate.name ?? "Development certificate")
                        Text(certificate.machineName ?? certificate.serialNumber ?? "Unknown")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(certificate.serialNumber ?? "")
                }
                .frame(height: 220)
                HStack {
                    Button("Cancel", role: .cancel) { model.submitCertificates(nil) }
                    Spacer()
                    Button("Revoke Selected") {
                        model.submitCertificates(Array(selectedCertificates))
                        selectedCertificates.removeAll()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedCertificates.isEmpty)
                }
            }
            .padding(28)
            .frame(width: 520)
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(eyebrow: "DIAGNOSTICS", title: "Activity", subtitle: "Readable events from the native signing and device engine.")
            HStack {
                Toggle("Hide sensitive information", isOn: $model.hideSensitiveInfo)
                    .toggleStyle(.switch)
                Spacer()
                Button {
                    let text = model.visibleActivity.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy Log", systemImage: "doc.on.doc")
                }
                .disabled(model.visibleActivity.isEmpty)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            List(model.visibleActivity, id: \.self) { entry in
                Label(entry, systemImage: "circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.callout)
            }
        }
        .background(SlipBackdrop())
    }
}

struct PageHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow).font(.caption.weight(.bold)).foregroundStyle(.tint)
            Text(title).font(.largeTitle.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .slipGlassSurface(tint: Color.accentColor.opacity(0.08), cornerRadius: 24)
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }
}
