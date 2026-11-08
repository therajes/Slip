import AppKit
import Combine
import Foundation
import SwiftUI

// State remains owned by the MainActor facade; operations retain the shared lease.
extension AppModel {
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

    func performManagedRefresh(_ id: String) async -> Bool {
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

    func refreshAllManagedInstallations() {
        let ids = Set(managedInstallations.filter(\.enabled).map(\.id))
        refreshManagedInstallations(ids, respectPaused: true)
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

}
