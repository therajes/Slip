import Foundation

/// Read-modify-write under a separate lease, so a worker cannot resurrect a
/// deleted schedule or overwrite a pause made while an installation runs.
struct ManagedInstallationsRepository {
    let fileURL: URL

    func load() throws -> [ManagedInstallation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
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
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
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
}
