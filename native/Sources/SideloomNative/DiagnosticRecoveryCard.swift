import SwiftUI

struct DiagnosticRecoveryCard: View {
    let diagnostic: SlipDiagnostic
    @EnvironmentObject private var model: AppModel
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(diagnostic.title).font(.headline)
                Text(diagnostic.code == .verificationPending ? "The app may already be installed. Verify the selected iPhone before attempting another installation." : "Your saved workspace is preserved. Review this action before continuing.").font(.caption)
                Button(diagnostic.recovery.title) {
                    switch diagnostic.recovery {
                    case .retryDiscovery, .connectUSB: Task { await model.refreshDevices() }
                    case .verifyInstallation: Task { await model.verifyPendingInstallation() }
                    case .openAccounts, .refreshResources: NotificationCenter.default.post(name: .showAccounts, object: nil)
                    case .locateIPA, .reviewEntitlements, .retrySafely: NotificationCenter.default.post(name: .showInstall, object: nil)
                    case .detailedDiagnostics: break
                    }
                }.disabled(model.workspaceIsBusy)
                DisclosureGroup("Details") {
                    Text("\(diagnostic.code.rawValue) · \(diagnostic.severity.rawValue)").font(.caption.monospaced()).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("Recovery", systemImage: "stethoscope") }
    }
}

struct DeviceHealthPanel: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if let device = model.selectedDevice {
                    Text("\(device.displayName) · iOS \(device.version) · \(device.connectionType)")
                    Text("Device reference: \(DeviceHealthEvidence.maskedIdentity(device.udid)) · scoped to this iPhone").font(.caption.monospaced())
                    if let evidence = model.deviceHealth[device.udid] {
                        if let seen = evidence.lastSeen { Text("Last seen: \(seen.formatted())").font(.caption) }
                        if let check = evidence.lastCheck { Text("Last discovery check: \(check.formatted())").font(.caption) }
                        if let change = evidence.recentConnectionChange { Text(change).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("Discovery confirms reachability only. Pairing, trust and Developer Mode: Unknown until an operation verifies them.")
                } else { Text("No selected iPhone. Connection, pairing and trust: Unknown.") }
                Button("Retest Connection") { Task { await model.refreshDevices() } }.disabled(model.workspaceIsBusy)
                Text("Developer Mode: Settings → Privacy & Security → Developer Mode on the iPhone. This is physical device health; Apple Account status is shown separately in Accounts.").font(.caption).foregroundStyle(.secondary)
                Text("For pairing trouble, unlock the iPhone, connect USB and review Trust This Computer. Slip does not reset pairing records.").font(.caption).foregroundStyle(.secondary)
            }.font(.callout).padding(.vertical, 8)
        } label: { Label("Device Health & Diagnostics", systemImage: "iphone.gen3.radiowaves.left.and.right") }
    }
}
