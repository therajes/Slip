import CryptoKit
import Foundation

enum DeploymentPhase: String, Codable, Hashable, Sendable {
    case draft, needsReview, ready, waitingForDevice, waitingForAccount, signing, transferring, verifying, succeeded, failed, unknown, cancelled

    func permits(_ next: Self) -> Bool {
        if next == .needsReview { return self != .succeeded }
        switch self {
        case .draft: return next == .needsReview
        case .needsReview: return next == .ready
        case .ready, .waitingForDevice, .waitingForAccount:
            return [.waitingForDevice, .waitingForAccount, .signing, .cancelled].contains(next)
        case .signing: return [.waitingForAccount, .transferring, .verifying, .succeeded, .failed, .unknown, .cancelled].contains(next)
        case .transferring: return [.verifying, .failed, .unknown, .cancelled].contains(next)
        case .verifying: return [.succeeded, .unknown, .failed, .cancelled].contains(next)
        case .unknown: return [.succeeded, .failed].contains(next)
        case .failed, .cancelled, .succeeded: return false
        }
    }
}

/// One immutable review identity per device, on the existing installation queue.
struct DeploymentJob: Codable, Hashable, Sendable {
    var schemaVersion = 1
    let operationID: UUID
    let sourceSHA256: String
    let optionsSHA256: String
    let deviceUDID: String
    let account: String
    let teamID: String?
    let effectiveBundleID: String
    let createdAt: Date
    var reviewedAt: Date
    var updatedAt: Date
    var phase: DeploymentPhase = .ready
    var retryCount = 0
    var coreOperationID: String? = nil
    var lastErrorCode: String?

    mutating func transition(to next: DeploymentPhase, at date: Date = Date()) throws {
        guard phase.permits(next) else { throw SideloomError.message("Review the deployment before this transition.") }
        phase = next; updatedAt = date
    }
    var approvalExpired: Bool { Date().timeIntervalSince(reviewedAt) > 24 * 3600 }
    static func optionsHash(_ options: IpaInstallOptions) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(options)).map { String(format: "%02x", $0) }.joined()
    }
    static func sourceHash(_ path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
