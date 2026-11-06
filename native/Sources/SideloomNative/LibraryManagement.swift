import CryptoKit
import Foundation

struct CustomizationPreset: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var options: IpaInstallOptions
    init(name: String, options: IpaInstallOptions) {
        self.name = name
        self.options = options.relocated(to: "")
    }
}

struct LibraryVersionRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    var version: String
    var build: String
    var date = Date()
    var installed: Bool
}

struct LibraryManagementState: Codable, Sendable {
    var presets: [CustomizationPreset] = []
    var history: [String: [LibraryVersionRecord]] = [:]
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        presets = try values.decodeIfPresent([CustomizationPreset].self, forKey: .presets) ?? []
        history = try values.decodeIfPresent([String: [LibraryVersionRecord]].self, forKey: .history) ?? [:]
    }
}

struct ManagedStorageFile: Identifiable, Sendable {
    var url: URL
    var bytes: Int64
    var id: String { url.path }
}

actor LibraryManagementStore {
    static let shared = LibraryManagementStore()
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "app.sideloom.native")
    }
    private var stateURL: URL { root.appending(path: "Library/management-v1.json") }
    var managedDirectory: URL { root.appending(path: "ManagedIPAs") }
    func load() throws -> LibraryManagementState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return .init() }
        let data = try Data(contentsOf: stateURL)
        guard data.count < 8 * 1024 * 1024 else { throw SideloomError.message("Library history is too large to read.") }
        return try JSONDecoder().decode(LibraryManagementState.self, from: data)
    }
    private func save(_ state: LibraryManagementState) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
    func savePreset(name: String, options: IpaInstallOptions) throws {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty else { throw SideloomError.message("Give the preset a name.") }
        var state = try load()
        state.presets.append(.init(name: name, options: options)); try save(state)
    }
    func removePreset(_ id: UUID) throws {
        var state = try load(); state.presets.removeAll { $0.id == id }; try save(state)
    }
    func record(workspaceID: UUID, ipa: IpaInfo, installed: Bool) throws {
        var state = try load(), records = state.history[workspaceID.uuidString] ?? []
        if let last = records.last, last.version == ipa.version, last.build == ipa.buildVersion, last.installed == installed { return }
        records.append(.init(version: ipa.version, build: ipa.buildVersion, installed: installed))
        state.history[workspaceID.uuidString] = Array(records.suffix(100)); try save(state)
    }
    func copyIPA(_ source: URL) throws -> URL {
        let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else { throw SideloomError.message("Choose a regular source IPA, not a symbolic link.") }
        let before = IPAFileStamp.read(source.path)
        guard let before else { throw SideloomError.message("The source IPA is missing.") }
        try FileManager.default.createDirectory(at: managedDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = managedDirectory.resolvingSymlinksInPath()
        guard directory.standardizedFileURL.path == managedDirectory.standardizedFileURL.path else { throw SideloomError.message("Managed storage must not be a symbolic link.") }
        if source.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.path { return source }
        let temporary = directory.appending(path: ".copy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        guard before == IPAFileStamp.read(source.path), try digest(source) == digest(temporary) else { throw SideloomError.message("The source IPA changed during copying. Your original is preserved; try again.") }
        let destination = directory.appending(path: "\(UUID()).ipa")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
    private func digest(_ url: URL) throws -> SHA256.Digest {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 512 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize()
    }
    func files() throws -> [ManagedStorageFile] {
        guard FileManager.default.fileExists(atPath: managedDirectory.path) else { return [] }
        guard managedDirectory.resolvingSymlinksInPath().path == managedDirectory.standardizedFileURL.path else { throw SideloomError.message("Managed storage must not be a symbolic link.") }
        return try FileManager.default.contentsOfDirectory(at: managedDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]).compactMap { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, url.pathExtension == "ipa" else { return nil }
            return .init(url: url, bytes: Int64(values.fileSize ?? 0))
        }
    }
    func cleanupCandidates(references: Set<String>) throws -> [ManagedStorageFile] {
        let protected = Set(references.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        return try files().filter { !protected.contains($0.url.resolvingSymlinksInPath().path) }
    }
    func cleanup(_ requested: Set<String>, references: Set<String>, scheduleURL: URL) throws {
        let schedules = try ManagedInstallationsRepository(fileURL: scheduleURL).load()
        let protected = references.union(schedules.map(\.ipaPath))
        for file in try cleanupCandidates(references: protected) where requested.contains(file.url.path) {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
        }
    }
}

extension IpaInstallOptions {
    func relocated(to path: String) -> Self {
        .init(appPath: path, displayName: displayName, bundleId: bundleId, removedExtensions: removedExtensions,
              customIconPath: customIconPath, increasedMemoryLimit: increasedMemoryLimit, minimumOsVersion: minimumOsVersion,
              removeSupportedDevices: removeSupportedDevices, enableFileSharing: enableFileSharing, plistOverrides: plistOverrides)
    }
}

extension IpaInfo {
    func relocated(to path: String) -> Self {
        .init(path: path, fileName: URL(fileURLWithPath: path).lastPathComponent, appName: appName, bundleId: bundleId,
              version: version, buildVersion: buildVersion, minimumOsVersion: minimumOsVersion, executable: executable,
              encryptionStatus: encryptionStatus, sizeBytes: sizeBytes, extensions: extensions, appIdCost: appIdCost, warnings: warnings)
    }
}

extension AppModel {
    var managedIPAReferences: Set<String> {
        Set(library.apps.map(\.ipa.path) + library.queue.map(\.workspace.ipa.path) + managedInstallations.map(\.ipaPath))
    }
    func copyWorkspaceToManagedStorage(_ id: UUID) async throws {
        guard !workspaceIsBusy, let saved = library.apps.first(where: { $0.id == id }) else { throw SideloomError.message("Finish the current operation before managing storage.") }
        guard let operation = OperationCoordinator.beginOperation(type: .install, appName: "Managing IPA storage") else { throw SideloomError.message("Another installation or renewal is active. Try again when it finishes.") }
        isImportingLibrary = true
        defer { isImportingLibrary = false; operation.end() }
        let destination = try await LibraryManagementStore.shared.copyIPA(URL(fileURLWithPath: saved.ipa.path))
        let path = destination.path
        let scheduleURL = AutoRefreshStore.fileURL
        let originalPath = saved.ipa.path
        try await Task.detached(priority: .utility) {
            try ManagedInstallationsRepository(fileURL: scheduleURL).update { entries in
                for index in entries.indices where entries[index].ipaPath == originalPath {
                    entries[index].options = entries[index].options.relocated(to: path)
                }
            }
        }.value
        for index in library.apps.indices where library.apps[index].ipa.path == saved.ipa.path {
            library.apps[index].ipa = library.apps[index].ipa.relocated(to: path)
            library.apps[index].options = library.apps[index].options.relocated(to: path)
            library.apps[index].sourceStamp = IPAFileStamp.read(path)
        }
        for index in library.queue.indices where library.queue[index].workspace.ipa.path == saved.ipa.path {
            library.queue[index].workspace.ipa = library.queue[index].workspace.ipa.relocated(to: path)
            library.queue[index].workspace.options = library.queue[index].workspace.options.relocated(to: path)
            library.queue[index].workspace.sourceStamp = IPAFileStamp.read(path)
        }
        if activeLibraryID == id { ipa = saved.ipa.relocated(to: path); activeSourceStamp = IPAFileStamp.read(path) }
        reloadManagedInstallations(); persistWorkspace()
        libraryNotice = "IPA copied and verified in managed storage. The original file is preserved."
    }
    func applyCustomizationPreset(_ preset: CustomizationPreset, to saved: SavedAppWorkspace) async throws {
        guard !workspaceIsBusy else { throw SideloomError.message("Finish the current operation before applying a preset.") }
        guard await openLibraryWorkspace(saved.id) else { throw SideloomError.message("Locate this app’s source IPA before applying a preset.") }
        var choices = saved
        choices.options = preset.options.relocated(to: saved.ipa.path)
        applyWorkspaceChoices(choices)
        invalidateQueueReview(for: saved.id); persistWorkspace()
        NotificationCenter.default.post(name: .showInstall, object: nil)
    }
}
