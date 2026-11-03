import AppKit
import Foundation

extension AppModel {
    var workspaceIsBusy: Bool {
        isAuthenticating || isInspecting || isDownloading || isExporting || isImportingLibrary || isRestoringWorkspace || isRunningInstallQueue || isUninstallingApps
    }

    func currentWorkspace() -> SavedAppWorkspace? {
        guard let ipa else { return nil }
        return SavedAppWorkspace(id: activeLibraryID ?? UUID(), ipa: ipa, options: installOptions(for: ipa, includeUnfinishedOverrides: true),
                                 account: selectedAccount, deviceUDID: selectedDevice?.udid ?? desiredWorkspaceDeviceUDID,
                                 keepRefreshed: keepAutomaticallyRefreshed, sourceStamp: activeSourceStamp)
    }

    func persistWorkspace() {
        workspaceSaveTask?.cancel()
        workspaceSaveTask = nil
        guard let writer = libraryDiskWriter, !isRestoringWorkspace else { return }
        if var snapshot = currentWorkspace() {
            activeLibraryID = snapshot.id
            if let index = library.apps.firstIndex(where: { $0.id == snapshot.id }) {
                snapshot.updatedAt = library.apps[index].updatedAt
                if snapshot != library.apps[index] {
                    snapshot.updatedAt = Date()
                    library.apps[index] = snapshot
                }
            } else { library.apps.append(snapshot) }
            if library.activeID != snapshot.id { library.activeID = snapshot.id }
        }
        guard lastSubmittedLibrary != library else { return }
        let snapshot = library
        lastSubmittedLibrary = snapshot
        libraryRevision += 1
        let revision = libraryRevision
        pendingLibraryWrites += 1
        libraryWriteTask = Task { [weak self] in
            do {
                try await writer.save(snapshot, revision: revision)
                if let self, self.libraryRevision == revision { self.librarySaveFailed = false }
            } catch {
                if let self, self.libraryRevision == revision {
                    self.lastSubmittedLibrary = nil
                    self.librarySaveFailed = true
                    self.libraryNotice = "Slip couldn’t save the library. Your existing saved file has been preserved."
                }
            }
            self?.pendingLibraryWrites -= 1
        }
    }

    func scheduleWorkspacePersistence() {
        guard libraryRepository != nil, !isRestoringWorkspace else { return }
        workspaceSaveTask?.cancel()
        workspaceSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.persistWorkspace()
        }
    }

    @discardableResult
    func flushLibraryPersistence() async -> Bool {
        while true {
            persistWorkspace()
            while pendingLibraryWrites > 0 {
                await libraryWriteTask?.value
                if pendingLibraryWrites > 0 { await Task.yield() }
            }
            if librarySaveFailed { return false }
            // Include edits made while the preceding disk write was in flight.
            if workspaceSaveTask == nil { return true }
        }
    }

    @discardableResult
    func openLibraryWorkspace(_ id: UUID, queueID: UUID? = nil) async -> Bool {
        guard (!workspaceIsBusy || (isRunningInstallQueue && activeQueueID == queueID && queueID != nil)) else { return false }
        persistWorkspace()
        guard let saved = library.apps.first(where: { $0.id == id }) else { return false }
        guard saved.sourceExists else {
            libraryNotice = "\(saved.name)’s IPA has moved or was deleted. Locate it in the library to restore this workspace."
            return false
        }
        isRestoringWorkspace = true
        defer { isRestoringWorkspace = false; persistWorkspace() }
        let stamp = IPAFileStamp.read(saved.ipa.path)
        guard await loadIPA(URL(fileURLWithPath: saved.ipa.path), queueID: queueID) else { return false }
        guard let inspected = ipa else { return false }
        guard inspected == saved.ipa, stamp == saved.sourceStamp else {
            libraryNotice = "\(saved.name)’s IPA changed. Review its current contents before installing or adding it to the queue again."
            invalidateQueueReview(for: id)
            return queueID == nil
        }
        applyWorkspaceChoices(saved)
        ipaPreparationNotice = "Workspace restored. Review your saved choices before installing."
        return true
    }

    func applyWorkspaceChoices(_ saved: SavedAppWorkspace) {
        let options = saved.options
        customName = options.displayName ?? ""
        customBundleID = options.bundleId ?? ""
        customIconURL = options.customIconPath.map { URL(fileURLWithPath: $0) }
        removedExtensions = Set(options.removedExtensions)
        increasedMemoryLimit = options.increasedMemoryLimit
        minimumOSVersion = options.minimumOsVersion ?? ""
        removeSupportedDevices = options.removeSupportedDevices
        enableFileSharing = options.enableFileSharing
        plistOverrides = options.plistOverrides
        keepAutomaticallyRefreshed = saved.keepRefreshed
        selectedAccount = accounts.contains(saved.account) ? saved.account : ""
        desiredWorkspaceDeviceUDID = saved.deviceUDID
        selectedDevice = devices.filter { $0.udid == saved.deviceUDID }
            .sorted { $0.connectionType == "USB" && $1.connectionType != "USB" }.first
    }

    func locateLibraryWorkspace(_ id: UUID, at url: URL) async {
        guard !workspaceIsBusy, let saved = library.apps.first(where: { $0.id == id }) else { return }
        let path = url.resolvingSymlinksInPath().path
        guard !library.apps.contains(where: { $0.id != id && $0.ipa.path == path }) else {
            libraryNotice = "That IPA already has a saved workspace. Open its library entry instead."
            return
        }
        guard await loadIPA(url, expectedBundleID: saved.ipa.bundleId) else { return }
        activeLibraryID = id
        if ipa?.version == saved.ipa.version, ipa?.extensions == saved.ipa.extensions {
            applyWorkspaceChoices(saved)
        }
        invalidateQueueReview(for: id)
        persistWorkspace()
        libraryNotice = "IPA located. Review the restored workspace before installing."
        NotificationCenter.default.post(name: .showInstall, object: nil)
    }

    /// A batch preserves drop order and never signs without per-app review.
    func importIPAs(_ urls: [URL]) async {
        guard !workspaceIsBusy else { errorMessage = "Finish the current operation before importing apps."; return }
        var seen = Set<String>()
        let files = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "ipa" }
            .map { $0.resolvingSymlinksInPath() }.filter { seen.insert($0.path).inserted }
        guard !files.isEmpty else { return }
        if files.count == 1 {
            if let existing = library.apps.first(where: { $0.ipa.path == files[0].path }) {
                _ = await openLibraryWorkspace(existing.id)
            } else { _ = await loadIPA(files[0]); persistWorkspace() }
            NotificationCenter.default.post(name: .showInstall, object: nil)
            return
        }
        isImportingLibrary = true
        var imported = 0
        var failures: [String] = []
        defer { isImportingLibrary = false; persistWorkspace() }
        for file in files {
            if let existing = library.apps.first(where: { $0.ipa.path == file.path }) {
                addUnreviewedQueueItem(existing)
                imported += 1
                continue
            }
            guard await loadIPA(file) else { failures.append(file.lastPathComponent); errorMessage = nil; continue }
            persistWorkspace()
            if let saved = currentWorkspace() { addUnreviewedQueueItem(saved); imported += 1 }
        }
        libraryNotice = "\(imported) apps added in file order. Review each queue item before starting."
            + (failures.isEmpty ? "" : " Couldn’t import: \(failures.joined(separator: ", ")).")
        NotificationCenter.default.post(name: .showLibrary, object: nil)
    }

    private func addUnreviewedQueueItem(_ saved: SavedAppWorkspace) {
        guard !library.queue.contains(where: { $0.workspace.id == saved.id && $0.status != .installed }) else { return }
        library.queue.append(InstallQueueItem(workspace: saved))
    }

    func reviewQueueItem(_ id: UUID) async {
        guard !workspaceIsBusy, let item = library.queue.first(where: { $0.id == id }) else { return }
        if await openLibraryWorkspace(item.workspace.id) {
            // Review the queue's exact choices, rather than unrelated later edits.
            if ipa == item.workspace.ipa, activeSourceStamp == item.workspace.sourceStamp { applyWorkspaceChoices(item.workspace) }
            reviewingQueueID = id
            NotificationCenter.default.post(name: .showInstall, object: nil)
        }
    }

    func saveWorkspaceToQueue() {
        guard !workspaceIsBusy, let snapshot = currentWorkspace(), blockingInstallIssue == nil else {
            errorMessage = blockingInstallIssue.map { "\($0.title). \($0.detail)" } ?? "Finish the current operation before adding to the queue."
            return
        }
        persistWorkspace()
        if let id = reviewingQueueID, let index = library.queue.firstIndex(where: { $0.id == id }) {
            library.queue[index].workspace = snapshot
            library.queue[index].status = .ready
            library.queue[index].message = nil
        } else if let index = library.queue.firstIndex(where: { $0.workspace.id == snapshot.id && $0.status != .installed }) {
            library.queue[index].workspace = snapshot
            library.queue[index].status = .ready
            library.queue[index].message = nil
        } else { library.queue.append(InstallQueueItem(workspace: snapshot, status: .ready)) }
        reviewingQueueID = nil
        persistWorkspace()
        NotificationCenter.default.post(name: .showLibrary, object: nil)
    }

    func invalidateQueueReview(for workspaceID: UUID) {
        for index in library.queue.indices where library.queue[index].workspace.id == workspaceID && library.queue[index].status != .installed {
            library.queue[index].status = .review
            library.queue[index].message = "The source IPA changed. Review this app again."
        }
    }

    func removeLibraryWorkspace(_ id: UUID) {
        guard !workspaceIsBusy else { return }
        if activeLibraryID == id { clearIPA() }
        library.apps.removeAll { $0.id == id }
        library.queue.removeAll { $0.workspace.id == id }
        persistWorkspace() // Only references are removed; original files and renewal recipes stay intact.
    }

    func moveQueueItem(_ id: UUID, by offset: Int) {
        guard !isRunningInstallQueue, let index = library.queue.firstIndex(where: { $0.id == id }),
              library.queue.indices.contains(index + offset) else { return }
        library.queue.swapAt(index, index + offset)
        persistWorkspace()
    }

    func removeQueueItem(_ id: UUID) {
        guard activeQueueID != id else { return }
        library.queue.removeAll { $0.id == id }
        if reviewingQueueID == id { reviewingQueueID = nil }
        persistWorkspace()
    }

    func startInstallQueue() {
        guard !workspaceIsBusy, !library.queue.isEmpty else { return }
        // Do not silently skip an unreviewed/failed app or reorder the user's queue.
        let pending = library.queue.filter { $0.status != .installed }
        guard !pending.isEmpty, pending.allSatisfy({ $0.status == .ready }) else {
            libraryNotice = "Review every pending app before starting the queue."
            return
        }
        persistWorkspace()
        queueCancelled = false
        isRunningInstallQueue = true
        Task { await runInstallQueue(pending.map(\.id)) }
    }

    func runInstallQueue(_ ids: [UUID], performInstallation: (@MainActor () async -> Bool)? = nil) async {
        defer { isRunningInstallQueue = false; activeQueueID = nil; persistWorkspace() }
        NotificationCenter.default.post(name: .showInstall, object: nil)
        for id in ids {
            guard !queueCancelled else { break }
            guard let item = library.queue.first(where: { $0.id == id }), item.status == .ready else { continue }
            activeQueueID = id
            let opened = await openLibraryWorkspace(item.workspace.id, queueID: id)
            if queueCancelled { setQueueResult(id, .cancelled, message: "Queue stopped. Review before retrying."); break }
            guard opened else {
                setQueueResult(id, .review, message: "The saved IPA is missing or changed. Locate it and review this app again.")
                break
            }
            // Restore the reviewed snapshot, not subsequent edits to the library.
            guard ipa == item.workspace.ipa, activeSourceStamp == item.workspace.sourceStamp else {
                setQueueResult(id, .review, message: "The IPA changed after review. Review it again.")
                break
            }
            await refreshDevices()
            guard !queueCancelled else { break }
            applyWorkspaceChoices(item.workspace)
            guard blockingInstallIssue == nil else {
                setQueueResult(id, .failed, message: blockingInstallIssue.map { "\($0.title). \($0.detail)" })
                break
            }
            setQueueResult(id, .installing)
            let installed: Bool
            if let performInstallation { installed = await performInstallation() }
            else { installed = await installCurrentWorkspace() }
            setQueueResult(id, installed ? .installed : queueCancelled ? .cancelled : .failed,
                           message: installed ? nil : errorMessage ?? (queueCancelled ? "Queue stopped. Review before retrying." : "Installation stopped. Review this app before retrying."))
            if !installed { break }
        }
    }

    private func setQueueResult(_ id: UUID, _ status: InstallQueueStatus, message: String? = nil) {
        guard let index = library.queue.firstIndex(where: { $0.id == id }) else { return }
        library.queue[index].status = status
        library.queue[index].message = message
        persistWorkspace()
    }

    func stopInstallQueue() {
        queueCancelled = true
        if isInstalling { cancelInstall() }
    }
}

extension Notification.Name {
    static let showLibrary = Notification.Name("SlipShowLibrary")
}
