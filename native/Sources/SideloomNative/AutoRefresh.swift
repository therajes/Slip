import AppKit
import Foundation

struct ManagedInstallation: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var appName: String
    var bundleId: String
    var account: String
    var deviceUDID: String
    var deviceName: String
    var options: IpaInstallOptions
    var installedAt: Date
    var profileExpiryConfirmed: Bool? = nil
    var expiryIsEstimated: Bool { profileExpiryConfirmed != true }
    var expiresAt: Date
    var nextRefreshAt: Date
    var lastAttemptAt: Date?
    var enabled: Bool
    var status: String
    var lastError: String?

    var approvedSourceSHA256: String? = nil
    var reviewedOptionsSHA256: String? = nil
    var approvedIconSHA256: String? = nil
    var lastVerifiedAt: Date? = nil
    var lastReachableAt: Date? = nil
    var retryCount: Int? = nil
    var reasonCode: String? = nil
    var nextEligibleAt: Date? = nil
    var pendingOperationID: String? = nil
    var actionRequired: Bool? = nil
    var teamReference: String? = nil

    var ipaPath: String { options.appPath }

    func isDueForBackgroundRefresh(at now: Date) -> Bool {
        enabled && actionRequired != true && pendingOperationID == nil && status != "Needs attention" && (nextEligibleAt ?? nextRefreshAt) <= now
    }
}

@MainActor
enum AutoRefreshStore {
    private static let fileName = "managed-installations.json"

    static var fileURL: URL {
        let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return (base ?? FileManager.default.homeDirectoryForCurrentUser)
            .appending(path: "app.sideloom.native", directoryHint: .isDirectory)
            .appending(path: fileName)
    }

    static func load() -> [ManagedInstallation] {
        (try? loadChecked()) ?? []
    }

    static func loadChecked() throws -> [ManagedInstallation] {
        try ManagedInstallationsRepository(fileURL: fileURL).load()
    }

    @discardableResult
    static func update<T>(_ body: (inout [ManagedInstallation]) throws -> T) throws -> T {
        try ManagedInstallationsRepository(fileURL: fileURL).update(body)
    }

    static func mergeOutcome(_ updated: ManagedInstallation, original: ManagedInstallation) throws {
        try ManagedInstallationsRepository(fileURL: fileURL).mergeOutcome(updated, original: original)
    }

    static func remove(bundleIDs: Set<String>, deviceUDID: String) throws -> Int {
        try ManagedInstallationsRepository(fileURL: fileURL).remove(bundleIDs: bundleIDs, deviceUDID: deviceUDID)
    }

    static func recordSuccessfulInstall(
        ipa: IpaInfo,
        request: InstallRequest,
        enabled: Bool,
        profileExpiresAt: Double? = nil
    ) throws -> ManagedInstallation {
        let now = Date()
        let effectiveBundleID = request.options.bundleId ?? ipa.bundleId
        let key = "\(request.device.udid)|\(effectiveBundleID)"
        return try update { installations in
        let existingID = installations.first(where: {
            $0.deviceUDID == request.device.udid && $0.bundleId == effectiveBundleID
        })?.id
        var entry = ManagedInstallation(
            id: existingID ?? key,
            appName: request.options.displayName ?? ipa.appName,
            bundleId: effectiveBundleID,
            account: request.email,
            deviceUDID: request.device.udid,
            deviceName: request.device.name,
            options: request.options,
            installedAt: now,
            profileExpiryConfirmed: profileExpiresAt != nil,
            expiresAt: profileExpiresAt.map { Date(timeIntervalSince1970: $0) } ?? now.addingTimeInterval(7 * 24 * 60 * 60),
            nextRefreshAt: profileExpiresAt.map { Date(timeIntervalSince1970: $0).addingTimeInterval(-24 * 60 * 60) } ?? now.addingTimeInterval(6 * 24 * 60 * 60),
            lastAttemptAt: now,
            enabled: enabled,
            status: enabled ? "Scheduled" : "Paused",
            lastError: nil
        )
        entry.lastVerifiedAt = now
        entry.lastReachableAt = now
        entry.retryCount = 0
        entry.reasonCode = "install.verified"
        entry.actionRequired = false
        if let previous = installations.first(where: { $0.id == entry.id && $0.options == request.options && $0.account == request.email }) {
            entry.approvedSourceSHA256 = previous.approvedSourceSHA256
            entry.reviewedOptionsSHA256 = previous.reviewedOptionsSHA256
            entry.approvedIconSHA256 = previous.approvedIconSHA256
            entry.teamReference = previous.teamReference
        }
        installations.removeAll {
            $0.deviceUDID == request.device.udid && $0.bundleId == effectiveBundleID
        }
        installations.append(entry)
        return entry
        }
    }
}

@MainActor
enum AutoRefreshScheduler {
    static let label = "app.sideloom.native.refresh"
    static let intervalSeconds = 15 * 60

    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
            .appending(path: "\(label).plist")
    }

    private(set) static var isInstalled = false

    static func installIfAppropriate() throws {
        guard let executableURL = Bundle.main.executableURL,
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }

        let directory = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.path, "--refresh-due"],
            "RunAtLoad": true,
            "StartInterval": intervalSeconds,
            "ProcessType": "Background",
            "LowPriorityIO": false
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        let previous = try? Data(contentsOf: launchAgentURL)
        var setupLease: OperationCoordinator.OperationHandle?
        if previous != data {
            // Hold the same lease as renewal, so reloading the agent cannot
            // interrupt a worker that has already started signing or transfer.
            setupLease = OperationCoordinator.beginOperation(type: .refresh, appName: "Updating renewal schedule")
            guard setupLease != nil else { return }
            try data.write(to: launchAgentURL, options: [.atomic])
            if previous != nil {
                let unload = Process()
                unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                unload.arguments = ["bootout", "gui/\(getuid())/\(label)"]
                unload.standardOutput = FileHandle.nullDevice
                unload.standardError = FileHandle.nullDevice
                try unload.run()
                unload.waitUntilExit()
            }
        }
        defer { setupLease?.end() }

        let target = "gui/\(getuid())"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", target, launchAgentURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        // bootstrap also returns nonzero for an already-loaded agent; verify
        // registration instead of claiming readiness from a plist's existence.
        let verification = Process()
        verification.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        verification.arguments = ["print", "\(target)/\(label)"]
        verification.standardOutput = FileHandle.nullDevice
        verification.standardError = FileHandle.nullDevice
        try verification.run()
        verification.waitUntilExit()
        isInstalled = verification.terminationStatus == 0
        guard isInstalled else { throw SideloomError.message("Background renewal could not start. Reopen Slip from Applications to try again.") }
    }
}

@MainActor
enum AutoRefreshWorker {
    struct Result {
        let attempted: Int
        let succeeded: Int
        let attentionNeeded: Int
    }

    static func runDue(forceIDs: Set<String> = [], networkAvailable: Bool = true, onBattery: Bool = false) async -> Result {
        let preferences = UserDefaults.standard
        let snapshot = AutoRefreshStore.load()
        let enabled = preferences.object(forKey: "backgroundRefreshEnabled") as? Bool ?? snapshot.contains(where: \.enabled)
        guard enabled, !preferences.bool(forKey: "backgroundRefreshPaused") else { return .init(attempted: 0, succeeded: 0, attentionNeeded: 0) }
        let now = Date()
        for item in snapshot where item.enabled && item.expiresAt.timeIntervalSince(now) < 24 * 3600 {
            await NotificationCoordinator.shared.deliver(.appExpiring, installationID: item.id, reason: item.reasonCode ?? "expiry.approaching")
        }
        let due = snapshot.filter { forceIDs.contains($0.id) || $0.isDueForBackgroundRefresh(at: now) }.sorted { $0.expiresAt < $1.expiresAt }
        guard !due.isEmpty else { return .init(attempted: 0, succeeded: 0, attentionNeeded: 0) }
        let devices = (try? await CoreClient().run(["devices"]))?.devices ?? []
        var attempted = 0, succeeded = 0, attention = 0
        for candidate in due {
            guard let handle = OperationCoordinator.beginOperation(type: .refresh, appName: candidate.appName, bundleId: candidate.bundleId) else { continue }
            defer { handle.end() }
            guard var item = AutoRefreshStore.load().first(where: { $0.id == candidate.id }),
                  item.options == candidate.options, item.lastAttemptAt == candidate.lastAttemptAt,
                  forceIDs.contains(item.id) || item.isDueForBackgroundRefresh(at: Date()) else { continue }
            let original = item
            let path = item.ipaPath
            let digest = try? await Task.detached { try DeploymentJob.sourceHash(path) }.value
            let optionsDigest = try? DeploymentJob.optionsHash(item.options)
            let iconPath = item.options.customIconPath
            let iconDigest = try? await Task.detached { try iconPath.map(DeploymentJob.sourceHash) }.value
            let matches = digest != nil && digest == item.approvedSourceSHA256 && optionsDigest == item.reviewedOptionsSHA256 &&
                (iconPath == nil || (iconDigest != nil && iconDigest == item.approvedIconSHA256))
            let device = preferredDevice(for: item, among: devices)
            let password = item.pendingOperationID == nil && matches && device != nil ? (try? KeychainStore.backgroundPassword(for: item.account)) : nil
            let decision = RenewalEngine.evaluate(item, context: .init(now: Date(), networkAvailable: networkAvailable,
                matchingDeviceReachable: device != nil, accountUsable: password != nil, sourceMatches: matches,
                onBattery: onBattery, force: forceIDs.contains(item.id)))
            guard decision.eligible, let device, let password else {
                item.status = decision.status.rawValue; item.reasonCode = decision.reason; item.lastError = decision.nextAction
                if decision.status == .reviewRequired || decision.status == .requiresAuthentication { item.actionRequired = true; attention += 1 }
                if decision.status == .waitingForDevice || decision.status == .waitingForNetwork { item.nextEligibleAt = Date().addingTimeInterval(15 * 60) }
                try? AutoRefreshStore.mergeOutcome(item, original: original)
                RenewalHistory.record(item, status: decision.status, reason: decision.reason)
                if item.actionRequired == true {
                    await NotificationCoordinator.shared.deliver(.refreshFailed, installationID: item.id, reason: decision.reason)
                }
                continue
            }
            let request = InstallRequest(email: item.account, password: password,
                anisetteServer: preferences.string(forKey: "anisetteServer") ?? "", storagePath: coreStorageURL(for: item.account).path,
                device: device, options: item.options, authenticationMode: preferences.string(forKey: "authenticationMode") ?? "local")
            item.lastAttemptAt = Date(); item.status = "Renewing"; item.reasonCode = "operation.in_progress"
            item.lastError = nil; item.pendingOperationID = UUID().uuidString
            do { try AutoRefreshStore.mergeOutcome(item, original: original) }
            catch { attention += 1; continue } // Never start without a durable pending checkpoint.
            attempted += 1
            do {
                let outcome = try await performInstall(request) { operationID in
                    item.pendingOperationID = operationID
                    try AutoRefreshStore.mergeOutcome(item, original: original)
                }
                switch outcome {
                case .installed, .installedWithExpiry:
                    let verified = Date()
                    let expiry: Date? = { if case .installedWithExpiry(let date) = outcome { return date }; return nil }()
                    item.installedAt = verified; item.lastVerifiedAt = verified; item.lastReachableAt = verified
                    item.profileExpiryConfirmed = expiry != nil; item.expiresAt = expiry ?? verified.addingTimeInterval(7 * 86400)
                    item.nextRefreshAt = item.expiresAt.addingTimeInterval(-86400); item.nextEligibleAt = nil
                    item.status = "Scheduled"; item.reasonCode = "install.verified"; item.lastError = nil
                    item.pendingOperationID = nil; item.retryCount = 0; item.actionRequired = false
                    succeeded += 1
                case .verificationPending(let message):
                    item.status = RenewalStatus.verificationPending.rawValue; item.reasonCode = "install.verification_pending"
                    item.lastError = message; item.actionRequired = true; attention += 1
                case .attention(let message):
                    item.pendingOperationID = nil
                    markAttention(&item, message); attention += 1
                case .failed(let message):
                    item.pendingOperationID = nil
                    markRetry(&item, message)
                }
            } catch {
                // Stream termination after transfer is converted to pending by performInstall.
                item.pendingOperationID = nil
                markRetry(&item, "The renewal connection ended before transfer. Slip will retry with backoff.")
            }
            do { try AutoRefreshStore.mergeOutcome(item, original: original) }
            catch {
                attention += 1
                if item.reasonCode == "install.verified" { succeeded -= 1 }
                RenewalHistory.record(item, status: .verificationPending, reason: "storage.write_failed")
                continue // Durable pending checkpoint remains until metadata can be committed.
            }
            RenewalHistory.record(item, status: RenewalEngine.status(for: item), reason: item.reasonCode ?? "operation.unknown")
            if item.reasonCode == "install.verified" {
                await NotificationCoordinator.shared.deliver(.refreshSuccess, installationID: item.id, reason: "install.verified")
            } else if item.actionRequired == true {
                await NotificationCoordinator.shared.deliver(.refreshFailed, installationID: item.id, reason: item.reasonCode ?? "operation.interaction_required")
            }
        }
        return .init(attempted: attempted, succeeded: succeeded, attentionNeeded: attention)
    }

    enum InstallOutcome: Equatable {
        case installed
        case installedWithExpiry(Date)
        case attention(String)
        case verificationPending(String)
        case failed(String)
    }

    static func performInstall(_ request: InstallRequest, core: CoreClient = CoreClient(), operationStarted: ((String) throws -> Void)? = nil) async throws -> InstallOutcome {
        let stream = try core.installStream(request: request)
        var outcome: InstallOutcome = .failed("Installation ended before completion. Slip will retry.")
        var mayHaveTransferred = false
        do {
        for try await event in stream {
            if event.type == "progress", ["transfer", "verify"].contains(event.stage ?? "") { mayHaveTransferred = true }
            switch event.type {
            case "operationStarted":
                if let id = event.operationId {
                    do {
                        try operationStarted?(id)
                        try await PendingOutcomeStore.shared.save(.init(operationId: id, storagePath: request.storagePath,
                            device: request.device, options: request.options, account: request.email, renewalEnabled: true))
                    } catch {
                        core.cancel()
                        return .attention("Recovery information could not be saved. Open Slip before retrying.")
                    }
                }
            case "completed":
                guard event.confirmsInstallation else {
                    outcome = .verificationPending("Device verification is pending. Open Slip to verify before refreshing again.")
                    continue
                }
                outcome = event.profileExpiresAt.map { .installedWithExpiry(Date(timeIntervalSince1970: $0)) } ?? .installed
            case "provisioningReviewRequired":
                try? core.submitCapabilityAcknowledgement(true)
            case "verificationPending":
                mayHaveTransferred = true
                outcome = .verificationPending("Installation may have completed. Open Slip to verify this iPhone before retrying.")
            case "twoFactorRequired":
                try? core.submitTwoFactor(nil)
                outcome = .attention("Apple requested a verification code. Open Slip and refresh this app manually.")
            case "certificateSelectionRequired":
                try? core.submitCertificates(nil)
                outcome = .attention("Apple requires a certificate decision. Open Slip and refresh this app manually.")
            case "error":
                if case .attention = outcome { break }
                if case .verificationPending = outcome { break }
                if mayHaveTransferred { outcome = .verificationPending("Transfer may have completed. Open Slip to verify before retrying.") }
                else if event.diagnostic?.retryable == false { outcome = .attention(event.message ?? "Open Slip to resolve the signing issue.") }
                else { outcome = .failed(event.message ?? "Installation failed. Slip will retry.") }
            default:
                break
            }
        }
        } catch {
            if mayHaveTransferred { return .verificationPending("The transfer acknowledgement was interrupted. Verify the iPhone before retrying.") }
            if case .attention = outcome { return outcome }
            throw error
        }
        return outcome
    }

    private static func preferredDevice(
        for item: ManagedInstallation,
        among devices: [DeviceInfo]
    ) -> DeviceInfo? {
        devices
            .filter { $0.udid == item.deviceUDID }
            .sorted { left, right in
                let leftNetwork = left.connectionType.caseInsensitiveCompare("Network") == .orderedSame
                let rightNetwork = right.connectionType.caseInsensitiveCompare("Network") == .orderedSame
                return leftNetwork && !rightNetwork
            }
            .first
    }

    private static func coreStorageURL(for account: String) -> URL {
        let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let safe = account.lowercased()
            .replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
        return (base ?? FileManager.default.homeDirectoryForCurrentUser)
            .appending(path: "app.sideloom.native/Core", directoryHint: .isDirectory)
            .appending(path: safe, directoryHint: .isDirectory)
    }

    private static func markRetry(_ item: inout ManagedInstallation, _ message: String) {
        item.status = RenewalStatus.backingOff.rawValue
        item.lastError = message
        item.reasonCode = "network.timeout"
        item.retryCount = (item.retryCount ?? 0) + 1
        item.nextEligibleAt = RenewalEngine.retryDate(now: Date(), attempt: item.retryCount ?? 1, jitter: Double.random(in: 0...1))
    }

    private static func markAttention(_ item: inout ManagedInstallation, _ message: String) {
        item.status = "Needs attention"
        item.lastError = message
        item.reasonCode = "authentication.interaction_required"
        item.actionRequired = true
        // A user-action failure is excluded from unattended retries. Refresh now
        // or re-enabling the schedule can resume it after the user fixes the issue.
        item.nextRefreshAt = Date().addingTimeInterval(2 * 60 * 60)
    }

    private static func postNotification(title: String, message: String) {
        guard UserDefaults.standard.bool(forKey: "renewalNotificationsEnabled") else { return }
        Task { await NotificationCoordinator.shared.deliver(title == "Slip needs attention" ? .refreshFailed : .refreshSuccess) }
    }
}
