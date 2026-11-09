import AppKit
import Foundation

struct ManagedInstallation: Codable, Hashable, Identifiable {
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

    var ipaPath: String { options.appPath }

    func isDueForBackgroundRefresh(at now: Date) -> Bool {
        enabled && status != "Needs attention" && nextRefreshAt <= now
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
        let entry = ManagedInstallation(
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

    static func runDue(forceIDs: Set<String> = []) async -> Result {
        var installations = AutoRefreshStore.load()
        let now = Date()
        let dueIndexes = installations.indices.filter { index in
            let item = installations[index]
            return forceIDs.contains(item.id) || item.isDueForBackgroundRefresh(at: now)
        }
        guard !dueIndexes.isEmpty else {
            return Result(attempted: 0, succeeded: 0, attentionNeeded: 0)
        }

        if dueIndexes.contains(where: { installations[$0].expiresAt.timeIntervalSince(now) < 24 * 3600 }) {
            Task { await NotificationCoordinator.shared.deliver(.appExpiring) }
        }
        let discovery = try? await CoreClient().run(["devices"])
        let devices = discovery?.devices ?? []
        var succeeded = 0
        var attentionNeeded = 0
        var attempted = 0

        for index in dueIndexes {
            guard let latest = AutoRefreshStore.load().first(where: { $0.id == installations[index].id }),
                  forceIDs.contains(latest.id) || latest.isDueForBackgroundRefresh(at: now),
                  latest.options == installations[index].options else { continue }
            let item = latest
            installations[index] = latest
            guard let opHandle = OperationCoordinator.beginOperation(
                type: .refresh, appName: item.appName, bundleId: item.bundleId
            ) else { continue }
            attempted += 1
            defer {
                try? AutoRefreshStore.mergeOutcome(installations[index], original: item)
                opHandle.end()
            }

            installations[index].lastAttemptAt = Date()
            installations[index].status = "Refreshing"
            installations[index].lastError = nil
            try? AutoRefreshStore.mergeOutcome(installations[index], original: item)

            guard FileManager.default.fileExists(atPath: item.ipaPath) else {
                markAttention(
                    &installations[index],
                    "The saved IPA is missing. Restore it and use Refresh now, or choose a replacement IPA in Slip."
                )
                attentionNeeded += 1
                continue
            }
            guard let device = preferredDevice(for: item, among: devices) else {
                markRetry(
                    &installations[index],
                    "iPhone is not reachable. Slip will retry over Wi‑Fi or USB."
                )
                continue
            }

            do {
                let password = try KeychainStore.password(for: item.account)
                let request = InstallRequest(
                    email: item.account,
                    password: password,
                    anisetteServer: UserDefaults.standard.string(forKey: "anisetteServer") ?? "",
                    storagePath: coreStorageURL(for: item.account).path,
                    device: device,
                    options: item.options,
                    authenticationMode: UserDefaults.standard.string(forKey: "authenticationMode") ?? "local"
                )
                let outcome = try await performInstall(request)
                switch outcome {
                case .installed, .installedWithExpiry:
                    let refreshedAt = Date()
                    installations[index].installedAt = refreshedAt
                    let expiry: Date?
                    if case .installedWithExpiry(let date) = outcome { expiry = date } else { expiry = nil }
                    installations[index].profileExpiryConfirmed = expiry != nil
                    installations[index].expiresAt = expiry ?? refreshedAt.addingTimeInterval(7 * 24 * 60 * 60)
                    installations[index].nextRefreshAt = installations[index].expiresAt.addingTimeInterval(-24 * 60 * 60)
                    installations[index].status = "Scheduled"
                    installations[index].lastError = nil
                    succeeded += 1
                case .attention(let message):
                    markAttention(&installations[index], message)
                    attentionNeeded += 1
                case .failed(let message):
                    markRetry(&installations[index], message)
                }
            } catch {
                markAttention(&installations[index], error.localizedDescription)
                attentionNeeded += 1
            }
        }

        if succeeded > 0 {
            postNotification(
                title: "Slip Auto Refresh",
                message: succeeded == 1 ? "One app was refreshed successfully." : "\(succeeded) apps were refreshed successfully."
            )
        }
        if attentionNeeded > 0 {
            postNotification(
                title: "Slip needs attention",
                message: "Open Slip to review \(attentionNeeded) auto-refresh item\(attentionNeeded == 1 ? "" : "s")."
            )
        }
        return Result(
            attempted: attempted,
            succeeded: succeeded,
            attentionNeeded: attentionNeeded
        )
    }

    enum InstallOutcome: Equatable {
        case installed
        case installedWithExpiry(Date)
        case attention(String)
        case failed(String)
    }

    static func performInstall(_ request: InstallRequest, core: CoreClient = CoreClient()) async throws -> InstallOutcome {
        let stream = try core.installStream(request: request)
        var outcome: InstallOutcome = .failed("Installation ended before completion. Slip will retry.")
        do {
        for try await event in stream {
            switch event.type {
            case "operationStarted":
                if let id = event.operationId {
                    do {
                        try await PendingOutcomeStore.shared.save(.init(operationId: id, storagePath: request.storagePath,
                            device: request.device, options: request.options, account: request.email, renewalEnabled: true))
                    } catch {
                        core.cancel()
                        return .attention("Recovery information could not be saved. Open Slip before retrying.")
                    }
                }
            case "completed":
                guard event.confirmsInstallation else {
                    outcome = .attention("Device verification is pending. Open Slip to verify before refreshing again.")
                    continue
                }
                outcome = event.profileExpiresAt.map { .installedWithExpiry(Date(timeIntervalSince1970: $0)) } ?? .installed
            case "provisioningReviewRequired":
                try? core.submitCapabilityAcknowledgement(true)
            case "verificationPending":
                outcome = .attention("Installation may have completed. Open Slip to verify this iPhone before retrying.")
            case "twoFactorRequired":
                try? core.submitTwoFactor(nil)
                outcome = .attention("Apple requested a verification code. Open Slip and refresh this app manually.")
            case "certificateSelectionRequired":
                try? core.submitCertificates(nil)
                outcome = .attention("Apple requires a certificate decision. Open Slip and refresh this app manually.")
            case "error":
                if case .attention = outcome { break }
                outcome = .failed(event.message ?? "Installation failed. Slip will retry.")
            default:
                break
            }
        }
        } catch {
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
        item.status = "Waiting to retry"
        item.lastError = message
        // Back off by 30 minutes to prevent rapid retry loops and Apple server throttling
        item.nextRefreshAt = Date().addingTimeInterval(30 * 60)
    }

    private static func markAttention(_ item: inout ManagedInstallation, _ message: String) {
        item.status = "Needs attention"
        item.lastError = message
        // A user-action failure is excluded from unattended retries. Refresh now
        // or re-enabling the schedule can resume it after the user fixes the issue.
        item.nextRefreshAt = Date().addingTimeInterval(2 * 60 * 60)
    }

    private static func postNotification(title: String, message: String) {
        guard UserDefaults.standard.bool(forKey: "renewalNotificationsEnabled") else { return }
        Task { await NotificationCoordinator.shared.deliver(title == "Slip needs attention" ? .refreshFailed : .refreshSuccess) }
    }
}
