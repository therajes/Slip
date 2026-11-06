import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [DeviceInfo] = []
    @Published var selectedDevice: DeviceInfo? {
        didSet { deviceSelectionDidChange(from: oldValue); scheduleWorkspacePersistence() }
    }
    var desiredWorkspaceDeviceUDID: String?
    @Published var ipa: IpaInfo? { didSet { scheduleWorkspacePersistence() } }
    @Published var ipaIconURL: URL?
    @Published var customName = "" { didSet { if customName != oldValue { scheduleWorkspacePersistence() } } }
    @Published var customBundleID = "" { didSet { if customBundleID != oldValue { scheduleWorkspacePersistence() } } }
    @Published var customIconURL: URL? { didSet { if customIconURL != oldValue { scheduleWorkspacePersistence() } } }
    @Published var removedExtensions: Set<String> = [] { didSet { if removedExtensions != oldValue { scheduleWorkspacePersistence() } } }
    @Published var increasedMemoryLimit = false { didSet { if increasedMemoryLimit != oldValue { scheduleWorkspacePersistence() } } }
    @Published var minimumOSVersion = "" { didSet { if minimumOSVersion != oldValue { scheduleWorkspacePersistence() } } }
    @Published var removeSupportedDevices = false { didSet { if removeSupportedDevices != oldValue { scheduleWorkspacePersistence() } } }
    @Published var enableFileSharing = false { didSet { if enableFileSharing != oldValue { scheduleWorkspacePersistence() } } }
    @Published var plistOverrides: [PlistOverride] = [] { didSet { if plistOverrides != oldValue { scheduleWorkspacePersistence() } } }
    @Published var keepAutomaticallyRefreshed = true { didSet { if keepAutomaticallyRefreshed != oldValue { scheduleWorkspacePersistence() } } }
    @Published var accounts: [String] = []
    @Published var accountProfiles: [String: AccountProfile] = [:]
    @Published var selectedAccount = "" { didSet { if selectedAccount != oldValue { scheduleWorkspacePersistence() } } }
    @Published var isRefreshing = false
    @Published var isInspecting = false
    @Published var isInstalling = false
    @Published var isEnablingWiFi = false
    @Published var isExporting = false
    @Published var isDownloading = false
    let operationProgress = OperationProgress()
    var downloadProgress: IPADownloadProgress? {
        get { operationProgress.download }
        set { operationProgress.download = newValue }
    }
    var currentStage: String {
        get { operationProgress.stage }
        set { if newValue != operationProgress.stage { operationProgress.stage = newValue } }
    }
    var overallProgress: Double {
        get { operationProgress.fraction }
        set { if newValue != operationProgress.fraction { operationProgress.fraction = newValue } }
    }
    @Published var activity: [String] = []
    @Published var errorMessage: String?
    @Published var showTwoFactor = false
    @Published var twoFactorDetails: TwoFactorDetails?
    @Published var verificationCode = ""
    @Published var authentication = AuthenticationFlow()
    @Published var isSubmittingTwoFactor = false
    @Published var twoFactorError: String?
    @Published var twoFactorStatus = ""
    @Published var certificates: [CertificateInfo] = []
    @Published var showCertificates = false
    @Published var showAppIDExhausted = false
    @Published var managedInstallations: [ManagedInstallation] = []
    @Published var managedInstallationsError: String?
    @Published var installedApps: [InstalledAppInfo] = []
    @Published var isLoadingInstalledApps = false
    var inventoryGeneration = UUID()
    @Published var installedAppsDeviceUDID: String?
    @Published var isUninstallingApps = false
    @Published var inspectionDuration: TimeInterval?
    @Published var ipaPreparationNotice: String?
    @Published var lastInstallDuration: TimeInterval?
    @Published var refreshingManagedIDs: Set<String> = []
    @Published var activeRefreshID: String?
    private var refreshQueueCancelled = false
    @Published var hideSensitiveInfo = UserDefaults.standard.bool(forKey: "hideSensitiveInfo") {
        didSet { UserDefaults.standard.set(hideSensitiveInfo, forKey: "hideSensitiveInfo") }
    }

    @Published var accountCertificates: [CertificateInfo] = []
    @Published var accountAppIDs: [AppleAppID] = []
    @Published var appIDQuota: AppIDQuotaInfo?
    @Published var certificateRevocationNotice: String?
    @Published var resourcesTeamID: String?
    @Published var resourcesAccount = ""
    @Published var isManagingAccount = false
    @Published var resourcesError: String?
    @Published var resourcesLoaded = false
    @Published var resourcesUpdatedAt: Date?
    @Published var hostIdentity: HostIdentityInfo?
    @Published var isLoadingHostIdentity = false
    @Published var hostIdentityError: String?
    @Published var authenticationNotice: String?
    private var operationCancelled = false
    private var inspectionGeneration = UUID()
    @Published var library = AppLibraryState()
    @Published var libraryNotice: String?
    @Published var isImportingLibrary = false
    @Published var isRestoringWorkspace = false
    @Published var isRunningInstallQueue = false
    @Published var activeQueueID: UUID?
    @Published var reviewingQueueID: UUID?
    var queueCancelled = false
    var activeLibraryID: UUID?
    var activeSourceStamp: IPAFileStamp?
    let libraryRepository: AppLibraryRepository?
    let libraryManagementStore: LibraryManagementStore?
    var workspaceSaveTask: Task<Void, Never>?
    var libraryWriteTask: Task<Void, Never>?
    var libraryDiskWriter: LibraryDiskWriter?
    var lastSubmittedLibrary: AppLibraryState?
    var libraryRevision: UInt64 = 0
    var pendingLibraryWrites = 0
    var librarySaveFailed = false
    var deviceMonitor: DeviceConnectionMonitor?

    var isAuthenticating: Bool { isLoggingIn || isInstalling || isManagingAccount }
    var showInlineTwoFactor: Bool { authentication.showsChallenge }
    var canRespondToTwoFactor: Bool {
        isLoggingIn ? authentication.canRespondToChallenge : (showTwoFactor && !isSubmittingTwoFactor)
    }
    var canSubmitTwoFactor: Bool {
        canRespondToTwoFactor && twoFactorDetails?.unknown != true
    }

    @Published var isLoggingIn = false
    @Published var loginStage = ""

    let core: CoreClient
    @Published var pausedDownload: PausedIPADownload?
    @Published var pauseQueueAfterCurrent = false
    private let downloadControl = IPADownloadControl()
    var downloadTask: Task<URL, Error>?
    var downloadGeneration: UUID?
    @Published var authenticationMode = UserDefaults.standard.string(forKey: "authenticationMode") ?? "local" {
        didSet { UserDefaults.standard.set(authenticationMode, forKey: "authenticationMode") }
    }
    @Published var anisetteServer = UserDefaults.standard.string(forKey: "anisetteServer") ?? "" {
        didSet { UserDefaults.standard.set(anisetteServer, forKey: "anisetteServer") }
    }
    private var stageProgress: [String: Double] = [:]
    private var installStartedAt: Date?
    private var activeOperationHandle: OperationCoordinator.OperationHandle?

    var currentlyRefreshingAppName: String? {
        if let local = activeRefreshID ?? managedInstallations.first(where: { refreshingManagedIDs.contains($0.id) })?.id {
            if let match = managedInstallations.first(where: { $0.id == local }) {
                return match.appName
            }
            return "an app"
        }
        return OperationCoordinator.currentlyRefreshingAppName()
    }

    init(startupTasks: Bool = true, core: CoreClient = CoreClient(), loadSavedState: Bool = true,
         libraryRepository: AppLibraryRepository? = nil) {
        self.core = core
        let repository = libraryRepository ?? (loadSavedState && startupTasks ? .standard : nil)
        self.libraryRepository = repository
        self.libraryManagementStore = repository.map {
            $0.fileURL == AppLibraryRepository.standard.fileURL ? .shared : LibraryManagementStore(root: $0.fileURL.deletingLastPathComponent().deletingLastPathComponent())
        }
        if loadSavedState { reloadAccounts(); reloadManagedInstallations() }
        if let repository = self.libraryRepository {
            do { library = try repository.load() }
            catch { libraryNotice = "Slip couldn’t read your library. The saved file has been preserved." }
            lastSubmittedLibrary = library
            libraryDiskWriter = LibraryDiskWriter(repository: repository, initialState: library)
            library.recoverInterruptedQueue()
        }
        if startupTasks {
            do {
                try AutoRefreshScheduler.installIfAppropriate()
            } catch {
                appendActivity("Auto Refresh scheduler: \(error.localizedDescription)")
            }
            Task { [self] in
                if ipa == nil, !isInspecting, let id = library.activeID { await openLibraryWorkspace(id) }
                await refreshDevices()
                deviceMonitor = DeviceConnectionMonitor { [weak self] in
                    guard let self, !self.workspaceIsBusy else { return }
                    await self.refreshDevices(quiet: true)
                }
            }
        }
    }

    private func recordAuthenticationWarning(_ event: CoreEvent) {
        let message = event.message ?? "Signed in, but the developer session could not be saved. Apple may ask you to sign in again next time."
        if authenticationNotice != message { appendActivity(message) }
        authenticationNotice = message
    }

    func loadHostIdentity() async {
        guard !isLoadingHostIdentity else { return }
        isLoadingHostIdentity = true
        hostIdentityError = nil
        defer { isLoadingHostIdentity = false }
        do {
            let event = try await core.run(["host-identity"])
            guard event.type == "hostIdentity", let identity = event.hostIdentity else {
                throw SideloomError.message("Slip could not read this Mac's identity. Try refreshing.")
            }
            hostIdentity = identity
        } catch {
            hostIdentity = nil
            hostIdentityError = error.localizedDescription
        }
    }

    func reloadAccounts() {
        accounts = KeychainStore.accounts()
        accountProfiles = AccountProfileStore.load(for: accounts)
        let preferred = UserDefaults.standard.string(forKey: "selectedAccount") ?? ""
        selectedAccount = accounts.contains(preferred) ? preferred : (accounts.first ?? "")
    }

    @discardableResult
    func signInAccount(email: String, password: String, profileName: String = "", profileImageURL: URL? = nil) async -> Bool {
        // The first action claims the operation synchronously before starting any async work.
        guard !workspaceIsBusy else { return false }
        operationCancelled = false
        authenticationNotice = nil
        errorMessage = nil
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        authentication.begin(accountEmail: normalized)
        guard normalized.contains("@"), !password.isEmpty else {
            authentication.fail(message: "Enter your Apple Account email and password.")
            return false
        }
        isLoggingIn = true
        showTwoFactor = false
        twoFactorDetails = nil
        twoFactorError = nil
        isSubmittingTwoFactor = false
        verificationCode = ""
        loginStage = authentication.message
        defer {
            isLoggingIn = false
            showTwoFactor = false
            verificationCode = ""
            isSubmittingTwoFactor = false
        }

        do {
            let storageURL = try accountStorageURL(for: normalized)
            let request = LoginAccountRequest(
                email: normalized,
                password: password,
                anisetteServer: anisetteServer,
                storagePath: storageURL.path,
                authenticationMode: authenticationMode
            )
            let stream = try core.loginStream(request: request)
            var verifiedProfileName = profileName

            for try await event in stream {
                if operationCancelled { return false }
                switch event.type {
                case "authenticationState":
                    receiveAuthenticationState(event)
                case "authenticationWarning":
                    recordAuthenticationWarning(event)
                case "progress":
                    authentication.updateMessage(event.message ?? "Signing in to Apple…")
                    loginStage = authentication.message
                case "twoFactorRequired":
                    receiveTwoFactorChallenge(event.details)
                    authentication.receiveChallenge(event.details)
                    loginStage = authentication.message
                    appendActivity("Apple requested a verification code")
                case "accountProfile":
                    if let name = event.accountName, !name.isEmpty { verifiedProfileName = name }
                case "completed":
                    try KeychainStore.save(account: normalized, password: password)
                    try AccountProfileStore.upsert(email: normalized, displayName: verifiedProfileName, imageURL: profileImageURL)
                    reloadAccounts()
                    selectedAccount = normalized
                    UserDefaults.standard.set(normalized, forKey: "selectedAccount")
                    authentication.complete()
                    loginStage = authentication.message
                    appendActivity("Signed in and saved the Apple Account to macOS Keychain")
                    return true
                case "error":
                    verificationCode = ""
                    let raw = event.message ?? "Apple sign-in could not finish."
                    if raw.contains("1100") || raw.lowercased().contains("session has expired") || raw.lowercased().contains("session expired") {
                        clearDeveloperSession(for: normalized)
                    }
                    let message = friendlyMessage(raw)
                    authentication.fail(message: message, code: event.code, retryable: event.retryable, failedStage: event.failedStage ?? event.stage)
                    loginStage = authentication.message
                    appendActivity("Sign-in failed: \(message)")
                    return false
                default: break
                }
            }
            if operationCancelled { return false }
            let message = authentication.errorMessage ?? "Apple sign-in ended before the developer session was ready. Try signing in again."
            authentication.fail(message: message, retryable: true)
            appendActivity("Sign-in incomplete: \(message)")
            return false
        } catch {
            if operationCancelled { return false }
            let message = authentication.errorMessage ?? friendlyMessage(for: error)
            authentication.fail(message: message)
            appendActivity("Sign-in error: \(message)")
            return false
        }
    }

    private func receiveAuthenticationState(_ event: CoreEvent) {
        if isLoggingIn {
            authentication.receiveState(stage: event.stage, message: event.message, provider: event.provider,
                                        code: event.code, retryable: event.retryable, failedStage: event.failedStage)
            loginStage = authentication.message
        }
        if showTwoFactor, let message = event.message { twoFactorStatus = message }
        switch event.stage {
        case "verifyingCode": isSubmittingTwoFactor = true
        case "signedIn":
            if !isLoggingIn { showTwoFactor = false }
            isSubmittingTwoFactor = false
        default: break
        }
    }

    private func receiveTwoFactorChallenge(_ details: TwoFactorDetails?) {
        twoFactorDetails = details
        twoFactorError = details?.lastError
        isSubmittingTwoFactor = false
        verificationCode = ""
        showTwoFactor = true
    }

    func deleteAccount(_ email: String) {
        guard !workspaceIsBusy else {
            errorMessage = "Wait for the current Apple Account operation before removing an account."
            return
        }
        resourcesLoaded = false
        resourcesUpdatedAt = nil
        accountCertificates = []
        accountAppIDs = []
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        do {
            clearDeveloperSession(for: email)
            try KeychainStore.delete(account: email)
            try? AccountProfileStore.delete(email)
            try? AccountProfileStore.delete(normalized)

            // Completely wipe cached session tokens, anisette state, and developer keys in Core
            let fileManager = FileManager.default
            if let storageURL = try? accountStorageURL(for: normalized) {
                try? fileManager.removeItem(at: storageURL)
            }
            let normalizedForStorage = normalized.replacingOccurrences(of: "@", with: "_at_").replacingOccurrences(of: ".", with: "_")
            if let support = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ).appending(path: "app.sideloom.native/Core/\(normalizedForStorage)", directoryHint: .isDirectory) {
                try? fileManager.removeItem(at: support)
            }

            // Remove any auto-refresh schedules belonging to this account so background workers don't repeatedly fail
            try? AutoRefreshStore.update { installations in
                installations.removeAll { $0.account.caseInsensitiveCompare(normalized) == .orderedSame }
            }
            reloadManagedInstallations()

            reloadAccounts()
            if selectedAccount.caseInsensitiveCompare(normalized) == .orderedSame {
                selectedAccount = accounts.first ?? ""
                UserDefaults.standard.set(selectedAccount, forKey: "selectedAccount")
            }
            appendActivity("Removed \(email) from macOS Keychain and cleared cached session data")
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }


    func chooseAccount(_ email: String) {
        guard !isAuthenticating else { return }
        appIDQuota = nil
        certificateRevocationNotice = nil
        accountCertificates = []
        accountAppIDs = []
        resourcesLoaded = false
        resourcesUpdatedAt = nil
        resourcesError = nil
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

    func manageAccount(command: String = "account-resources", serialNumber: String? = nil,
                       serialNumbers: [String]? = nil, expectedSerialNumbers: [String]? = nil, appIdId: String? = nil) async {
        guard !workspaceIsBusy, !selectedAccount.isEmpty else { return }
        let email = selectedAccount
        isManagingAccount = true
        authentication = AuthenticationFlow()
        certificateRevocationNotice = nil
        appIDQuota = nil
        resourcesLoaded = false
        accountCertificates = []
        accountAppIDs = []
        operationCancelled = false
        authenticationNotice = nil
        resourcesError = nil
        errorMessage = nil
        defer {
            isManagingAccount = false
            showTwoFactor = false
            verificationCode = ""
            isSubmittingTwoFactor = false
            twoFactorError = nil
        }
        do {
            let request = AccountResourcesRequest(
                email: email,
                password: try KeychainStore.password(for: email),
                anisetteServer: anisetteServer,
                storagePath: try accountStorageURL(for: email).path,
                serialNumber: serialNumber,
                serialNumbers: serialNumbers,
                expectedSerialNumbers: expectedSerialNumbers,
                appIdId: appIdId,
                authenticationMode: authenticationMode
            )
            let commands = command == "account-resources" ? [command] : [command, "account-resources"]
            for action in commands {
                var completed = false
                var loadedResources: CoreEvent?
                let stream = try core.authenticatedStream(command: action, request: request)
                for try await event in stream {
                    if operationCancelled { return }
                    switch event.type {
                    case "authenticationState":
                        receiveAuthenticationState(event)
                    case "authenticationWarning":
                        recordAuthenticationWarning(event)
                    case "twoFactorRequired":
                        receiveTwoFactorChallenge(event.details)
                    case "accountResources":
                        loadedResources = event
                    case "appIdQuota":
                        recordAppIDQuota(event)
                    case "certificateRevocationResult":
                        let message = event.message ?? "Some certificates could not be revoked. Refresh the list to review the result."
                        certificateRevocationNotice = message
                        appendActivity(message)
                    case "completed":
                        completed = true
                        showTwoFactor = false
                        if action == "revoke-certificates", let count = event.revokedCount {
                            let message = event.message ?? "Revoked \(count) development certificate\(count == 1 ? "" : "s")."
                            certificateRevocationNotice = message
                            appendActivity(message)
                        }
                    case "error":
                        throw SideloomError.message(event.message ?? "Apple could not complete this account operation.")
                    default: break
                    }
                }
                if operationCancelled { return }
                guard completed else { throw SideloomError.message("Apple did not complete the account operation. Refresh and try again.") }
                if action == "account-resources" {
                    guard let event = loadedResources else {
                        throw SideloomError.message("Apple returned no certificate or App ID list. Refresh to try again.")
                    }
                    resourcesAccount = email
                    resourcesTeamID = event.teamId
                    accountCertificates = event.certificates ?? []
                    accountAppIDs = event.appIds ?? []
                    resourcesLoaded = true
                    resourcesUpdatedAt = Date()
                }
                appendActivity("Apple Account operation completed: \(action)")
            }
        } catch {
            if operationCancelled { return }
            let message = friendlyMessage(for: error)
            resourcesError = message
            errorMessage = message
            appendActivity("Account resources: \(message)")
        }
    }

    func revokeAccountCertificates(_ plan: CertificateRevocationPlan, for account: String) async {
        guard !workspaceIsBusy else { return }
        guard selectedAccount == account, resourcesAccount == account, resourcesLoaded,
              CertificateRevocationPlan.availableSerialNumbers(in: accountCertificates) == plan.expectedSerialNumbers else {
            resourcesError = "The account or certificate list changed. Refresh and review the certificates before revoking them."
            return
        }
        await manageAccount(command: "revoke-certificates", serialNumbers: plan.serialNumbers,
                            expectedSerialNumbers: plan.expectedSerialNumbers)
        // A batch can partially succeed. Fetch Apple's current list without repeating
        // the destructive request, then preserve its result for the user to review.
        if let failure = resourcesError, !operationCancelled {
            let notice = certificateRevocationNotice
            await manageAccount()
            resourcesError = failure
            certificateRevocationNotice = notice
            errorMessage = failure
        }
    }

    private func recordAppIDQuota(_ event: CoreEvent) {
        appIDQuota = AppIDQuotaInfo(used: event.used.flatMap { $0 >= 0 ? $0 : nil },
                                   remaining: event.remaining.flatMap { $0 >= 0 ? $0 : nil },
                                   limit: event.limit.flatMap { $0 > 0 ? $0 : nil }, message: event.message)
        if let message = event.message { appendActivity(message) }
    }

    func refreshDevices(quiet: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let event = try await core.run(["devices"])
            let discovered = event.devices ?? []
            if devices != discovered { devices = discovered }
            let selection: DeviceInfo?
            if let current = selectedDevice,
               let replacement = devices.first(where: { $0.identity == current.identity }) {
                selection = replacement
            } else {
                if let desiredWorkspaceDeviceUDID {
                    selection = devices.first(where: { $0.udid == desiredWorkspaceDeviceUDID && $0.connectionType == "USB" })
                        ?? devices.first(where: { $0.udid == desiredWorkspaceDeviceUDID })
                } else {
                    selection = devices.first(where: { $0.connectionType.caseInsensitiveCompare("USB") == .orderedSame }) ?? devices.first
                }
            }
            if selectedDevice != selection { selectedDevice = selection }
            if !quiet, let errors = event.errors, !errors.isEmpty {
                appendActivity(errors.joined(separator: " • "))
            }
        } catch {
            // A transient discovery failure is not evidence of disconnection.
            if !quiet { errorMessage = error.localizedDescription }
        }
    }

    @discardableResult
    func loadIPA(_ url: URL, downloadID: UUID? = nil, expectedBundleID: String? = nil, queueID: UUID? = nil, historyWorkspaceID: UUID? = nil) async -> Bool {
        guard !isInstalling, !isExporting, !isDownloading || downloadID == downloadGeneration,
              !isRunningInstallQueue || (queueID != nil && queueID == activeQueueID) else {
            errorMessage = "Wait for the current IPA operation or cancel its download first."
            return false
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.pathExtension.lowercased() == "ipa" else {
            errorMessage = "Choose a valid .ipa file."
            return false
        }
        persistWorkspace()
        let generation = UUID()
        inspectionGeneration = generation
        isInspecting = true
        errorMessage = nil
        let started = Date()
        defer { if inspectionGeneration == generation { isInspecting = false } }
        do {
            let event = try await core.run(["inspect", resolved.path])
            guard inspectionGeneration == generation, !Task.isCancelled,
                  downloadID == nil || downloadID == downloadGeneration else { return false }
            guard let info = event.ipa else { throw SideloomError.message("The IPA could not be inspected.") }
            if let expectedBundleID, info.bundleId != expectedBundleID {
                throw SideloomError.message("This IPA belongs to \(info.appName), not the app being recovered. Choose the original app’s IPA.")
            }
            // Commit only a validated archive; a failed replacement keeps the
            // previous IPA, icon and all of the user's customization choices.
            discardIPAPreview()
            ipa = info
            activeLibraryID = historyWorkspaceID ?? library.apps.first(where: { $0.ipa.path == info.path })?.id ?? UUID()
            if let id = activeLibraryID, let store = libraryManagementStore {
                Task { try? await store.record(workspaceID: id, ipa: info, installed: false) }
            }
            activeSourceStamp = IPAFileStamp.read(info.path)
            reviewingQueueID = nil
            resetCustomizations()
            ipaPreparationNotice = nil
            inspectionDuration = Date().timeIntervalSince(started)
            currentStage = "Ready"
            appendActivity("Loaded \(info.appName) \(info.version) in \(inspectionDuration?.formatted(.number.precision(.fractionLength(2))) ?? "0")s")
            Task { await loadIPAPreview(for: info, generation: generation) }
            return true
        } catch {
            guard inspectionGeneration == generation, !Task.isCancelled,
                  downloadID == nil || downloadID == downloadGeneration else { return false }
            errorMessage = friendlyMessage(for: error)
            currentStage = "Import failed"
            return false
        }
    }

    func downloadIPA(from input: String) async {
        guard !workspaceIsBusy else {
            errorMessage = "Wait for the current IPA operation to finish."
            return
        }
        guard let url = IPADownloadPolicy.url(input) else {
            errorMessage = IPADownloadError.invalidURL.localizedDescription
            return
        }
        let resume = pausedDownload.flatMap { $0.url == url ? $0 : nil }
        pausedDownload = nil
        let control = downloadControl
        let generation = UUID()
        downloadGeneration = generation
        isDownloading = true
        downloadProgress = IPADownloadProgress()
        currentStage = "Downloading IPA"
        errorMessage = nil
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "app.sideloom.native/Imports", directoryHint: .isDirectory)
        let task = Task { [weak self] in
            try await IPAURLDownloadService().download(url, to: directory, control: control, resume: resume) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadGeneration == generation else { return }
                    self.downloadProgress = progress
                }
            }
        }
        downloadTask = task
        defer {
            if downloadGeneration == generation {
                isDownloading = false
                downloadProgress = nil
                downloadTask = nil
                downloadGeneration = nil
            }
        }
        do {
            let destination = try await task.value
            guard downloadGeneration == generation else {
                try? FileManager.default.removeItem(at: destination)
                return
            }
            currentStage = "Checking downloaded IPA"
            let loaded = await loadIPA(destination, downloadID: generation)
            if loaded { appendActivity("Downloaded and verified IPA") }
            else if ipa?.path != destination.path { try? FileManager.default.removeItem(at: destination) }
        } catch {
            guard downloadGeneration == generation else { return }
            if let paused = error as? PausedIPADownload {
                pausedDownload = paused
                currentStage = "Download paused"
                appendActivity("Download paused. The partial IPA is preserved until you resume or cancel.")
            } else if error is CancellationError || (error as? URLError)?.code == .cancelled {
                currentStage = "Download cancelled"
            } else {
                if let resume { pausedDownload = resume }
                currentStage = "Download failed"
                errorMessage = (error as? SideloomError)?.localizedDescription ?? IPADownloadPolicy.message(error)
                appendActivity("IPA download failed: \(errorMessage ?? "Connection failed")")
            }
        }
    }

    func pauseDownload() { downloadControl.pause() }

    func resumeDownload() async {
        guard let pausedDownload else { return }
        await downloadIPA(from: pausedDownload.url.absoluteString)
    }

    func cancelDownload() {
        if pausedDownload != nil { pausedDownload = nil; currentStage = "Download cancelled" }
        guard isDownloading else { return }
        downloadGeneration = nil
        downloadTask?.cancel()
        downloadTask = nil
        downloadProgress = nil
        isDownloading = false
        inspectionGeneration = UUID()
        isInspecting = false
        currentStage = "Download cancelled"
        appendActivity("IPA download cancelled")
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
        guard !isLoadingInstalledApps, !isUninstallingApps else { return }
        guard let device = selectedDevice else {
            installedApps = []
            return
        }
        isLoadingInstalledApps = true
        let generation = UUID()
        inventoryGeneration = generation
        defer { if inventoryGeneration == generation { isLoadingInstalledApps = false } }
        do {
            let event = try await core.run(["apps"], input: device)
            guard inventoryGeneration == generation, selectedDevice?.udid == device.udid else { return }
            installedAppsDeviceUDID = device.udid
            installedApps = event.apps ?? []
            appendActivity("Loaded \(installedApps.count) user apps from \(device.name)")
        } catch {
            guard inventoryGeneration == generation, selectedDevice?.udid == device.udid else { return }
            installedApps = []
            installedAppsDeviceUDID = nil
            errorMessage = error.localizedDescription
        }
    }

    func copyBundleIDs(_ bundleIDs: Set<String>) {
        guard !bundleIDs.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bundleIDs.sorted().joined(separator: "\n"), forType: .string)
        appendActivity("Copied \(bundleIDs.count) bundle ID\(bundleIDs.count == 1 ? "" : "s")")
    }

    func refreshManagedInstallations(_ ids: Set<String>, respectPaused: Bool = false) {
        guard !workspaceIsBusy, refreshingManagedIDs.isEmpty else {
            errorMessage = "Finish the current operation before refreshing apps."
            return
        }
        let queued = managedInstallations.filter { ids.contains($0.id) }.map(\.id)
        guard !queued.isEmpty else { return }
        refreshQueueCancelled = false
        refreshingManagedIDs = Set(queued)
        Task {
            var completed = 0
            for id in queued {
                guard !refreshQueueCancelled else { break }
                guard let latest = AutoRefreshStore.load().first(where: { $0.id == id }),
                      !respectPaused || latest.enabled else { refreshingManagedIDs.remove(id); continue }
                if await performManagedRefresh(id) { completed += 1 }
                else { break } // A failure or cancellation must not repeat sign-in across the queue.
            }
            refreshingManagedIDs.removeAll()
            activeRefreshID = nil
            reloadManagedInstallations()
            appendActivity("Refresh finished: \(completed) of \(queued.count) renewed")
        }
    }

    private func performManagedRefresh(_ id: String) async -> Bool {
        guard let item = AutoRefreshStore.load().first(where: { $0.id == id }),
              let handle = OperationCoordinator.beginOperation(type: .refresh, appName: item.appName, bundleId: item.bundleId) else {
            errorMessage = "Slip is busy with another installation or renewal. Try again when it finishes."
            return false
        }
        activeOperationHandle = handle
        activeRefreshID = id
        operationCancelled = false
        isInstalling = true
        currentStage = "Checking \(item.appName)"
        errorMessage = nil
        authenticationNotice = nil
        authentication = AuthenticationFlow()
        installStartedAt = Date()
        overallProgress = 0
        stageProgress = [:]
        defer {
            handle.end()
            activeOperationHandle = nil
            activeRefreshID = nil
            isInstalling = false
            refreshingManagedIDs.remove(id)
        }
        do {
            guard FileManager.default.fileExists(atPath: item.ipaPath) else {
                throw SideloomError.message("The saved IPA is missing. Choose a replacement IPA in Auto Refresh.")
            }
            let inspection = try await core.run(["inspect", item.ipaPath])
            guard !operationCancelled else { return false }
            guard let info = inspection.ipa, info.encryptionStatus != "Encrypted" else {
                throw SideloomError.message("Choose a valid decrypted IPA before renewing this app.")
            }
            guard item.options.bundleId != nil || info.bundleId == item.bundleId else {
                throw SideloomError.message("The saved IPA belongs to another app. Choose the correct IPA before renewing.")
            }
            let discovery = try await core.run(["devices"])
            guard !operationCancelled else { return false }
            guard let device = discovery.devices?.filter({ $0.udid == item.deviceUDID })
                .sorted(by: { $0.connectionType == "USB" && $1.connectionType != "USB" }).first else {
                throw SideloomError.message("Connect \(item.deviceName), unlock it, then refresh again.")
            }
            let request = InstallRequest(email: item.account, password: try KeychainStore.password(for: item.account),
                                         anisetteServer: anisetteServer, storagePath: try accountStorageURL(for: item.account).path,
                                         device: device, options: item.options, authenticationMode: authenticationMode)
            appendActivity("Renewing \(item.appName) on \(device.displayName)")
            await consumeInstall(request, ipa: info, renewing: item)
            return currentStage == "Installed"
        } catch {
            if !operationCancelled { errorMessage = friendlyMessage(for: error); currentStage = "Refresh needs attention" }
            var updated = item
            updated.status = "Needs attention"
            updated.lastError = errorMessage ?? "Refresh cancelled."
            updated.lastAttemptAt = Date()
            updated.nextRefreshAt = Date().addingTimeInterval(30 * 60)
            try? AutoRefreshStore.mergeOutcome(updated, original: item)
            return false
        }
    }

    @discardableResult
    func uninstallApps(bundleIDs: Set<String>, expectedDeviceUDID: String? = nil) async -> Set<String> {
        guard !workspaceIsBusy, !isUninstallingApps, let device = selectedDevice, !bundleIDs.isEmpty,
              inventoryMatchesSelectedDevice, expectedDeviceUDID == nil || expectedDeviceUDID == device.udid else { return [] }
        isUninstallingApps = true
        defer { isUninstallingApps = false }
        do {
            let request = UninstallAppsRequest(device: device, bundleIds: bundleIDs.sorted())
            let event = try await core.run(["uninstall"], input: request)
            let removed = Set(event.bundleIds ?? [])
            if selectedDevice?.udid == device.udid, installedAppsDeviceUDID == device.udid {
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
        guard !isRunningInstallQueue, !isImportingLibrary, !isRestoringWorkspace else { return }
        Task { _ = await installCurrentWorkspace() }
    }

    @discardableResult
    func installCurrentWorkspace() async -> Bool {
        guard !isAuthenticating, !isInspecting, !isDownloading, !isExporting else {
            errorMessage = "Wait for the current operation to finish before installing."
            return false
        }
        operationCancelled = false
        authenticationNotice = nil
        errorMessage = nil
        if let refreshingName = currentlyRefreshingAppName {
            errorMessage = "An app is already refreshing (\(refreshingName)). Please wait for it to finish before installing a new app."
            appendActivity("Installation blocked: \(refreshingName) is currently refreshing")
            return false
        }
        guard let ipa, let selectedDevice else {
            errorMessage = ipa == nil ? "Choose an IPA first." : "Connect and select an iPhone."
            return false
        }
        guard !selectedAccount.isEmpty else {
            errorMessage = "Add an Apple Account in Keychain first."
            return false
        }
        if let issue = blockingInstallIssue {
            errorMessage = "\(issue.title). \(issue.detail)"
            return false
        }

        guard let opHandle = OperationCoordinator.beginOperation(
            type: .install,
            appName: ipa.appName,
            bundleId: ipa.bundleId
        ) else {
            let name = OperationCoordinator.currentlyRefreshingAppName() ?? "Another operation"
            errorMessage = "\(name) is currently in progress. Please wait for it to finish before installing a new app."
            return false
        }
        activeOperationHandle = opHandle

        do {
            let password = try KeychainStore.password(for: selectedAccount)
            let storageURL = try accountStorageURL(for: selectedAccount)
            let options = installOptions(for: ipa)
            let request = InstallRequest(
                email: selectedAccount,
                password: password,
                anisetteServer: anisetteServer,
                storagePath: storageURL.path,
                device: selectedDevice,
                options: options,
                authenticationMode: authenticationMode
            )
            isInstalling = true
            authentication = AuthenticationFlow()
            overallProgress = 0
            stageProgress = [:]
            currentStage = "Starting"
            installStartedAt = Date()
            appendActivity("Starting install on \(selectedDevice.name) via \(selectedDevice.connectionType)")
            persistWorkspace()
            await consumeInstall(request, ipa: ipa)
            return currentStage == "Installed"
        } catch {
            activeOperationHandle?.end()
            activeOperationHandle = nil
            errorMessage = friendlyMessage(for: error)
            return false
        }
    }

    func exportModifiedIPA(to destination: URL) {
        guard !workspaceIsBusy else {
            errorMessage = "Wait for the current IPA operation to finish before exporting."
            return
        }
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
        guard !isInstalling, !isExporting, !isRunningInstallQueue, !isImportingLibrary, !isRestoringWorkspace else { return }
        cancelDownload()
        inspectionGeneration = UUID()
        isInspecting = false
        persistWorkspace()
        ipa = nil
        activeLibraryID = nil
        activeSourceStamp = nil
        reviewingQueueID = nil
        library.activeID = nil
        discardIPAPreview()
        inspectionDuration = nil
        ipaPreparationNotice = nil
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
        refreshManagedInstallations(ids, respectPaused: true)
    }

    func consumeInstall(_ request: InstallRequest, ipa: IpaInfo, renewing item: ManagedInstallation? = nil) async {
        var renewalCompleted = false
        defer {
            if let item, !renewalCompleted {
                var failed = item
                failed.status = operationCancelled ? "Waiting to retry" : "Needs attention"
                failed.lastError = operationCancelled ? "Refresh cancelled." : (errorMessage ?? "Open Slip to finish renewing this app.")
                failed.lastAttemptAt = Date()
                failed.nextRefreshAt = Date().addingTimeInterval(30 * 60)
                try? AutoRefreshStore.mergeOutcome(failed, original: item)
                reloadManagedInstallations()
            }
            isInstalling = false
            showTwoFactor = false
            showCertificates = false
            verificationCode = ""
            isSubmittingTwoFactor = false
            twoFactorError = nil
            activeOperationHandle?.end()
            activeOperationHandle = nil
        }
        do {
            let stream = try core.installStream(request: request)
            var completed = false
            for try await event in stream {
                if operationCancelled { return }
                switch event.type {
                case "progress":
                    updateProgress(stage: event.stage ?? "working", value: event.value ?? 0, message: event.message)
                case "authenticationState":
                    receiveAuthenticationState(event)
                case "authenticationWarning":
                    recordAuthenticationWarning(event)
                case "appIdQuota":
                    recordAppIDQuota(event)
                case "twoFactorRequired":
                    receiveTwoFactorChallenge(event.details)
                    errorMessage = nil
                    appendActivity("Apple requested a verification code")
                case "accountProfile":
                    if let email = event.email, let accountName = event.accountName {
                        try? AccountProfileStore.upsert(email: email, displayName: accountName)
                        reloadAccounts()
                    }
                case "certificateSelectionRequired":
                    certificates = event.certificates ?? []
                    guard certificates.contains(where: { $0.serialNumber?.isEmpty == false }) else {
                        core.cancel()
                        throw SideloomError.message("Apple reported a certificate limit but returned no certificates to revoke. Open Apple Accounts, refresh Certificates & App IDs, and try again.")
                    }
                    showCertificates = true
                case "completed":
                    completed = true
                    showTwoFactor = false
                    verificationCode = ""
                    overallProgress = 1
                    currentStage = "Installed"
                    if let store = libraryManagementStore {
                        let effectiveID = request.options.bundleId ?? ipa.bundleId
                        for saved in library.apps where saved.ipa.path == request.options.appPath
                            && saved.deviceUDID == request.device.udid
                            && (saved.options.bundleId ?? saved.ipa.bundleId) == effectiveID {
                            Task { try? await store.record(workspaceID: saved.id, ipa: ipa, installed: true) }
                        }
                    }
                    if let installStartedAt {
                        lastInstallDuration = Date().timeIntervalSince(installStartedAt)
                    }
                    appendActivity("Installation completed successfully\(lastInstallDuration.map { " in \($0.formatted(.number.precision(.fractionLength(1))))s" } ?? "")")
                    do {
                        if let item {
                            renewalCompleted = true
                            var refreshed = item
                            let now = Date()
                            refreshed.installedAt = now
                            refreshed.profileExpiryConfirmed = event.profileExpiresAt != nil
                            refreshed.expiresAt = event.profileExpiresAt.map { Date(timeIntervalSince1970: $0) } ?? now.addingTimeInterval(7 * 86400)
                            refreshed.nextRefreshAt = refreshed.expiresAt.addingTimeInterval(-86400)
                            refreshed.lastAttemptAt = now
                            refreshed.status = "Scheduled"
                            refreshed.lastError = nil
                            try AutoRefreshStore.mergeOutcome(refreshed, original: item)
                            reloadManagedInstallations()
                        } else {
                        let entry = try AutoRefreshStore.recordSuccessfulInstall(
                            ipa: ipa,
                            request: request,
                            enabled: keepAutomaticallyRefreshed,
                            profileExpiresAt: event.profileExpiresAt
                        )
                        reloadManagedInstallations()
                        if entry.enabled {
                            appendActivity("Auto Refresh scheduled for \(entry.nextRefreshAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                        }
                    } catch {
                        appendActivity("Could not save Auto Refresh schedule: \(error.localizedDescription)")
                    }
                case "error":
                    let raw = event.message ?? "Installation failed"
                    if raw.contains("1100") || raw.lowercased().contains("session has expired") || raw.lowercased().contains("session expired") {
                        clearDeveloperSession(for: request.email)
                    }
                    let message = friendlyMessage(raw)
                    showTwoFactor = false
                    verificationCode = ""
                    showCertificates = false
                    if raw.lowercased().contains("not enough available app ids") {
                        showAppIDExhausted = true
                        currentStage = "Install failed"
                        return
                    }
                    errorMessage = message
                    appendActivity("Error: \(message)")
                    currentStage = "Install failed"
                    return
                default:
                    break
                }
            }
            if !completed && !operationCancelled {
                throw SideloomError.message("The signing engine ended before confirming installation. Try again and check Activity for details.")
            }
        } catch {
            if operationCancelled { return }
            currentStage = "Install failed"
            showTwoFactor = false
            verificationCode = ""
            showCertificates = false
            if errorMessage == nil {
                let msg = friendlyMessage(for: error)
                if msg.lowercased().contains("not enough available app ids") || msg.lowercased().contains("app ids") {
                    showAppIDExhausted = true
                } else {
                    errorMessage = msg
                }
            }
            if let errorMessage { appendActivity("Error: \(errorMessage)") }
            appendActivity("Installation stopped")
        }
    }

    func clearDeveloperSession(for email: String? = nil) {
        let target = email ?? (selectedAccount.isEmpty ? nil : selectedAccount)
        guard let account = target,
              let url = try? accountStorageURL(for: account) else { return }
        try? KeychainStore.deleteDeveloperSession(storageURL: url)
    }

    func submitTwoFactorCode(_ code: String? = nil) {
        guard canSubmitTwoFactor else { return }
        let clean = VerificationCode.normalized(code ?? verificationCode)
        guard clean.count == 6 else {
            showTwoFactorError("Enter the six-digit verification code from Apple.")
            return
        }
        guard beginTwoFactorAction(.verifying) else { return }
        do {
            try core.submitTwoFactor(clean)
            // Keep the field visible while Apple verifies and prepares developer access.
            verificationCode = ""
        } catch { failTwoFactorAction(error) }
    }

    func submitTwoFactor(_ code: String?) {
        guard let code else { cancelInstall(); return }
        submitTwoFactorCode(code)
    }

    func selectTwoFactorMethod(numberID: UInt32? = nil) {
        guard beginTwoFactorAction(.choosingMethod) else { return }
        do {
            try core.selectTwoFactorMethod(numberID: numberID)
            verificationCode = ""
        } catch { failTwoFactorAction(error) }
    }

    func resendTwoFactor() {
        guard beginTwoFactorAction(.resending) else { return }
        do {
            try core.resendTwoFactor()
            verificationCode = ""
            appendActivity("Requested a new Apple verification code")
        } catch { failTwoFactorAction(error) }
    }

    private func beginTwoFactorAction(_ action: AuthenticationFlow.ChallengeAction) -> Bool {
        guard canRespondToTwoFactor else { return false }
        if isLoggingIn && !authentication.beginChallengeAction(action) { return false }
        isSubmittingTwoFactor = true
        twoFactorError = nil
        switch action {
        case .verifying: twoFactorStatus = "Verifying your code with Apple…"
        case .resending: twoFactorStatus = "Requesting a new code…"
        case .choosingMethod: twoFactorStatus = "Sending your verification code…"
        }
        return true
    }

    private func showTwoFactorError(_ message: String) {
        twoFactorError = message
        if isLoggingIn { authentication.showChallengeError(message) }
    }

    private func failTwoFactorAction(_ error: Error) {
        let message = friendlyMessage(for: error)
        isSubmittingTwoFactor = false
        if isLoggingIn {
            authentication.fail(message: message, retryable: true)
            core.cancel()
        } else { twoFactorError = message }
    }

    func submitCertificates(_ serials: [String]?) {
        guard let serials else { cancelInstall(); return }
        let available = Set(certificates.compactMap(\.serialNumber))
        guard !serials.isEmpty, Set(serials).isSubset(of: available) else {
            errorMessage = "Select an existing certificate to revoke."
            return
        }
        defer { showCertificates = false }
        do {
            try core.submitCertificates(serials)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelSignIn() {
        if isLoggingIn { cancelInstall() }
        else { authentication = AuthenticationFlow(); verificationCode = "" }
    }

    func cancelInstall() {
        operationCancelled = true
        if isRunningInstallQueue { queueCancelled = true }
        if activeRefreshID != nil { refreshQueueCancelled = true }
        if isLoggingIn { authentication.cancel(); loginStage = authentication.message }
        isSubmittingTwoFactor = false
        twoFactorError = nil
        showTwoFactor = false
        showCertificates = false
        showAppIDExhausted = false
        verificationCode = ""
        core.cancel()
        currentStage = "Cancelled"
        appendActivity("Apple Account operation cancelled")
    }

    func dismissAppIDExhausted() {
        showAppIDExhausted = false
        NotificationCenter.default.post(name: .showAccounts, object: nil)
    }

    func reloadManagedInstallations() {
        do {
            managedInstallations = try AutoRefreshStore.loadChecked().sorted { $0.nextRefreshAt < $1.nextRefreshAt }
            managedInstallationsError = nil
        } catch {
            managedInstallationsError = "Slip couldn’t read the renewal schedule. Your saved file has been preserved."
        }
    }

    func setAutoRefreshEnabled(_ enabled: Bool, for id: String) {
        do {
            try AutoRefreshStore.update { installations in
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
            try AutoRefreshStore.update { $0.removeAll { $0.id == id } }
            reloadManagedInstallations()
            appendActivity("Removed an Auto Refresh schedule")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshManagedInstallationNow(_ id: String) {
        refreshManagedInstallations([id])
    }

    func prepareManagedReinstall(_ id: String, from url: URL) async {
        guard let item = AutoRefreshStore.load().first(where: { $0.id == id }) else { return }
        guard await loadIPA(url, expectedBundleID: item.options.bundleId == nil ? item.bundleId : nil),
              ipa?.path == url.resolvingSymlinksInPath().path else { return }
        customName = item.options.displayName ?? ""
        customBundleID = item.options.bundleId ?? ""
        customIconURL = item.options.customIconPath.map { URL(fileURLWithPath: $0) }
        increasedMemoryLimit = item.options.increasedMemoryLimit
        minimumOSVersion = item.options.minimumOsVersion ?? ""
        removeSupportedDevices = item.options.removeSupportedDevices
        enableFileSharing = item.options.enableFileSharing
        plistOverrides = item.options.plistOverrides
        keepAutomaticallyRefreshed = item.enabled
        chooseAccount(item.account)
        if let device = devices.first(where: { $0.udid == item.deviceUDID }) { selectedDevice = device }
        ipaPreparationNotice = "Signing choices restored for \(item.appName). Review the app and extensions before installing; optional extensions start disabled."
        NotificationCenter.default.post(name: .showInstall, object: nil)
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

    func installOptions(for ipa: IpaInfo, includeUnfinishedOverrides: Bool = false) -> IpaInstallOptions {
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
            plistOverrides: includeUnfinishedOverrides ? plistOverrides : plistOverrides.filter { !$0.key.trimmed.isEmpty }
        )
    }

    private func accountStorageURL(for email: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "app.sideloom.native/Core", directoryHint: .isDirectory)
        let safe = email.lowercased().replacingOccurrences(of: "@", with: "_at_").replacingOccurrences(of: ".", with: "_")
        return base.appending(path: safe, directoryHint: .isDirectory)
    }

    private func removeRefreshRecipes(for bundleIDs: Set<String>, deviceUDID: String) {
        do {
            let removed = try AutoRefreshStore.remove(bundleIDs: bundleIDs, deviceUDID: deviceUDID)
            guard removed > 0 else { return }
            reloadManagedInstallations()
            appendActivity("Removed matching Auto Refresh schedules")
        } catch {
            errorMessage = "The apps were removed, but Slip could not remove their Auto Refresh schedules: \(error.localizedDescription)"
        }
    }

    private func loadIPAPreview(for info: IpaInfo, generation: UUID) async {
        var temporary: URL?
        do {
            let cached = try await IPAPreviewCache.shared.location(for: info)
            if !cached.exists {
                let output = cached.url.deletingLastPathComponent().appending(path: "temporary-\(UUID()).png")
                temporary = output
                _ = try await core.run(["icon", info.path, output.path])
                guard inspectionGeneration == generation, ipa?.path == info.path else {
                    await IPAPreviewCache.shared.discard(output)
                    return
                }
                try await IPAPreviewCache.shared.store(output, at: cached.url)
            }
            guard inspectionGeneration == generation, ipa?.path == info.path else { return }
            ipaIconURL = cached.url
        } catch {
            if let temporary { await IPAPreviewCache.shared.discard(temporary) }
            guard inspectionGeneration == generation, ipa?.path == info.path else { return }
            ipaIconURL = nil
            appendActivity("The IPA did not expose a usable app icon; showing a fallback.")
        }
    }

    private func discardIPAPreview() { ipaIconURL = nil }

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
        var message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        message = message.replacingOccurrences(of: "thread 'main' panicked", with: "The signing engine stopped unexpectedly")

        let lowerRaw = message.lowercased()
        if lowerRaw.contains("no 2fa code provided")
            || lowerRaw.contains("no 2fa method selected")
            || lowerRaw.contains("a two-factor code is required")
            || (lowerRaw.contains("aborting") && (lowerRaw.contains("2fa") || lowerRaw.contains("two-factor")))
            || ((lowerRaw.contains("2fa") || lowerRaw.contains("two-factor") || lowerRaw.contains("verification")) && (lowerRaw.contains("cancel") || lowerRaw.contains("abort")))
            || lowerRaw.contains("two-factor verification was canceled")
            || lowerRaw.contains("two-factor authentication was canceled")
            || lowerRaw.contains("two-factor authentication canceled") {
            return "Two-factor verification was canceled. Enter the code sent to your Apple devices to complete sign-in."
        }
        if lowerRaw.contains("-80045") || lowerRaw.contains("action cannot be completed") {
            return "Apple temporarily rate-limited authentication (-80045). Please wait 2 to 3 minutes or try again."
        }
        if lowerRaw.contains("websocket") || lowerRaw.contains("connection reset without closing handshake") {
            return "The Apple authentication service temporarily disconnected. Please try signing in again."
        }
        if lowerRaw.contains("-20209") || (lowerRaw.contains("locked") && (lowerRaw.contains("apple id") || lowerRaw.contains("account"))) {
            return "Your Apple Account has been locked for security reasons. Please visit https://iforgot.apple.com to unlock it, then try again."
        }
        if lowerRaw.contains("-20101") || lowerRaw.contains("-20102") || lowerRaw.contains("your apple id or password was incorrect") || (lowerRaw.contains("incorrect") && lowerRaw.contains("password")) {
            return "Apple rejected the sign-in. Your Apple Account email or password was incorrect. Please check your credentials and try again."
        }
        if lowerRaw.contains("-21669") || lowerRaw.contains("incorrect verification code") {
            return "The verification code entered was incorrect. Please try signing in again with a new code."
        }
        if lowerRaw.contains("-22979") || lowerRaw.contains("-22981") || (lowerRaw.contains("too many") && lowerRaw.contains("code")) {
            return "Too many verification codes have been requested. Please wait a few minutes before trying again."
        }
        if lowerRaw.contains("-28248") {
            return "SMS verification is unavailable for this Apple Account. Please verify using a trusted Apple device."
        }
        if lowerRaw.contains("503") || lowerRaw.contains("service temporarily unavailable") {
            return "Apple's sign-in service (GrandSlam) is temporarily unavailable (HTTP 503). Apple may be experiencing high load or throttling requests. Please wait a few moments and try again."
        }
        if lowerRaw.contains("429") || lowerRaw.contains("too many requests") {
            return "Apple's authentication servers are temporarily rate-limiting requests (HTTP 429 Too Many Requests). Please wait 2 to 3 minutes before trying again."
        }
        if lowerRaw.contains("mach-o") {
            return "The selected IPA contains an incompatible or corrupted binary. Slip has attempted to repair it, but the app bundle may be incomplete."
        }
        if lowerRaw.contains("applicationverificationfailed") || lowerRaw.contains("failed to verify code signature") {
            return "iOS rejected the app signature. Ensure Developer Mode is enabled on your iPhone in Settings \u{2192} Privacy & Security."
        }
        if lowerRaw.contains("not enough available app ids") {
            return "Your free Apple Account does not have enough available App IDs for this setup. Free accounts allow up to 10 App IDs in a seven-day period, and each kept extension can require another ID. Remove optional extensions or wait for Apple's quota to renew. Deleting an ID may not immediately restore the quota."
        }
        if lowerRaw.contains("maximum number of installed apps") {
            return "Free Apple Accounts can only have 3 active sideloaded apps at a time. Delete another sideloaded app from your iPhone and try again."
        }

        let lines = message.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let bulletLines = lines.filter { $0.hasPrefix("●") || $0.hasPrefix("╰─▶") || $0.hasPrefix("├─▶") }
            .map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "●╰├│─▶ ").union(.whitespacesAndNewlines))
            }

        if let bestBullet = bulletLines.last(where: {
            let bl = $0.lowercased()
            return !bl.contains("failed to log in") &&
                !bl.contains("failed to send initial") &&
                !bl.contains("grandslam error") &&
                !bl.contains("received error response") &&
                !bl.contains("caused by") &&
                !bl.contains(".cargo") &&
                !bl.contains(".rs:") &&
                !bl.isEmpty
        }) ?? bulletLines.first {
            message = bestBullet
        } else {
            let cleanLines = lines.map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "●╰├│─▶ ").union(.whitespacesAndNewlines))
            }.filter { line in
                let l = line.lowercased()
                return !l.contains(".cargo") && !l.contains(".rs:") && !l.isEmpty && l != "misc"
            }
            if let firstClean = cleanLines.first {
                message = firstClean
            }
        }

        message = message.trimmingCharacters(in: CharacterSet(charactersIn: "●╰├│─▶ ").union(.whitespacesAndNewlines))

        if let expression = try? NSRegularExpression(pattern: #"(/Users/[^\s]+|/[^\s]+\.rs:\d+(?::\d+)?)"#) {
            message = expression.stringByReplacingMatches(
                in: message,
                range: NSRange(message.startIndex..., in: message),
                withTemplate: ""
            ).trimmingCharacters(in: CharacterSet(charactersIn: "●╰├│─▶ ").union(.whitespacesAndNewlines))
        }

        let lower = message.lowercased()
        if message.isEmpty || lower.contains("signing engine") || lower == "misc" || message.hasPrefix("╰") || message.hasPrefix("─▶") {
            return "Unable to complete authentication with Apple. Please verify your Apple Account and connection, then try again."
        }

        return message
    }
}


private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
