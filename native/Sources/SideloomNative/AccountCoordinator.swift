import AppKit
import Combine
import Foundation
import SwiftUI

// State remains owned by the MainActor facade; operations retain the shared lease.
extension AppModel {
    func recordAuthenticationWarning(_ event: CoreEvent) {
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

    func receiveAuthenticationState(_ event: CoreEvent) {
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

    func receiveTwoFactorChallenge(_ details: TwoFactorDetails?) {
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

    func recordAppIDQuota(_ event: CoreEvent) {
        appIDQuota = AppIDQuotaInfo(used: event.used.flatMap { $0 >= 0 ? $0 : nil },
                                   remaining: event.remaining.flatMap { $0 >= 0 ? $0 : nil },
                                   limit: event.limit.flatMap { $0 > 0 ? $0 : nil }, message: event.message)
        if let message = event.message { appendActivity(message) }
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

    func beginTwoFactorAction(_ action: AuthenticationFlow.ChallengeAction) -> Bool {
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

    func showTwoFactorError(_ message: String) {
        twoFactorError = message
        if isLoggingIn { authentication.showChallengeError(message) }
    }

    func failTwoFactorAction(_ error: Error) {
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

    func accountStorageURL(for email: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "app.sideloom.native/Core", directoryHint: .isDirectory)
        let safe = email.lowercased().replacingOccurrences(of: "@", with: "_at_").replacingOccurrences(of: ".", with: "_")
        return base.appending(path: safe, directoryHint: .isDirectory)
    }

}
