import Foundation

struct PendingInstallOutcome: Codable, Sendable {
    var operationId: String
    var storagePath: String
    var device: DeviceInfo
    var ipa: IpaInfo? = nil
    var options: IpaInstallOptions? = nil
    var account: String? = nil
    var renewalEnabled: Bool? = nil
}
actor PendingOutcomeStore {
    static let shared = PendingOutcomeStore()
    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "app.sideloom.native/Operations/pending-v1.json")
    private func records() throws -> [PendingInstallOutcome] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count < 4 * 1024 * 1024 else { throw SideloomError.message("Pending installation record is too large.") }
        let decoder = JSONDecoder()
        if let records = try? decoder.decode([PendingInstallOutcome].self, from: data) { return records }
        return [try decoder.decode(PendingInstallOutcome.self, from: data)]
    }
    func load() throws -> PendingInstallOutcome? { try records().first }
    private func write(_ values: [PendingInstallOutcome]) throws {
        let data = try JSONEncoder().encode(values)
        guard data.count < 4 * 1024 * 1024 else { throw SideloomError.message("Installation recovery storage is full. Verify pending installations first.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func save(_ value: PendingInstallOutcome) throws {
        var values = try records()
        values.removeAll { $0.operationId == value.operationId }
        values.append(value)
        try write(values)
    }
    func clear(operationId: String) throws {
        try write(records().filter { $0.operationId != operationId })
    }

}
extension AppModel {
    func verifyPendingInstallation() async {
        guard !workspaceIsBusy else { return }
        guard let record = try? await PendingOutcomeStore.shared.load() else { return }
        guard let lease = OperationCoordinator.beginOperation(type: .install, appName: "Verifying previous installation") else { return }
        isInspecting = true
        defer { isInspecting = false; lease.end() }
        do {
            let event = try await CoreClient().run(["reconcile-install"], input: record)
            if event.confirmsInstallation, event.operationId == record.operationId {
                if let ipa = record.ipa, let options = record.options, let account = record.account {
                    // Reconciliation never authenticates or installs. The empty
                    // credentials are used only to reconstruct local metadata.
                    let request = InstallRequest(email: account, password: "", anisetteServer: "", storagePath: record.storagePath,
                        device: record.device, options: options)
                    try AutoRefreshStore.recordSuccessfulInstall(ipa: ipa, request: request,
                        enabled: record.renewalEnabled ?? false, profileExpiresAt: event.profileExpiresAt)
                    reloadManagedInstallations()
                } else if let options = record.options, let account = record.account,
                          let original = AutoRefreshStore.load().first(where: {
                              $0.account == account && $0.deviceUDID == record.device.udid && $0.options == options
                          }) {
                    var updated = original
                    let now = Date()
                    updated.installedAt = now
                    updated.lastAttemptAt = now
                    updated.profileExpiryConfirmed = event.profileExpiresAt != nil
                    updated.expiresAt = event.profileExpiresAt.map { Date(timeIntervalSince1970: $0) } ?? now.addingTimeInterval(7 * 86400)
                    updated.nextRefreshAt = updated.expiresAt.addingTimeInterval(-86400)
                    updated.status = original.enabled ? "Scheduled" : "Paused"
                    updated.lastError = nil
                    try AutoRefreshStore.mergeOutcome(updated, original: original)
                    reloadManagedInstallations()
                }
                if let ipa = record.ipa, let options = record.options, let store = libraryManagementStore {
                    for saved in library.apps where saved.deviceUDID == record.device.udid
                        && saved.ipa.path == options.appPath
                        && (saved.options.bundleId ?? saved.ipa.bundleId) == (options.bundleId ?? ipa.bundleId) {
                        try await store.record(workspaceID: saved.id, ipa: ipa, installed: true)
                    }
                }
                currentStage = "Previous installation verified"
                appendActivity("The intended iPhone confirms the previous app installation. Review its renewal recipe before another install.")
                try await PendingOutcomeStore.shared.clear(operationId: record.operationId)
                diagnostic = nil
            } else {
                try await PendingOutcomeStore.shared.save(record)
                diagnostic = SlipDiagnostic(code: .verificationPending, phase: "verify", severity: .warning, retryable: true, recovery: .verifyInstallation)
                currentStage = "Verification pending"
            }
        } catch {
            try? await PendingOutcomeStore.shared.save(record)
            diagnostic = SlipDiagnostic(code: .verificationPending, phase: "verify", severity: .warning, retryable: true, recovery: .verifyInstallation)
            currentStage = "Verification pending"
        }
    }
}
