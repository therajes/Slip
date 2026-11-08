import AppKit
import Combine
import Foundation
import SwiftUI

// State remains owned by the MainActor facade; operations retain the shared lease.
extension AppModel {
    func install() {
        guard !isRunningInstallQueue, !isImportingLibrary, !isRestoringWorkspace else { return }
        Task { _ = await installCurrentWorkspace() }
    }

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
                if event.type == "operationStarted" {
                    guard await checkpointDeploymentPhase(.signing, operationID: event.operationId) else { core.cancel(); return }
                } else if event.type == "progress", event.stage == "transfer" {
                    guard await checkpointDeploymentPhase(.transferring) else { core.cancel(); return }
                } else if event.type == "progress", event.stage == "verify" {
                    guard await checkpointDeploymentPhase(.verifying) else { core.cancel(); return }
                }
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
                    guard await checkpointDeploymentPhase(.waitingForAccount) else { core.cancel(); return }
                    receiveTwoFactorChallenge(event.details)
                    errorMessage = nil
                    appendActivity("Apple requested a verification code")
                case "accountProfile":
                    guard await checkpointDeploymentPhase(.signing) else { core.cancel(); return }
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
                case "operationStarted":
                    if let id = event.operationId, libraryRepository?.fileURL == AppLibraryRepository.standard.fileURL {
                        do {
                            try await PendingOutcomeStore.shared.save(.init(operationId: id, storagePath: request.storagePath, device: request.device,
                                ipa: ipa, options: request.options, account: request.email, renewalEnabled: item?.enabled ?? keepAutomaticallyRefreshed))
                        } catch {
                            core.cancel()
                            throw SideloomError.message("Could not preserve installation recovery information. Installation stopped before transfer.")
                        }
                    }
                case "postProvisionChecks":
                    postProvisionChecks = event.checks ?? []
                case "provisioningReviewRequired":
                    let alert = NSAlert()
                    alert.messageText = "Review signing capability changes"
                    alert.informativeText = event.message ?? "The signed app has capability limitations."
                    alert.addButton(withTitle: "Cancel Installation")
                    alert.addButton(withTitle: "Accept Limitations & Continue")
                    try core.submitCapabilityAcknowledgement(alert.runModal() == .alertSecondButtonReturn)
                case "verificationPending":
                    _ = await checkpointDeploymentPhase(.unknown, operationID: event.operationId)
                    diagnostic = event.diagnostic ?? SlipDiagnostic(code: .verificationPending, phase: "verify", severity: .warning, retryable: true, recovery: .verifyInstallation)
                    currentStage = "Verification pending"
                    errorMessage = "The device has not confirmed this installation. Verify its state before retrying; saved installation metadata is unchanged."
                    return
                case "completed":
                    guard event.confirmsInstallation else {
                        _ = await checkpointDeploymentPhase(.unknown, operationID: event.operationId)
                        diagnostic = SlipDiagnostic(code: .verificationPending, phase: "verify", severity: .warning, retryable: true, recovery: .verifyInstallation)
                        currentStage = "Verification pending"
                        errorMessage = "The signing engine did not provide device verification. Saved installation metadata is unchanged."
                        return
                    }
                    guard await checkpointDeploymentPhase(.succeeded, operationID: event.operationId) else { return }
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
                        if libraryRepository?.fileURL == AppLibraryRepository.standard.fileURL, let id = event.operationId {
                            try await PendingOutcomeStore.shared.clear(operationId: id)
                        }
                    } catch {
                        appendActivity("Could not save Auto Refresh schedule: \(error.localizedDescription)")
                    }
                case "error":
                    _ = await checkpointDeploymentPhase(event.diagnostic?.code == .cancelled ? .cancelled : .failed, operationID: event.operationId)
                    diagnostic = event.diagnostic
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

    func updateProgress(stage: String, value: Double, message: String?) {
        stageProgress[stage] = value
        let prepare = stageProgress["prepare", default: 0]
        let sign = stageProgress["sign", default: 0]
        let install = stageProgress["install", default: 0]
        let account = stageProgress["account", default: stage == "account" ? value : 1]
        overallProgress = account * 0.08 + prepare * 0.12 + sign * 0.40 + install * 0.40
        currentStage = message ?? stage.capitalized
    }

}
