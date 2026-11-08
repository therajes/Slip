import Foundation

struct IPAFileStamp: Codable, Hashable, Sendable {
    let size: UInt64
    let modifiedAt: Date

    static func read(_ path: String) -> Self? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: path),
              let size = values[.size] as? NSNumber, let date = values[.modificationDate] as? Date else { return nil }
        return Self(size: size.uint64Value, modifiedAt: date)
    }
}

/// Only preparation choices and file references. Secrets stay in Keychain.
struct SavedAppWorkspace: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var ipa: IpaInfo
    var options: IpaInstallOptions
    var account: String
    var deviceUDID: String?
    var keepRefreshed: Bool
    var sourceStamp: IPAFileStamp?
    var updatedAt = Date()

    var name: String { options.displayName ?? ipa.appName }
    var sourceExists: Bool { FileManager.default.fileExists(atPath: ipa.path) }
}

enum InstallQueueStatus: String, Codable, Sendable {
    case review = "Review required"
    case ready = "Ready"
    case installing = "Installing"
    case installed = "Installed"
    case failed = "Needs attention"
    case cancelled = "Cancelled"
    case waitingForDevice = "Waiting for device"
    case waitingForAccount = "Waiting for account"
    case unknown = "Verification pending"
}

struct InstallQueueItem: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var workspace: SavedAppWorkspace
    var status: InstallQueueStatus = .review
    var message: String?
    var deployment: DeploymentJob? = nil
}

struct AppLibraryState: Codable, Equatable, Sendable {
    var version = 1
    var apps: [SavedAppWorkspace] = []
    var queue: [InstallQueueItem] = []
    var activeID: UUID?

    /// Relaunch never restarts signing or treats an interrupted install as success.
    mutating func recoverInterruptedQueue() {
        for index in queue.indices where queue[index].status == .installing {
            if queue[index].deployment != nil {
                queue[index].deployment?.phase = .unknown
                queue[index].status = .unknown
                queue[index].message = "Interrupted deployment. Verify the intended iPhone before reviewing a retry."
                continue
            }
            queue[index].status = .review
            queue[index].message = "Installation was interrupted. Check the app on your iPhone, then review before retrying."
        }
    }
}

struct AppLibraryRepository: Sendable {
    let fileURL: URL
    static var standard: Self {
        Self(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "app.sideloom.native/Library/workspaces-v1.json"))
    }

    func load() throws -> AppLibraryState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AppLibraryState() }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 16 * 1024 * 1024 else { throw SideloomError.message("The saved library is too large to open.") }
        let state = try JSONDecoder().decode(AppLibraryState.self, from: data)
        guard state.version == 1, Set(state.apps.map(\.id)).count == state.apps.count,
              Set(state.queue.map(\.id)).count == state.queue.count else {
            throw SideloomError.message("The saved library format could not be read.")
        }
        return state
    }

    func save(_ state: AppLibraryState) throws {
        // Validate the existing document first; preserve a damaged or newer file.
        _ = try load()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
