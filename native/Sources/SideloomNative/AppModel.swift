import AppKit
import Foundation
import SwiftUI

private final class StrictHTTPSRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}

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
    @Published var activeAppIDs: [DeveloperAppIDInfo] = []
    @Published var appIDMaxQuantity: UInt64?
    @Published var appIDAvailableQuantity: Int64?
    @Published var appIDTeamName = ""
    @Published var appIDAccount = ""
    @Published var isLoadingAppIDs = false
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
    private var installCancellationRequested = false
    private var installOperationLease: DeviceOperationLease?

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
        if !appIDAccount.isEmpty,
           appIDAccount.caseInsensitiveCompare(selectedAccount) != .orderedSame {
            clearAppIDInventory()
        }
    }

    @discardableResult
    func saveAccount(email: String, password: String, profileName: String = "") -> Bool {
        do {
            let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let emailParts = normalized.split(separator: "@", omittingEmptySubsequences: false)
            guard emailParts.count == 2,
                  emailParts.allSatisfy({ !$0.isEmpty }),
                  normalized.utf8.count <= 254,
                  !normalized.contains(where: { $0.isWhitespace || $0.isNewline }),
                  !password.isEmpty else {
                throw SideloomError.message("Enter a valid Apple Account and password.")
            }
            let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedName.count <= 80, !trimmedName.contains(where: \.isNewline) else {
                throw SideloomError.message("Profile names must be one line and 80 characters or fewer.")
            }
            try KeychainStore.save(account: normalized, password: password)
            try AccountProfileStore.upsert(email: normalized, displayName: profileName)
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
            if appIDAccount == email.lowercased() { clearAppIDInventory() }
            appendActivity("Removed \(email) from macOS Keychain")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseAccount(_ email: String) {
        if !appIDAccount.isEmpty,
           appIDAccount.caseInsensitiveCompare(email) != .orderedSame {
            clearAppIDInventory()
        }
        selectedAccount = email
        UserDefaults.standard.set(email, forKey: "selectedAccount")
    }

    func loadActiveAppIDs() async {
        guard !isLoadingAppIDs else { return }
        guard !isInstalling && !isUninstallingApps else {
            errorMessage = "Wait for the current iPhone operation to finish before contacting Apple again."
            return
        }
        guard !selectedAccount.isEmpty else {
            errorMessage = "Add and select an Apple Account first."
            return
        }

        let requestedAccount = selectedAccount
        isLoadingAppIDs = true
        errorMessage = nil
        defer {
            isLoadingAppIDs = false
            showTwoFactor = false
        }
        do {
            let password = try KeychainStore.password(for: requestedAccount)
            let storageURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appending(path: "app.sideloom.native/Core", directoryHint: .isDirectory)
            let request = AppleAccountRequest(
                email: requestedAccount,
                password: password,
                anisetteServer: anisetteServer,
                storagePath: storageURL.path
            )
            let stream = try core.appIDsStream(request: request)
            var receivedInventory = false
            for try await event in stream {
                switch event.type {
                case "twoFactorRequired":
                    showTwoFactor = true
                    appendActivity("Apple requested verification before loading App IDs")
                case "accountProfile":
                    if let email = event.email, let accountName = event.accountName {
                        try? AccountProfileStore.upsert(email: email, displayName: accountName)
                        reloadAccounts()
                    }
                case "appIds":
                    guard selectedAccount.caseInsensitiveCompare(requestedAccount) == .orderedSame else {
                        appendActivity("Discarded App IDs because the selected Apple Account changed")
                        continue
                    }
                    activeAppIDs = event.appIds ?? []
                    appIDMaxQuantity = event.maxQuantity
                    appIDAvailableQuantity = event.availableQuantity
                    appIDTeamName = event.message ?? "Apple Developer Team"
                    appIDAccount = requestedAccount.lowercased()
                    receivedInventory = true
                    appendActivity("Loaded \(activeAppIDs.count) active App ID\(activeAppIDs.count == 1 ? "" : "s") from Apple")
                case "error":
                    let message = friendlyMessage(event.message ?? "Apple App IDs could not be loaded")
                    errorMessage = message
                    appendActivity("App ID loading failed: \(message)")
                default:
                    break
                }
            }
            if !receivedInventory && errorMessage == nil {
                throw SideloomError.message("Apple returned no App ID inventory.")
            }
        } catch {
            errorMessage = friendlyMessage(for: error)
            appendActivity("App ID loading failed: \(friendlyMessage(for: error))")
        }
    }

    private func clearAppIDInventory() {
        activeAppIDs = []
        appIDMaxQuantity = nil
        appIDAvailableQuantity = nil
        appIDTeamName = ""
        appIDAccount = ""
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
        guard !isInspecting else {
            errorMessage = "Wait for the current IPA inspection to finish."
            return
        }
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
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedInput.utf8.count <= 4_096,
              let url = URL(string: trimmedInput),
              url.scheme?.lowercased() == "https" else {
            errorMessage = "Enter a valid HTTPS IPA URL."
            return
        }
        isDownloading = true
        currentStage = "Downloading IPA"
        defer { isDownloading = false }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        let session = URLSession(
            configuration: configuration,
            delegate: StrictHTTPSRedirectDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        let maximumDownloadBytes: Int64 = 4 * 1_024 * 1_024 * 1_024

        var lastError: Error?
        for attempt in 1...3 {
            var importedURL: URL?
            do {
                appendActivity("Downloading IPA (attempt \(attempt) of 3)")
                let (temporaryURL, response) = try await session.download(from: url)
                if let response = response as? HTTPURLResponse,
                   !(200...299).contains(response.statusCode) {
                    throw SideloomError.message("Download failed with HTTP \(response.statusCode).")
                }
                guard response.url?.scheme?.lowercased() == "https" else {
                    throw SideloomError.message("The download redirected to an insecure connection.")
                }
                if response.expectedContentLength > maximumDownloadBytes {
                    throw SideloomError.message("The download is larger than Slip's 4 GB safety limit.")
                }
                let downloadedSize = try FileManager.default.attributesOfItem(
                    atPath: temporaryURL.path
                )[.size] as? NSNumber
                if downloadedSize?.int64Value ?? 0 > maximumDownloadBytes {
                    throw SideloomError.message("The download is larger than Slip's 4 GB safety limit.")
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
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: support.path
                )
                let destination = support.appending(
                    path: "\(UUID().uuidString)-Downloaded.ipa",
                    directoryHint: .notDirectory
                )
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                importedURL = destination
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destination.path
                )
                currentStage = "Inspecting download"
                errorMessage = nil
                await loadIPA(destination)
                if ipa?.path == destination.path {
                    appendActivity("Downloaded and verified \(destination.lastPathComponent)")
                    return
                }
                try? FileManager.default.removeItem(at: destination)
                throw SideloomError.message("The downloaded file is not a valid IPA.")
            } catch {
                if let importedURL, ipa?.path != importedURL.path {
                    try? FileManager.default.removeItem(at: importedURL)
                }
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
        guard !isInstalling && !isUninstallingApps else {
            errorMessage = "Wait for the current iPhone operation before changing Wi-Fi pairing."
            return
        }
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
            let operationLease = try DeviceOperationCoordinator.acquire()
            defer { operationLease.release() }
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
        guard !isInstalling && !isUninstallingApps else {
            errorMessage = "Wait for the current iPhone operation before loading apps."
            return
        }
        guard let device = selectedDevice else {
            installedApps = []
            return
        }
        isLoadingInstalledApps = true
        defer { isLoadingInstalledApps = false }
        do {
            let operationLease = try DeviceOperationCoordinator.acquire()
            defer { operationLease.release() }
            let event = try await core.run(["apps"], input: device)
            guard selectedDevice?.identity == device.identity else {
                appendActivity("Discarded app inventory because the selected iPhone changed")
                return
            }
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
        guard !isInstalling && !isUninstallingApps else {
            errorMessage = "Wait for the current iPhone operation to finish before refreshing."
            return
        }
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
            let operationLease = try DeviceOperationCoordinator.acquire()
            defer { operationLease.release() }
            let request = UninstallAppsRequest(device: device, bundleIds: bundleIDs.sorted())
            let event = try await core.run(["uninstall"], input: request)
            let removed = Set(event.bundleIds ?? [])
            if selectedDevice?.identity == device.identity {
                installedApps.removeAll { removed.contains($0.bundleId) }
            }
            if !removed.isEmpty {
                removeRefreshRecipes(for: removed, deviceUDID: device.udid)
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
        guard !isLoadingInstalledApps && !isUninstallingApps && !isEnablingWiFi else {
            errorMessage = "Wait for the current iPhone operation to finish before installing."
            return
        }
        guard !isLoadingAppIDs else {
            errorMessage = "Wait for Apple App IDs to finish loading before installing."
            return
        }
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
            installOperationLease = try DeviceOperationCoordinator.acquire()
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
            installCancellationRequested = false
            overallProgress = 0
            stageProgress = [:]
            currentStage = "Starting"
            installStartedAt = Date()
            appendActivity("Starting install on \(selectedDevice.name) via \(selectedDevice.connectionType)")
            Task { await consumeInstall(request, ipa: ipa) }
        } catch {
            installOperationLease?.release()
            installOperationLease = nil
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
        let account = request.email
        let device = request.device
        let options = request.options
        defer {
            installOperationLease?.release()
            installOperationLease = nil
            isInstalling = false
            installCancellationRequested = false
        }
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
                            account: account,
                            device: device,
                            options: options,
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
            if installCancellationRequested {
                currentStage = "Cancelled"
                appendActivity("Installation cancelled")
            }
        } catch {
            showTwoFactor = false
            showCertificates = false
            if installCancellationRequested {
                currentStage = "Cancelled"
                appendActivity("Installation cancelled")
            } else {
                if errorMessage == nil { errorMessage = friendlyMessage(for: error) }
                if let errorMessage { appendActivity("Error: \(errorMessage)") }
                appendActivity("Installation stopped")
            }
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
            let validated = serials?.filter { !$0.isEmpty }
            try core.submitCertificates(validated?.isEmpty == false ? validated : nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelInstall() {
        installCancellationRequested = true
        core.cancel()
        currentStage = "Cancelling"
        appendActivity("Cancelling installation")
    }

    func reloadManagedInstallations() {
        managedInstallations = AutoRefreshStore.load().sorted {
            $0.nextRefreshAt < $1.nextRefreshAt
        }
    }

    func setAutoRefreshEnabled(_ enabled: Bool, for id: String) {
        do {
            try AutoRefreshStore.mutate { installations in
                guard let index = installations.firstIndex(where: { $0.id == id }) else { return }
                installations[index].enabled = enabled
                installations[index].status = enabled ? "Scheduled" : "Paused"
                installations[index].lastError = nil
            }
            reloadManagedInstallations()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func forgetManagedInstallation(_ id: String) {
        do {
            try AutoRefreshStore.mutate { installations in
                installations.removeAll { $0.id == id }
            }
            reloadManagedInstallations()
            appendActivity("Removed an Auto Refresh schedule")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshManagedInstallationNow(_ id: String) {
        guard !isInstalling && !isUninstallingApps else {
            errorMessage = "Wait for the current iPhone operation to finish before refreshing."
            return
        }
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
            } else {
                appendActivity("Auto Refresh could not start because another iPhone operation is running")
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

    private func removeRefreshRecipes(for bundleIDs: Set<String>, deviceUDID: String) {
        do {
            var removed = false
            try AutoRefreshStore.mutate { installations in
                let originalCount = installations.count
                installations.removeAll {
                    $0.deviceUDID == deviceUDID && bundleIDs.contains($0.bundleId)
                }
                removed = installations.count != originalCount
            }
            guard removed else { return }
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
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: previewDirectory.path
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
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
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
