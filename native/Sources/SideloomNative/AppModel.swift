import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [DeviceInfo] = []
    @Published var deviceHealth: [String: DeviceHealthEvidence] = [:]
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
    var refreshQueueCancelled = false
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
    var operationCancelled = false
    var inspectionGeneration = UUID()
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

    @Published var postProvisionChecks: [SigningCheck] = []
    @Published var diagnostic: SlipDiagnostic?
    let core: CoreClient
    @Published var pausedDownload: PausedIPADownload?
    @Published var pauseQueueAfterCurrent = false
    let downloadControl = IPADownloadControl()
    var downloadTask: Task<URL, Error>?
    var downloadGeneration: UUID?
    @Published var authenticationMode = UserDefaults.standard.string(forKey: "authenticationMode") ?? "local" {
        didSet { UserDefaults.standard.set(authenticationMode, forKey: "authenticationMode") }
    }
    @Published var anisetteServer = UserDefaults.standard.string(forKey: "anisetteServer") ?? "" {
        didSet { UserDefaults.standard.set(anisetteServer, forKey: "anisetteServer") }
    }
    var stageProgress: [String: Double] = [:]
    var installStartedAt: Date?
    var activeOperationHandle: OperationCoordinator.OperationHandle?

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
            do { try BackupRepository.recover(root: repository.fileURL.deletingLastPathComponent().deletingLastPathComponent()); library = try repository.load() }
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
                await verifyPendingInstallation()
                deviceMonitor = DeviceConnectionMonitor { [weak self] in
                    guard let self, !self.workspaceIsBusy else { return }
                    await self.refreshDevices(quiet: true)
                }
            }
        }
    }

    var visibleActivity: [String] {
        hideSensitiveInfo ? activity.map(redacted) : activity
    }

    func redacted(_ entry: String) -> String {
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

    func appendActivity(_ entry: String) {
        activity.insert(entry, at: 0)
        if activity.count > 100 { activity.removeLast(activity.count - 100) }
    }

    func friendlyMessage(for error: Error) -> String {
        friendlyMessage(error.localizedDescription)
    }

    func friendlyMessage(_ raw: String) -> String {
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

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
