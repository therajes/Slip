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
        case .retryDiscovery: String(localized: "Retry Discovery")
        case .connectUSB: String(localized: "Connect via USB")
        case .openAccounts: String(localized: "Open Accounts")
        case .refreshResources: String(localized: "Refresh Resource Status")
        case .locateIPA: String(localized: "Locate IPA")
        case .reviewEntitlements: String(localized: "Review Entitlement Differences")
        case .verifyInstallation: String(localized: "Verify Device Installation")
        case .retrySafely: String(localized: "Retry Safely")
        case .detailedDiagnostics: String(localized: "Open Detailed Diagnostics")
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
        case .smsRequired: String(localized: "SMS verification required")
        case .interactionRequired: String(localized: "Open Slip to finish authentication")
        case .appIDCapacity: String(localized: "App ID availability needs attention")
        case .entitlementUnsupported: String(localized: "Signing capabilities need review")
        case .encrypted: String(localized: "Encrypted executable cannot be signed")
        case .invalidArchive: String(localized: "The IPA could not be validated")
        case .untrusted: String(localized: "iPhone trust needs attention")
        case .disconnected: String(localized: "The selected iPhone is unavailable")
        case .developerMode: String(localized: "Check Developer Mode on your iPhone")
        case .timeout: String(localized: "The connection timed out")
        case .verificationPending: String(localized: "Installation verification is pending")
        case .sourceMissing: String(localized: "The saved IPA is missing")
        case .cancelled: String(localized: "Operation cancelled")
        case .unknown: String(localized: "Operation needs attention")
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
