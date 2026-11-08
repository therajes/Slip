import Foundation

struct AppUpdateSubscription: Codable, Sendable {
    var source = ""
    var github = false
    var checkedAt: Date?
    var releases: [AppUpdateRelease] = []
}

actor AppUpdateRepository {
    static let shared = AppUpdateRepository(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "app.sideloom.native/Library/update-sources-v1.json"))
    let fileURL: URL
    init(fileURL: URL) { self.fileURL = fileURL }
    private func loadAll() throws -> [String: AppUpdateSubscription] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 16 * 1024 * 1024 else { throw SideloomError.message("Saved update sources exceed the storage limit.") }
        return try JSONDecoder().decode([String: AppUpdateSubscription].self, from: data)
    }
    func load(_ id: UUID) throws -> AppUpdateSubscription { try loadAll()[id.uuidString] ?? .init() }
    func save(_ subscription: AppUpdateSubscription, for id: UUID) throws {
        var all = try loadAll(); all[id.uuidString] = subscription
        let data = try JSONEncoder().encode(all)
        guard data.count <= 16 * 1024 * 1024 else { throw SideloomError.message("Saved update sources exceed the storage limit.") }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

extension AppModel {
    /// Downloads and inspects before replacing the saved source; signing remains a separate reviewed action.
    func prepareLibraryUpdate(_ release: AppUpdateRelease, workspace: SavedAppWorkspace) async -> Bool {
        guard !workspaceIsBusy, SourceFeedParser.secureURL(release.downloadURL.absoluteString) != nil else { return false }
        persistWorkspace()
        let generation = UUID()
        downloadGeneration = generation
        isDownloading = true; downloadProgress = IPADownloadProgress(); errorMessage = nil
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "app.sideloom.native/Imports")
        let task = Task { [weak self] in
            try await IPAURLDownloadService().download(release.downloadURL, to: directory) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadGeneration == generation else { return }
                    self.downloadProgress = progress
                }
            }
        }
        downloadTask = task
        defer {
            if downloadGeneration == generation { isDownloading = false; downloadGeneration = nil; downloadTask = nil; downloadProgress = nil }
        }
        do {
            let file = try await task.value
            guard downloadGeneration == generation else { try? FileManager.default.removeItem(at: file); return false }
            guard await loadIPA(file, downloadID: generation, expectedBundleID: workspace.ipa.bundleId, historyWorkspaceID: workspace.id) else { try? FileManager.default.removeItem(at: file); return false }
            activeLibraryID = workspace.id
            applyWorkspaceChoices(workspace)
            removedExtensions.formIntersection(Set(ipa?.extensions.map(\.path) ?? []))
            invalidateQueueReview(for: workspace.id)
            persistWorkspace()
            ipaPreparationNotice = "Update prepared with saved customizations. Review extensions and compatibility before signing."
            NotificationCenter.default.post(name: .showInstall, object: nil)
            return true
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                currentStage = "Update download cancelled"
            } else if downloadGeneration == generation { errorMessage = IPADownloadPolicy.message(error) }
            return false
        }
    }
}

extension AppModel {
    /// Catalog discovery never signs; explicit asset selection downloads, inspects,
    /// validates declared identity and returns to the existing readiness workflow.
    func prepareCatalogRelease(_ release: AppUpdateRelease, expectedBundleID: String?) async -> Bool {
        guard !workspaceIsBusy, SourceFeedParser.secureURL(release.downloadURL.absoluteString) != nil else { return false }
        let generation = UUID()
        downloadGeneration = generation; isDownloading = true; errorMessage = nil
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "app.sideloom.native/Imports")
        let task = Task {
            try await IPAURLDownloadService().download(release.downloadURL, to: directory) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadGeneration == generation else { return }
                    self.downloadProgress = progress
                }
            }
        }
        downloadTask = task
        defer { if downloadGeneration == generation { isDownloading = false; downloadGeneration = nil; downloadTask = nil; downloadProgress = nil } }
        do {
            let file = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard downloadGeneration == generation else { try? FileManager.default.removeItem(at: file); return false }
            guard await loadIPA(file, downloadID: generation, expectedBundleID: expectedBundleID) else { try? FileManager.default.removeItem(at: file); return false }
            ipaPreparationNotice = "Catalog asset inspected. Review its actual identity, capabilities and target before signing. No installation has started."
            NotificationCenter.default.post(name: .showInstall, object: nil)
            return true
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { currentStage = "Catalog download cancelled" }
            else { errorMessage = IPADownloadPolicy.message(error) }
            return false
        }
    }
}
