import Foundation

/// Read-modify-write under a separate lease, so a worker cannot resurrect a
/// deleted schedule or overwrite a pause made while an installation runs.
struct ManagedInstallationsRepository {
    let fileURL: URL

    func load() throws -> [ManagedInstallation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 16 * 1024 * 1024 else { throw SideloomError.message("The renewal schedule exceeds its safety budget.") }
        return try JSONDecoder().decode([ManagedInstallation].self, from: Data(contentsOf: fileURL))
    }

    @discardableResult
    func update<T>(_ body: (inout [ManagedInstallation]) throws -> T) throws -> T {
        guard let lease = try FileLease.acquire(fileURL.appendingPathExtension("lock"), wait: true) else {
            throw SideloomError.message("The renewal schedule is busy. Try again shortly.")
        }
        defer { lease.release() }
        var entries = try load()
        let result = try body(&entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        guard data.count <= 16 * 1024 * 1024 else { throw SideloomError.message("The renewal schedule exceeds its safety budget.") }
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return result
    }

    func mergeOutcome(_ updated: ManagedInstallation, original: ManagedInstallation) throws {
        try update { entries in
            guard let index = entries.firstIndex(where: { $0.id == original.id }),
                  entries[index].options == original.options, entries[index].account == original.account else { return }
            let enabled = entries[index].enabled
            entries[index] = updated
            entries[index].enabled = enabled
            if !enabled { entries[index].status = "Paused" }
        }
    }

    func remove(bundleIDs: Set<String>, deviceUDID: String) throws -> Int {
        try update { entries in
            let before = entries.count
            entries.removeAll { $0.deviceUDID == deviceUDID && bundleIDs.contains($0.bundleId) }
            return before - entries.count
        }
    }
}
