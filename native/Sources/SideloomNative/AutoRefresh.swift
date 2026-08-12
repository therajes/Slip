import AppKit
import Darwin
import Foundation

@_silgen_name("flock")
private func slipFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

final class DeviceOperationLease: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func release() {
        stateLock.lock()
        guard let descriptor else {
            stateLock.unlock()
            return
        }
        self.descriptor = nil
        stateLock.unlock()
        _ = slipFlock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    deinit { release() }
}

enum DeviceOperationCoordinator {
    static func acquire() throws -> DeviceOperationLease {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "app.sideloom.native", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: base.path
        )
        let path = base.appending(path: "device-operation.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw SideloomError.message("Unable to create the iPhone operation lock.")
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(descriptor)
            throw SideloomError.message("Unable to protect the iPhone operation lock.")
        }
        guard slipFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw SideloomError.message(
                "Another Slip install, refresh, or uninstall operation is already running."
            )
        }
        return DeviceOperationLease(descriptor: descriptor)
    }
}

struct ManagedInstallation: Codable, Hashable, Identifiable {
    let id: String
    var appName: String
    var bundleId: String
    var account: String
    var deviceUDID: String
    var deviceName: String
    var options: IpaInstallOptions
    var installedAt: Date
    var expiresAt: Date
    var nextRefreshAt: Date
    var lastAttemptAt: Date?
    var enabled: Bool
    var status: String
    var lastError: String?

    var ipaPath: String { options.appPath }
}

@MainActor
enum AutoRefreshStore {
    private static let fileName = "managed-installations.json"
    private static let lockFileName = "managed-installations.lock"

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
        (try? withLock(exclusive: false) { try loadUnlocked(strict: false) }) ?? []
    }

    static func save(_ installations: [ManagedInstallation]) throws {
        try withLock(exclusive: true) {
            try saveUnlocked(installations)
        }
    }

    @discardableResult
    static func mutate(
        _ changes: (inout [ManagedInstallation]) throws -> Void
    ) throws -> [ManagedInstallation] {
        try withLock(exclusive: true) {
            var installations = try loadUnlocked(strict: true)
            try changes(&installations)
            try saveUnlocked(installations)
            return installations
        }
    }

    static func updateRuntime(_ entry: ManagedInstallation) throws {
        try mutate { installations in
            guard let index = installations.firstIndex(where: { $0.id == entry.id }) else {
                return
            }
            let enabled = installations[index].enabled
            var merged = entry
            merged.enabled = enabled
            if !enabled && merged.status != "Needs attention" {
                merged.status = "Paused"
            } else if enabled && merged.status == "Paused" {
                merged.status = "Scheduled"
            }
            installations[index] = merged
        }
    }

    private static func loadUnlocked(strict: Bool) throws -> [ManagedInstallation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let size = attributes[.size] as? NSNumber, size.int64Value > 16 * 1_024 * 1_024 {
            throw SideloomError.message("The Auto Refresh schedule is unexpectedly large.")
        }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            return try JSONDecoder().decode([ManagedInstallation].self, from: data)
        } catch {
            if strict {
                throw SideloomError.message(
                    "The Auto Refresh schedule is damaged. Restore or remove managed-installations.json before changing schedules."
                )
            }
            return []
        }
    }

    private static func saveUnlocked(_ installations: [ManagedInstallation]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(installations).write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func withLock<T>(
        exclusive: Bool,
        _ operation: () throws -> T
    ) throws -> T {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let lockURL = directory.appending(path: lockFileName)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw SideloomError.message("Unable to lock the Auto Refresh schedule.")
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(descriptor)
            throw SideloomError.message("Unable to protect the Auto Refresh schedule lock.")
        }
        defer { Darwin.close(descriptor) }
        guard slipFlock(descriptor, exclusive ? LOCK_EX : LOCK_SH) == 0 else {
            throw SideloomError.message("Unable to coordinate the Auto Refresh schedule.")
        }
        defer { _ = slipFlock(descriptor, LOCK_UN) }
        return try operation()
    }

    static func recordSuccessfulInstall(
        ipa: IpaInfo,
        account: String,
        device: DeviceInfo,
        options: IpaInstallOptions,
        enabled: Bool
    ) throws -> ManagedInstallation {
        let now = Date()
        let effectiveBundleID = options.bundleId ?? ipa.bundleId
        let key = "\(device.udid)|\(effectiveBundleID)"
        var savedEntry: ManagedInstallation?
        try mutate { installations in
            let existingID = installations.first(where: {
                $0.deviceUDID == device.udid && $0.bundleId == effectiveBundleID
            })?.id
            let entry = ManagedInstallation(
                id: existingID ?? key,
                appName: options.displayName ?? ipa.appName,
                bundleId: effectiveBundleID,
                account: account,
                deviceUDID: device.udid,
                deviceName: device.name,
                options: options,
                installedAt: now,
                expiresAt: now.addingTimeInterval(7 * 24 * 60 * 60),
                nextRefreshAt: now.addingTimeInterval(6 * 24 * 60 * 60),
                lastAttemptAt: now,
                enabled: enabled,
                status: enabled ? "Scheduled" : "Paused",
                lastError: nil
            )
            installations.removeAll {
                $0.deviceUDID == device.udid && $0.bundleId == effectiveBundleID
            }
            installations.append(entry)
            savedEntry = entry
        }
        guard let savedEntry else {
            throw SideloomError.message("Unable to save the Auto Refresh schedule.")
        }
        return savedEntry
    }
}

@MainActor
enum AutoRefreshScheduler {
    static let label = "app.sideloom.native.refresh"
    static let intervalSeconds = 6 * 60 * 60

    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
            .appending(path: "\(label).plist")
    }

    static var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: launchAgentURL.path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

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
        let configurationChanged = (try? Data(contentsOf: launchAgentURL)) != data
        if configurationChanged {
            try data.write(to: launchAgentURL, options: [.atomic])
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: launchAgentURL.path
        )

        let target = "gui/\(getuid())"
        if configurationChanged && isInstalled {
            let unload = Process()
            unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            unload.arguments = ["bootout", "\(target)/\(label)"]
            unload.standardOutput = FileHandle.nullDevice
            unload.standardError = FileHandle.nullDevice
            try unload.run()
            unload.waitUntilExit()
            if unload.terminationStatus != 0 && isInstalled {
                throw SideloomError.message(
                    "macOS could not reload Slip's updated background refresh service."
                )
            }
        } else if isInstalled {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", target, launchAgentURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        // bootstrap returns a non-zero status when this unchanged agent is already loaded.
        // Verify the service state instead of assuming every non-zero result is harmless.
        guard isInstalled else {
            throw SideloomError.message("macOS could not activate Slip's background refresh service.")
        }
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
        guard let operationLease = try? DeviceOperationCoordinator.acquire() else {
            return Result(attempted: 0, succeeded: 0, attentionNeeded: 0)
        }
        defer { operationLease.release() }
        var installations = AutoRefreshStore.load()
        let now = Date()
        let dueIndexes = installations.indices.filter { index in
            let item = installations[index]
            return forceIDs.contains(item.id) || (item.enabled && item.nextRefreshAt <= now)
        }
        guard !dueIndexes.isEmpty else {
            return Result(attempted: 0, succeeded: 0, attentionNeeded: 0)
        }

        let discovery = try? await CoreClient().run(["devices"])
        let devices = discovery?.devices ?? []
        var succeeded = 0
        var attentionNeeded = 0

        for index in dueIndexes {
            installations[index].lastAttemptAt = Date()
            installations[index].status = "Refreshing"
            installations[index].lastError = nil
            try? AutoRefreshStore.updateRuntime(installations[index])

            let item = installations[index]
            guard FileManager.default.fileExists(atPath: item.ipaPath) else {
                markAttention(
                    &installations[index],
                    "IPA file is missing. Restore it to \(item.ipaPath) or install it again."
                )
                attentionNeeded += 1
                try? AutoRefreshStore.updateRuntime(installations[index])
                continue
            }
            guard let device = preferredDevice(for: item, among: devices) else {
                markRetry(
                    &installations[index],
                    "iPhone is not reachable. Slip will retry over Wi‑Fi or USB."
                )
                try? AutoRefreshStore.updateRuntime(installations[index])
                continue
            }

            do {
                let password = try KeychainStore.password(for: item.account)
                let request = InstallRequest(
                    email: item.account,
                    password: password,
                    anisetteServer: "ani.sidestore.io",
                    storagePath: coreStorageURL().path,
                    device: device,
                    options: item.options
                )
                let outcome = try await performInstall(request)
                switch outcome {
                case .installed:
                    let refreshedAt = Date()
                    installations[index].installedAt = refreshedAt
                    installations[index].expiresAt = refreshedAt.addingTimeInterval(7 * 24 * 60 * 60)
                    installations[index].nextRefreshAt = refreshedAt.addingTimeInterval(6 * 24 * 60 * 60)
                    installations[index].status = installations[index].enabled ? "Scheduled" : "Paused"
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
            try? AutoRefreshStore.updateRuntime(installations[index])
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
            attempted: dueIndexes.count,
            succeeded: succeeded,
            attentionNeeded: attentionNeeded
        )
    }

    private enum InstallOutcome {
        case installed
        case attention(String)
        case failed(String)
    }

    private static func performInstall(_ request: InstallRequest) async throws -> InstallOutcome {
        let core = CoreClient()
        let stream = try core.installStream(request: request)
        var outcome: InstallOutcome = .failed("Installation ended before completion. Slip will retry.")
        for try await event in stream {
            switch event.type {
            case "completed":
                outcome = .installed
            case "twoFactorRequired":
                try? core.submitTwoFactor(nil)
                outcome = .attention("Apple requested a verification code. Open Slip and refresh this app manually.")
            case "certificateSelectionRequired":
                try? core.submitCertificates(nil)
                outcome = .attention("Apple requires a certificate decision. Open Slip and refresh this app manually.")
            case "error":
                if case .attention = outcome {
                    break
                }
                outcome = .failed(event.message ?? "Installation failed. Slip will retry.")
            default:
                break
            }
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

    private static func coreStorageURL() -> URL {
        let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return (base ?? FileManager.default.homeDirectoryForCurrentUser)
            .appending(path: "app.sideloom.native/Core", directoryHint: .isDirectory)
    }

    private static func markRetry(_ item: inout ManagedInstallation, _ message: String) {
        item.status = "Waiting to retry"
        item.lastError = message
    }

    private static func markAttention(_ item: inout ManagedInstallation, _ message: String) {
        item.status = "Needs attention"
        item.lastError = message
    }

    private static func postNotification(title: String, message: String) {
        let escape: (String) -> String = {
            $0.components(separatedBy: .controlCharacters)
                .joined(separator: " ")
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "display notification \"\(escape(message))\" with title \"\(escape(title))\""
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
