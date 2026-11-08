import AppKit
import Combine
import Foundation
import SwiftUI

// State remains owned by the MainActor facade; operations retain the shared lease.
extension AppModel {
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

    func loadIPAPreview(for info: IpaInfo, generation: UUID) async {
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

    func discardIPAPreview() { ipaIconURL = nil }

}
