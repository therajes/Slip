import CryptoKit
import Foundation

struct SlipBackup: Codable, Sendable {
    var schemaVersion = 1
    var createdAt = Date()
    var library: AppLibraryState
    var management: LibraryManagementState
    var subscriptions: [String: AppUpdateSubscription]
    var ipas: [String: Data]
    var checksums: [String: String]
    var catalog: Data? = nil
    var metadataDigest = ""
    var preview: String { "\(library.apps.count) apps, \(management.presets.count) presets, \(subscriptions.count) subscriptions, \(ipas.count) IPA copies. Existing IDs are retained; conflicts keep local entries. Devices and accounts require revalidation. This excludes iPhone app private data and Keychain secrets." }
}

actor BackupRepository {
    let root: URL
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "app.sideloom.native")) { self.root = root }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func export(library: AppLibraryState, includeIPAs: Bool) throws -> Data {
        let management = try read(LibraryManagementState.self, "management-v1.json") ?? .init()
        var subscriptions = try read([String: AppUpdateSubscription].self, "update-sources-v1.json") ?? [:]
        for key in subscriptions.keys {
            if var url = URLComponents(string: subscriptions[key]!.source) { url.query = nil; url.fragment = nil; url.user = nil; url.password = nil; subscriptions[key]!.source = url.string ?? "" }
            subscriptions[key]!.releases = []
        }
        var files: [String: Data] = [:]
        if includeIPAs {
            for app in library.apps {
                let url = URL(fileURLWithPath: app.ipa.path)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 128 * 1024 * 1024 else { throw SideloomError.message("Optional backup IPA copies must be regular files up to 128 MiB each.") }
                let data = try Data(contentsOf: url)
                files[app.id.uuidString] = data
                guard files.values.reduce(0, { $0 + $1.count }) <= 256 * 1024 * 1024 else { throw SideloomError.message("Optional IPA copies exceed the 256 MiB backup budget. Export metadata only for larger libraries.") }
            }
        }
        var value = SlipBackup(library: library, management: management, subscriptions: subscriptions, ipas: files, checksums: files.mapValues(Self.digest))
        let catalogURL = root.appending(path: "Library/catalog-v1.json")
        if FileManager.default.fileExists(atPath: catalogURL.path) {
            let bytes = try Data(contentsOf: catalogURL)
            guard bytes.count <= 32 * 1024 * 1024 else { throw SideloomError.message("Catalog metadata exceeds backup limits.") }
            let sources = try JSONDecoder().decode([CatalogSource].self, from: bytes)
            let clean = sources.map { source -> CatalogSource in
                var parts = URLComponents(string: source.address); parts?.query = nil; parts?.fragment = nil
                return CatalogSource(id: source.id, address: parts?.string ?? "", github: source.github, name: source.name, publisher: source.publisher)
            }
            value.catalog = try JSONEncoder().encode(clean)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        value.metadataDigest = try Self.metadataChecksum(value)
        return try encoder.encode(value)
    }
    private func read<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        let url = root.appending(path: "Library/" + name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attrs = try url.resourceValues(forKeys: [.fileSizeKey,.isSymbolicLinkKey])
        guard attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) <= 16 * 1024 * 1024 else { throw SideloomError.message("Backup metadata exceeds its safety budget.") }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    static func metadataChecksum(_ value: SlipBackup) throws -> String {
        var copy = value; copy.metadataDigest = ""
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(copy))
    }
    static func inspect(_ data: Data) throws -> SlipBackup {
        guard data.count <= 360 * 1024 * 1024 else { throw SideloomError.message("Backup exceeds the 360 MiB format limit.") }
        let value = try JSONDecoder().decode(SlipBackup.self, from: data)
        guard value.metadataDigest == (try metadataChecksum(value)), value.schemaVersion == 1, value.library.version == 1, value.library.apps.count <= 10000, value.ipas.count <= 1000,
              Set(value.library.apps.map(\.id)).count == value.library.apps.count, Set(value.ipas.keys) == Set(value.checksums.keys) else { throw SideloomError.message("Unsupported or inconsistent backup manifest.") }
        for (key, bytes) in value.ipas {
            guard UUID(uuidString: key) != nil, bytes.count <= 128 * 1024 * 1024, value.checksums[key] == digest(bytes), bytes.prefix(4) == Data([0x50,0x4b,0x03,0x04]) else { throw SideloomError.message("Backup IPA checksum or file type is invalid.") }
        }
        return value
    }
    static func recover(root: URL, locked: Bool = false) throws {
        let marker = root.appending(path: "Library/restore-rollback-v1.json")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        let lease = locked ? nil : try FileLease.acquire(root.appending(path: "Library/backup.lock"), wait: true)
        defer { lease?.release() }
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        let values = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: marker))
        guard Set(values.keys).isSubset(of: ["management-v1.json", "update-sources-v1.json", "workspaces-v1.json", "catalog-v1.json"]) else { throw SideloomError.message("Invalid backup rollback manifest.") }
        for (name, bytes) in values {
            let path = root.appending(path: "Library/" + name)
            if bytes.isEmpty { if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) } }
            else { try bytes.write(to: path, options: .atomic) }
        }
        try FileManager.default.removeItem(at: marker)
    }
    func restore(_ value: SlipBackup) throws -> AppLibraryState {
        _ = try Self.inspect(JSONEncoder().encode(value))
        try FileManager.default.createDirectory(at: root.appending(path: "Library"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let lease = try FileLease.acquire(root.appending(path: "Library/backup.lock"), wait: true) else { throw SideloomError.message("Backup restore is busy.") }
        defer { lease.release() }
        try Self.recover(root: root, locked: true)
        let repository = AppLibraryRepository(fileURL: root.appending(path: "Library/workspaces-v1.json"))
        var current = try repository.load()
        let existing = Set(current.apps.map(\.id))
        var additions = value.library.apps.filter { !existing.contains($0.id) }
        let directory = root.appending(path: "RestoredIPAs/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            for index in additions.indices {
                additions[index].keepRefreshed = false
                additions[index].deviceUDID = nil
                if let bytes = value.ipas[additions[index].id.uuidString] {
                    let file = directory.appending(path: additions[index].id.uuidString + ".ipa")
                    try bytes.write(to: file, options: .atomic)
                    additions[index].ipa = try additions[index].ipa.relocatedForBackup(file.path)
                    additions[index].options = additions[index].options.relocated(to: file.path)
                }
                additions[index].sourceStamp = nil
            }
            current.apps.append(contentsOf: additions)
            // The library commit is atomic; imported queue approvals and renewal execution are never restored.
            var management = try read(LibraryManagementState.self, "management-v1.json") ?? .init()
            let presetIDs = Set(management.presets.map(\.id))
            management.presets.append(contentsOf: value.management.presets.filter { !presetIDs.contains($0.id) })
            for (key, history) in value.management.history where management.history[key] == nil { management.history[key] = history }
            var subscriptions = try read([String: AppUpdateSubscription].self, "update-sources-v1.json") ?? [:]
            for (key, subscription) in value.subscriptions where subscriptions[key] == nil { subscriptions[key] = subscription }
            var files = ["management-v1.json": try JSONEncoder().encode(management), "update-sources-v1.json": try JSONEncoder().encode(subscriptions)]
            if let bytes = value.catalog {
                let sources = try JSONDecoder().decode([CatalogSource].self, from: bytes)
                guard sources.count <= 32, sources.allSatisfy({ SourceFeedParser.secureURL($0.address) != nil }) else { throw SideloomError.message("Invalid catalog backup configuration.") }
                let local = try read([CatalogSource].self, "catalog-v1.json") ?? []
                files["catalog-v1.json"] = try JSONEncoder().encode(local + sources.filter { candidate in !local.contains(where: { $0.address == candidate.address }) })
            }
            var previous: [String: Data] = [:]
            let names = Array(files.keys) + ["workspaces-v1.json"]
            for name in names { previous[name] = (try? Data(contentsOf: root.appending(path: "Library/" + name))) ?? Data() }
            try FileManager.default.createDirectory(at: root.appending(path: "Library"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let rollback = root.appending(path: "Library/restore-rollback-v1.json")
            try JSONEncoder().encode(previous).write(to: rollback, options: .atomic)
            do {
                for (name, data) in files { try data.write(to: root.appending(path: "Library/" + name), options: .atomic) }
                try repository.save(current)
                try FileManager.default.removeItem(at: rollback)
            } catch {
                try Self.recover(root: root, locked: true)
                throw error
            }
            return current
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}

private extension IpaInfo {
    func relocatedForBackup(_ path: String) throws -> Self {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] ?? [:]
        object["path"] = path
        return try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
