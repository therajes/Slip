import AppKit
import CryptoKit
import SwiftUI
import UserNotifications

struct AssuranceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var checks: [String] = []
    @State private var checking = false
    @State private var report: String?
    @State private var notificationTarget: String?
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let notificationTarget { Text("Renewal issue: \(notificationTarget)").font(.headline) }
                Text("A readiness pass does not mean a renewal ran. Slip needs an available Mac, an approved IPA, usable credentials and the intended reachable iPhone.").font(.caption).foregroundStyle(.secondary)
                Button("Check Background Readiness") { Task { await inspect() } }.disabled(checking || model.workspaceIsBusy)
                if checking { ProgressView().controlSize(.small) }
                ForEach(Array(checks.enumerated()), id: \.offset) { _, row in Text(row).font(.caption).textSelection(.enabled) }
                ForEach(model.managedInstallations) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.appName).font(.headline)
                            Text(RenewalEngine.status(for: item).rawValue).font(.caption)
                            if let date = item.lastVerifiedAt { Text("Last verified: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                            if let date = item.nextEligibleAt { Text("Next eligible check: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                        }
                        Spacer()
                        Button("Review Saved Source…") { approve(item) }.disabled(model.workspaceIsBusy)
                    }
                }
                DisclosureGroup("Private renewal history") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(RenewalHistory.load().suffix(20).reversed())) { entry in
                            Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.status.rawValue) · \(entry.reasonCode)").font(.caption)
                        }
                        Button("Preview sanitized renewal report") { report = Self.sanitized(RenewalHistory.load()) }
                        if let report {
                            Text("Privacy review: identifiers, paths and free-form context are excluded. Review before saving.").font(.caption)
                            Text(report).font(.caption.monospaced()).textSelection(.enabled)
                            Button("Save reviewed report…") {
                                let panel = NSSavePanel(); panel.nameFieldStringValue = "Slip-renewal-report.txt"
                                if panel.runModal() == .OK, let url = panel.url { try? Data(report.utf8).write(to: url, options: .atomic) }
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("Renewal Assurance", systemImage: "checkmark.shield") }
        .onAppear {
            let scope = UserDefaults.standard.string(forKey: "notificationPendingInstallation")
            notificationTarget = model.managedInstallations.first { NotificationCoordinator.deliveryScope(installationID: $0.id, reason: nil) == scope }?.appName
            UserDefaults.standard.removeObject(forKey: "notificationPendingInstallation")
        }
    }
    private func approve(_ item: ManagedInstallation) {
        let alert = NSAlert(); alert.messageText = String(localized: "Approve this renewal source?")
        alert.informativeText = "\(item.appName)\n\(item.ipaPath)\n\nSlip will retain this IPA's hash and reviewed signing options. Future source, icon or option changes require review. Apple limits still apply."
        alert.addButton(withTitle: String(localized: "Cancel")); alert.addButton(withTitle: String(localized: "Approve Saved Source"))
        if alert.runModal() == .alertSecondButtonReturn { Task { await model.approveRenewalSource(item.id); model.reloadManagedInstallations() } }
    }
    private func inspect() async {
        checking = true; defer { checking = false }
        let target = "gui/\(getuid())/\(AutoRefreshScheduler.label)"
        let registered = await Task.detached { () -> Bool in
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = ["print", target]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 } catch { return false }
        }.value
        var rows = [registered ? "LaunchAgent registration: present in this GUI session." : "LaunchAgent registration: unavailable; enable background refresh from the installed app."]
        rows.append(OperationCoordinator.isOperationInProgress() ? "Operation lease: busy; renewal must wait." : "Operation lease: currently free, subject to another operation starting.")
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        rows.append(settings.authorizationStatus == .authorized ? "Notifications: authorized; macOS settings and quiet hours control presentation." : "Notifications: unavailable; renewal does not require banners.")
        for item in model.managedInstallations {
            let path = item.ipaPath
            let hash = try? await Task.detached { try DeploymentJob.sourceHash(path) }.value
            rows.append("\(item.appName): " + (hash == nil ? "saved IPA missing or unreadable." : hash == item.approvedSourceSHA256 ? "source hash matches approval." : "source needs explicit review."))
            rows.append("\(item.appName): " + ((try? KeychainStore.backgroundPassword(for: item.account)) != nil ? "Keychain data is accessible without UI; Apple authentication remains unverified until attempted." : "saved credential requires foreground attention."))
            rows.append("\(item.appName): " + (model.devices.contains { $0.udid == item.deviceUDID } ? "exact device discovered; core verifies its authenticated pathway before transfer." : "intended iPhone not discovered."))
        }
        rows.append("Sleep/network: this Mac must be awake with internet access. Network and discovery hints do not prove device trust.")
        checks = rows
    }
    static func sanitized(_ entries: [RenewalHistoryEntry]) -> String {
        let allowed: Set<String> = ["policy.paused","install.verification_pending","refresh.source_review_required","schedule.not_due","operation.busy","network.unavailable","device.disconnected","authentication.interaction_required","power.prefers_ac","schedule.eligible","install.verified","network.timeout","operation.cancelled"]
        return (["Slip renewal report v1", "Private identifiers and free-form context excluded."] + entries.map { "\($0.status.rawValue) | \(allowed.contains($0.reasonCode) ? $0.reasonCode : "operation.unknown")" }).joined(separator: "\n")
    }
}
