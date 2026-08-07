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
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ManagedInstallation].self, from: data)) ?? []
    }

    static func save(_ installations: [ManagedInstallation]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(installations).write(to: fileURL, options: [.atomic])
    }

    static func recordSuccessfulInstall(
        ipa: IpaInfo,
        request: InstallRequest,
        enabled: Bool
    ) throws -> ManagedInstallation {
        let now = Date()
        let effectiveBundleID = request.options.bundleId ?? ipa.bundleId
        let key = "\(request.device.udid)|\(effectiveBundleID)"
        var installations = load()
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
            expiresAt: now.addingTimeInterval(7 * 24 * 60 * 60),
            nextRefreshAt: now.addingTimeInterval(6 * 24 * 60 * 60),
            lastAttemptAt: now,
            enabled: enabled,
            status: enabled ? "Scheduled" : "Paused",
            lastError: nil
        )
        installations.removeAll {
            $0.deviceUDID == request.device.udid && $0.bundleId == effectiveBundleID
        }
        installations.append(entry)
        try save(installations)
        return entry
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
        FileManager.default.fileExists(atPath: launchAgentURL.path)
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
        if (try? Data(contentsOf: launchAgentURL)) != data {
            try data.write(to: launchAgentURL, options: [.atomic])
        }

        let target = "gui/\(getuid())"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", target, launchAgentURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        // launchctl returns a non-zero status when this unchanged agent is already loaded.
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
            return item.enabled && (forceIDs.contains(item.id) || item.nextRefreshAt <= now)
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
            try? AutoRefreshStore.save(installations)

            let item = installations[index]
            guard FileManager.default.fileExists(atPath: item.ipaPath) else {
                markAttention(
                    &installations[index],
                    "IPA file is missing. Restore it to \(item.ipaPath) or install it again."
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
            try? AutoRefreshStore.save(installations)
        }

        try? AutoRefreshStore.save(installations)
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
            $0.replacingOccurrences(of: "\\", with: "\\\\")
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
