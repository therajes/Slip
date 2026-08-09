import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [DeviceInfo] = []
    @Published var selectedDevice: DeviceInfo?
    @Published var ipa: IpaInfo?
    @Published var ipaIconURL: URL?
    @Published var customName = ""
    @Published var customBundleID = ""
    @Published var customIconURL: URL?
    @Published var removedExtensions: Set<String> = []
    @Published var increasedMemoryLimit = false
    @Published var minimumOSVersion = ""
    @Published var removeSupportedDevices = false
    @Published var enableFileSharing = false
    @Published var plistOverrides: [PlistOverride] = []
    @Published var keepAutomaticallyRefreshed = true
    @Published var accounts: [String] = []
    @Published var accountProfiles: [String: AccountProfile] = [:]
    @Published var selectedAccount = ""
    @Published var isRefreshing = false
    @Published var isInspecting = false
    @Published var isInstalling = false
    @Published var isEnablingWiFi = false
    @Published var isExporting = false
    @Published var isDownloading = false
    @Published var currentStage = "Ready"
    @Published var overallProgress = 0.0
    @Published var activity: [String] = []
    @Published var errorMessage: String?
    @Published var showTwoFactor = false
    @Published var certificates: [CertificateInfo] = []
    @Published var showCertificates = false
    @Published var managedInstallations: [ManagedInstallation] = []
    @Published var installedApps: [InstalledAppInfo] = []
    @Published var isLoadingInstalledApps = false
    @Published var isUninstallingApps = false
    @Published var inspectionDuration: TimeInterval?
    @Published var lastInstallDuration: TimeInterval?
    @Published var refreshingManagedIDs: Set<String> = []
    @Published var hideSensitiveInfo = UserDefaults.standard.bool(forKey: "hideSensitiveInfo") {
        didSet { UserDefaults.standard.set(hideSensitiveInfo, forKey: "hideSensitiveInfo") }
    }

    let core = CoreClient()
    let anisetteServer = "ani.sidestore.io"
    private var stageProgress: [String: Double] = [:]
    private var installStartedAt: Date?

    init(startupTasks: Bool = true) {
        reloadAccounts()
        reloadManagedInstallations()
        if startupTasks {
            do {
                try AutoRefreshScheduler.installIfAppropriate()
            } catch {
                appendActivity("Auto Refresh scheduler: \(error.localizedDescription)")
            }
            Task { await refreshDevices() }
        }
    }

    func reloadAccounts() {
        accounts = KeychainStore.accounts()
        accountProfiles = AccountProfileStore.load(for: accounts)
        let preferred = UserDefaults.standard.string(forKey: "selectedAccount") ?? ""
        selectedAccount = accounts.contains(preferred) ? preferred : (accounts.first ?? "")
    }

    @discardableResult
    func saveAccount(email: String, password: String, profileName: String = "", profileImageURL: URL? = nil) -> Bool {
        do {
            let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized.contains("@"), !password.isEmpty else {
                throw SideloomError.message("Enter a valid Apple Account and password.")
            }
            try KeychainStore.save(account: normalized, password: password)
            try AccountProfileStore.upsert(
                email: normalized,
                displayName: profileName,
                imageURL: profileImageURL
            )
            reloadAccounts()
            selectedAccount = normalized
            UserDefaults.standard.set(normalized, forKey: "selectedAccount")
            appendActivity("Saved \(normalized) in macOS Keychain")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteAccount(_ email: String) {
        do {
            try KeychainStore.delete(account: email)
            try? AccountProfileStore.delete(email)
            reloadAccounts()
            appendActivity("Removed \(email) from macOS Keychain")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseAccount(_ email: String) {
        selectedAccount = email
        UserDefaults.standard.set(email, forKey: "selectedAccount")
    }

    func updateAccountPhoto(_ imageURL: URL, for email: String) {
        do {
            try AccountProfileStore.upsert(email: email, displayName: nil, imageURL: imageURL)
            reloadAccounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeAccountPhoto(for email: String) {
        do {
            try AccountProfileStore.removeImage(for: email)
            reloadAccounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshDevices() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let event = try await core.run(["devices"])
            devices = event.devices ?? []
            if let current = selectedDevice,
               let replacement = devices.first(where: { $0.identity == current.identity }) {
                selectedDevice = replacement
            } else {
                selectedDevice = devices.first(where: {
                    $0.connectionType.caseInsensitiveCompare("USB") == .orderedSame
                }) ?? devices.first
            }
            if let errors = event.errors, !errors.isEmpty {
                appendActivity(errors.joined(separator: " • "))
            }
        } catch {
            devices = []
            selectedDevice = nil
            errorMessage = error.localizedDescription
        }
    }

    func loadIPA(_ url: URL) async {
        guard url.pathExtension.lowercased() == "ipa" else {
            errorMessage = "Choose a valid .ipa file."
            return
        }
        isInspecting = true
        let startedAt = Date()
        discardIPAPreview()
        defer { isInspecting = false }
        do {
            let event = try await core.run(["inspect", url.path])
            guard let info = event.ipa else {
                throw SideloomError.message("The IPA could not be inspected.")
            }
            ipa = info
            customName = ""
            customBundleID = ""
            customIconURL = nil
            removedExtensions = Set(info.extensions.map(\.path))
            minimumOSVersion = ""
            removeSupportedDevices = false
            enableFileSharing = false
            plistOverrides = []
            await loadIPAPreview(for: info)
            inspectionDuration = Date().timeIntervalSince(startedAt)
            appendActivity("Loaded \(info.appName) \(info.version) in \(inspectionDuration?.formatted(.number.precision(.fractionLength(2))) ?? "0")s")
        } catch {
            ipa = nil
            discardIPAPreview()
            errorMessage = friendlyMessage(for: error)
        }
    }

    func downloadIPA(from input: String) async {
        guard !isDownloading else { return }
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            errorMessage = "Enter a valid HTTP or HTTPS IPA URL."
            return
        }
        isDownloading = true
        currentStage = "Downloading IPA"
        defer { isDownloading = false }

        var lastError: Error?
        for attempt in 1...3 {
            do {
                appendActivity("Downloading IPA (attempt \(attempt) of 3)")
                let (temporaryURL, response) = try await URLSession.shared.download(from: url)
                if let response = response as? HTTPURLResponse,
                   !(200...299).contains(response.statusCode) {
                    throw SideloomError.message("Download failed with HTTP \(response.statusCode).")
                }
                let support = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                ).appending(path: "app.sideloom.native/Imports", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(
                    at: support,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let suggested = url.lastPathComponent.lowercased().hasSuffix(".ipa")
                    ? url.lastPathComponent
                    : "Downloaded.ipa"
                let destination = support.appending(
                    path: "\(UUID().uuidString)-\(suggested)",
                    directoryHint: .notDirectory
                )
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                currentStage = "Inspecting download"
                await loadIPA(destination)
                if ipa?.path == destination.path {
                    appendActivity("Downloaded and verified \(destination.lastPathComponent)")
                    return
                }
                throw SideloomError.message("The downloaded file is not a valid IPA.")
            } catch {
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(attempt))
                }
            }
        }
        currentStage = "Download failed"
        errorMessage = lastError?.localizedDescription ?? "The IPA could not be downloaded."
        appendActivity("Download failed after three attempts")
    }

    func enableWiFiConnection() async {
        guard !isEnablingWiFi else { return }
        guard let device = selectedDevice else {
            errorMessage = "Connect and select an iPhone first."
            return
        }
        guard device.connectionType.caseInsensitiveCompare("USB") == .orderedSame else {
            errorMessage = "Connect this iPhone by USB before enabling its Wi-Fi connection."
            return
        }
        isEnablingWiFi = true
        defer { isEnablingWiFi = false }
        do {
            let event = try await core.run(["enable-wifi", device.udid])
            appendActivity(event.message ?? "Enabled Wi-Fi connection for \(device.name)")
            await refreshDevices()
        } catch {
            errorMessage = error.localizedDescription
            appendActivity("Wi-Fi setup failed: \(error.localizedDescription)")
        }
    }

    func loadInstalledApps() async {
        guard !isLoadingInstalledApps else { return }
        guard let device = selectedDevice else {
            installedApps = []
            return
        }
        isLoadingInstalledApps = true
        defer { isLoadingInstalledApps = false }
        do {
            let event = try await core.run(["apps"], input: device)
            installedApps = event.apps ?? []
            appendActivity("Loaded \(installedApps.count) user apps from \(device.name)")
        } catch {
            installedApps = []
            errorMessage = error.localizedDescription
        }
    }

    func copyBundleIDs(_ bundleIDs: Set<String>) {
        guard !bundleIDs.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bundleIDs.sorted().joined(separator: "\n"), forType: .string)
        appendActivity("Copied \(bundleIDs.count) bundle ID\(bundleIDs.count == 1 ? "" : "s")")
    }

    func refreshManagedInstallations(_ ids: Set<String>) {
        let available = ids.subtracting(refreshingManagedIDs)
        guard !available.isEmpty else { return }
        refreshingManagedIDs.formUnion(available)
        Task {
            let result = await AutoRefreshWorker.runDue(forceIDs: available)
            refreshingManagedIDs.subtract(available)
            reloadManagedInstallations()
            appendActivity("Selected refresh finished: \(result.succeeded)/\(result.attempted) succeeded")
        }
    }

    @discardableResult
    func uninstallApps(bundleIDs: Set<String>) async -> Set<String> {
        guard !isUninstallingApps, let device = selectedDevice, !bundleIDs.isEmpty else { return [] }
        isUninstallingApps = true
        defer { isUninstallingApps = false }
        do {
            let request = UninstallAppsRequest(device: device, bundleIds: bundleIDs.sorted())
            let event = try await core.run(["uninstall"], input: request)
            let removed = Set(event.bundleIds ?? [])
            installedApps.removeAll { removed.contains($0.bundleId) }
            if !removed.isEmpty {
                removeRefreshRecipes(for: removed)
            }
            appendActivity(event.message ?? "Removed \(removed.count) app\(removed.count == 1 ? "" : "s") from \(device.marketingName)")
            if let errors = event.errors, !errors.isEmpty {
                errorMessage = errors.joined(separator: "\n")
                appendActivity("Some selected apps could not be removed")
            }
            return removed
        } catch {
            errorMessage = friendlyMessage(for: error)
            appendActivity("Uninstall failed: \(friendlyMessage(for: error))")
            return []
        }
    }

    func install() {
        guard !isInstalling else { return }
        guard let ipa, let selectedDevice else {
            errorMessage = ipa == nil ? "Choose an IPA first." : "Connect and select an iPhone."
            return
        }
        guard !selectedAccount.isEmpty else {
            errorMessage = "Add an Apple Account in Keychain first."
            return
        }
        if let issue = blockingInstallIssue {
            errorMessage = "\(issue.title). \(issue.detail)"
            return
        }

        do {
            let password = try KeychainStore.password(for: selectedAccount)
            let storageURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appending(path: "app.sideloom.native/Core", directoryHint: .isDirectory)
            let options = installOptions(for: ipa)
            let request = InstallRequest(
                email: selectedAccount,
                password: password,
                anisetteServer: anisetteServer,
                storagePath: storageURL.path,
                device: selectedDevice,
                options: options
            )
            isInstalling = true
            overallProgress = 0
            stageProgress = [:]
            currentStage = "Starting"
            installStartedAt = Date()
            appendActivity("Starting install on \(selectedDevice.name) via \(selectedDevice.connectionType)")
            Task { await consumeInstall(request, ipa: ipa) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportModifiedIPA(to destination: URL) {
        guard !isExporting else { return }
        guard let ipa else {
            errorMessage = "Choose an IPA first."
            return
        }
        guard canExport else {
            let issue = customizationIssues.first { $0.level == .blocking }
            errorMessage = issue.map { "\($0.title). \($0.detail)" } ?? "This IPA cannot be exported safely."
            return
        }
        isExporting = true
        currentStage = "Exporting IPA"
        let request = ExportRequest(
            destination: destination.path,
            options: installOptions(for: ipa)
        )
        Task {
            defer { isExporting = false }
            do {
                let event = try await core.run(["export"], input: request)
                currentStage = "Exported"
                appendActivity(event.message ?? "Exported modified IPA to \(destination.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                currentStage = "Export failed"
                errorMessage = error.localizedDescription
                appendActivity("Export failed: \(error.localizedDescription)")
            }
        }
    }

    func copySelectedUDID() {
        guard let udid = selectedDevice?.udid else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(udid, forType: .string)
        appendActivity("Copied iPhone UDID")
    }

    func addPlistOverride() {
        plistOverrides.append(PlistOverride())
    }

    func clearIPA() {
        ipa = nil
        discardIPAPreview()
        inspectionDuration = nil
        resetCustomizations()
        currentStage = "Ready"
        overallProgress = 0
    }

    func resetCustomizations() {
        customName = ""
        customBundleID = ""
        customIconURL = nil
        removedExtensions = Set(ipa?.extensions.map(\.path) ?? [])
        increasedMemoryLimit = false
        minimumOSVersion = ""
        removeSupportedDevices = false
        enableFileSharing = false
        plistOverrides = []
    }

    func removePlistOverride(_ id: UUID) {
        plistOverrides.removeAll { $0.id == id }
    }

    func refreshAllManagedInstallations() {
        let ids = Set(managedInstallations.filter(\.enabled).map(\.id))
        refreshManagedInstallations(ids)
    }

    private func consumeInstall(_ request: InstallRequest, ipa: IpaInfo) async {
        defer { isInstalling = false }
        do {
            let stream = try core.installStream(request: request)
            for try await event in stream {
                switch event.type {
                case "progress":
                    updateProgress(stage: event.stage ?? "working", value: event.value ?? 0, message: event.message)
                case "twoFactorRequired":
                    showTwoFactor = true
                    appendActivity("Apple requested a verification code")
                case "accountProfile":
                    if let email = event.email, let accountName = event.accountName {
                        try? AccountProfileStore.upsert(email: email, displayName: accountName)
                        reloadAccounts()
                    }
                case "certificateSelectionRequired":
                    certificates = event.certificates ?? []
                    showCertificates = true
                case "completed":
                    overallProgress = 1
                    currentStage = "Installed"
                    if let installStartedAt {
                        lastInstallDuration = Date().timeIntervalSince(installStartedAt)
                    }
                    appendActivity("Installation completed successfully\(lastInstallDuration.map { " in \($0.formatted(.number.precision(.fractionLength(1))))s" } ?? "")")
                    do {
                        let entry = try AutoRefreshStore.recordSuccessfulInstall(
                            ipa: ipa,
                            request: request,
                            enabled: keepAutomaticallyRefreshed
                        )
                        reloadManagedInstallations()
                        if entry.enabled {
                            appendActivity("Auto Refresh scheduled for \(entry.nextRefreshAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                    } catch {
                        appendActivity("Could not save Auto Refresh schedule: \(error.localizedDescription)")
                    }
                case "error":
                    let message = friendlyMessage(event.message ?? "Installation failed")
                    showTwoFactor = false
                    showCertificates = false
                    errorMessage = message
                    appendActivity("Error: \(message)")
                default:
                    break
                }
            }
        } catch {
            showTwoFactor = false
            showCertificates = false
            if errorMessage == nil { errorMessage = friendlyMessage(for: error) }
            if let errorMessage { appendActivity("Error: \(errorMessage)") }
            appendActivity("Installation stopped")
        }
    }

    func submitTwoFactor(_ code: String?) {
        defer { showTwoFactor = false }
        do {
            try core.submitTwoFactor(code)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submitCertificates(_ serials: [String]?) {
        defer { showCertificates = false }
        do {
            try core.submitCertificates(serials)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelInstall() {
        core.cancel()
        isInstalling = false
        currentStage = "Cancelled"
        appendActivity("Installation cancelled")
    }

    func reloadManagedInstallations() {
        managedInstallations = AutoRefreshStore.load().sorted {
            $0.nextRefreshAt < $1.nextRefreshAt
        }
    }

    func setAutoRefreshEnabled(_ enabled: Bool, for id: String) {
        var installations = AutoRefreshStore.load()
        guard let index = installations.firstIndex(where: { $0.id == id }) else { return }
        installations[index].enabled = enabled
        installations[index].status = enabled ? "Scheduled" : "Paused"
        installations[index].lastError = nil
        do {
            try AutoRefreshStore.save(installations)
            reloadManagedInstallations()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func forgetManagedInstallation(_ id: String) {
        var installations = AutoRefreshStore.load()
        installations.removeAll { $0.id == id }
        do {
            try AutoRefreshStore.save(installations)
            reloadManagedInstallations()
            appendActivity("Removed an Auto Refresh schedule")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshManagedInstallationNow(_ id: String) {
        guard !refreshingManagedIDs.contains(id) else { return }
        refreshingManagedIDs.insert(id)
        Task {
            let result = await AutoRefreshWorker.runDue(forceIDs: [id])
            refreshingManagedIDs.remove(id)
            reloadManagedInstallations()
            if result.succeeded > 0 {
                appendActivity("Auto Refresh completed successfully")
            } else if result.attempted > 0 {
                appendActivity("Auto Refresh did not complete; review its status")
            }
        }
    }

    private func updateProgress(stage: String, value: Double, message: String?) {
        stageProgress[stage] = value
        let prepare = stageProgress["prepare", default: 0]
        let sign = stageProgress["sign", default: 0]
        let install = stageProgress["install", default: 0]
        let account = stageProgress["account", default: stage == "account" ? value : 1]
        overallProgress = account * 0.08 + prepare * 0.12 + sign * 0.40 + install * 0.40
        currentStage = message ?? stage.capitalized
    }

    private func installOptions(for ipa: IpaInfo) -> IpaInstallOptions {
        IpaInstallOptions(
            appPath: ipa.path,
            displayName: customName.trimmed.nilIfEmpty,
            bundleId: customBundleID.trimmed.nilIfEmpty,
            removedExtensions: Array(removedExtensions).sorted(),
            customIconPath: customIconURL?.path,
            increasedMemoryLimit: increasedMemoryLimit,
            minimumOsVersion: minimumOSVersion.trimmed.nilIfEmpty,
            removeSupportedDevices: removeSupportedDevices,
            enableFileSharing: enableFileSharing,
            plistOverrides: plistOverrides.filter { !$0.key.trimmed.isEmpty }
        )
    }

    private func removeRefreshRecipes(for bundleIDs: Set<String>) {
        var installations = AutoRefreshStore.load()
        let originalCount = installations.count
        installations.removeAll { bundleIDs.contains($0.bundleId) }
        guard installations.count != originalCount else { return }
        do {
            try AutoRefreshStore.save(installations)
            reloadManagedInstallations()
            appendActivity("Removed matching Auto Refresh schedules")
        } catch {
            errorMessage = "The apps were removed, but Slip could not remove their Auto Refresh schedules: \(error.localizedDescription)"
        }
    }

    private func loadIPAPreview(for info: IpaInfo) async {
        do {
            let previewDirectory = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appending(path: "app.sideloom.native/IPAIcons", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: previewDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let destination = previewDirectory.appending(
                path: "\(UUID().uuidString).png",
                directoryHint: .notDirectory
            )
            _ = try await core.run(["icon", info.path, destination.path])
            guard ipa?.path == info.path, FileManager.default.fileExists(atPath: destination.path) else {
                try? FileManager.default.removeItem(at: destination)
                return
            }
            ipaIconURL = destination
        } catch {
            ipaIconURL = nil
            appendActivity("The IPA did not expose a usable app icon; showing a fallback.")
        }
    }

    private func discardIPAPreview() {
        if let ipaIconURL {
            try? FileManager.default.removeItem(at: ipaIconURL)
        }
        ipaIconURL = nil
    }

    var visibleActivity: [String] {
        hideSensitiveInfo ? activity.map(redacted) : activity
    }

    private func redacted(_ entry: String) -> String {
        var result = entry.replacingOccurrences(
            of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            with: "••••@••••",
            options: [.regularExpression, .caseInsensitive]
        )
        for device in devices {
            result = result.replacingOccurrences(of: device.udid, with: "••••••••-••••")
        }
        result = result.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
        return result
    }

    private func appendActivity(_ entry: String) {
        activity.insert(entry, at: 0)
        if activity.count > 100 { activity.removeLast(activity.count - 100) }
    }

    private func friendlyMessage(for error: Error) -> String {
        friendlyMessage(error.localizedDescription)
    }

    private func friendlyMessage(_ raw: String) -> String {
        var message = raw
        if let expression = try? NSRegularExpression(pattern: #"/Users/[^\s]+/\.cargo/[^\s]+:\d+(?::\d+)?"#) {
            message = expression.stringByReplacingMatches(
                in: message,
                range: NSRange(message.startIndex..., in: message),
                withTemplate: "signing engine"
            )
        }
        message = message.replacingOccurrences(of: "thread 'main' panicked", with: "The signing engine stopped unexpectedly")
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
