import Foundation

enum DiagnosticCode: String, Codable, CaseIterable, Sendable {
    case smsRequired = "authentication.sms_required"
    case interactionRequired = "authentication.interaction_required"
    case appIDCapacity = "account.app_id_capacity"
    case entitlementUnsupported = "signing.entitlement_unsupported"
    case encrypted = "ipa.encrypted"
    case invalidArchive = "ipa.invalid_archive"
    case untrusted = "device.untrusted"
    case disconnected = "device.disconnected"
    case developerMode = "device.developer_mode"
    case timeout = "network.timeout"
    case verificationPending = "install.verification_pending"
    case sourceMissing = "refresh.source_missing"
    case cancelled = "operation.cancelled"
    case unknown = "operation.unknown"
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}
enum DiagnosticSeverity: String, Codable, Sendable { case information, warning, error }
enum RecoveryAction: String, Codable, Sendable {
    case retryDiscovery, connectUSB, openAccounts, refreshResources, locateIPA, reviewEntitlements, verifyInstallation, retrySafely, detailedDiagnostics
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .detailedDiagnostics
    }
    var title: String {
        switch self {
        case .retryDiscovery: "Retry Discovery"
        case .connectUSB: "Connect via USB"
        case .openAccounts: "Open Accounts"
        case .refreshResources: "Refresh Resource Status"
        case .locateIPA: "Locate IPA"
        case .reviewEntitlements: "Review Entitlement Differences"
        case .verifyInstallation: "Verify Device Installation"
        case .retrySafely: "Retry Safely"
        case .detailedDiagnostics: "Open Detailed Diagnostics"
        }
    }
}
struct SlipDiagnostic: Codable, Equatable, Sendable {
    var schemaVersion: Int? = 1
    var code: DiagnosticCode
    var phase: String?
    var severity: DiagnosticSeverity
    var retryable: Bool
    var recovery: RecoveryAction
    var title: String {
        switch code {
        case .smsRequired: "SMS verification required"
        case .interactionRequired: "Open Slip to finish authentication"
        case .appIDCapacity: "App ID availability needs attention"
        case .entitlementUnsupported: "Signing capabilities need review"
        case .encrypted: "Encrypted executable cannot be signed"
        case .invalidArchive: "The IPA could not be validated"
        case .untrusted: "iPhone trust needs attention"
        case .disconnected: "The selected iPhone is unavailable"
        case .developerMode: "Check Developer Mode on your iPhone"
        case .timeout: "The connection timed out"
        case .verificationPending: "Installation verification is pending"
        case .sourceMissing: "The saved IPA is missing"
        case .cancelled: "Operation cancelled"
        case .unknown: "Operation needs attention"
        }
    }
}

extension SupportReport {
    /// Deliberately excludes messages, contexts, source names, accounts and identifiers.
    static func generate(diagnostics: [SlipDiagnostic], appVersion: String, osVersion: String) -> String {
        let version = appVersion.allSatisfy { $0.isNumber || $0 == "." } ? appVersion : "Unknown"
        let os = osVersion.allSatisfy { $0.isNumber || $0 == "." } ? osVersion : "Unknown"
        let rows = diagnostics.map { diagnostic in
            "\(diagnostic.code.rawValue) | \(diagnostic.severity.rawValue) | retryable=\(diagnostic.retryable) | \(diagnostic.recovery.rawValue)"
        }.sorted()
        return (["Slip sanitized support report v1", "Slip: \(version)", "macOS: \(os)", "Free-form messages and private context excluded."] + rows).joined(separator: "\n")
    }
}
