import CryptoKit
import Foundation

struct RenewalHistoryEntry: Codable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    var installationReference: String
    var status: RenewalStatus
    var reasonCode: String
}
@MainActor
enum RenewalHistory {
    private static var url: URL { AutoRefreshStore.fileURL.deletingLastPathComponent().appending(path: "Renewal/history-v1.json") }
    static func load() -> [RenewalHistoryEntry] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1024 * 1024,
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RenewalHistoryEntry].self, from: data)) ?? []
    }
    static func record(_ item: ManagedInstallation, status: RenewalStatus, reason: String) {
        let allowed = reason.count < 100 && reason.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "._".contains($0)) }
        guard let lease = try? FileLease.acquire(url.appendingPathExtension("lock"), wait: true) else { return }
        defer { lease.release() }
        let reference = SHA256.hash(data: Data(item.id.utf8)).map { String(format: "%02x", $0) }.joined()
        var entries = load()
        if let last = entries.last, last.installationReference == reference, last.status == status,
           last.reasonCode == reason, Date().timeIntervalSince(last.date) < 15 * 60 { return }
        entries.append(.init(installationReference: reference, status: status, reasonCode: allowed ? reason : "operation.unknown"))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(Array(entries.suffix(500))).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* History failure must not change an installation outcome. */ }
    }
}
