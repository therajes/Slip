import Foundation

/// A confirmation captures exact serial numbers. “All” never becomes an open-ended
/// instruction that could revoke a certificate created after the user reviewed it.
struct CertificateRevocationPlan: Identifiable {
    let id = UUID()
    let serialNumbers: [String]
    let expectedSerialNumbers: [String]
    let certificates: [CertificateInfo]
    let includesAll: Bool

    static func availableSerialNumbers(in certificates: [CertificateInfo]) -> [String] {
        Array(Set(certificates.compactMap { certificate in
            guard let serial = certificate.serialNumber, !serial.isEmpty else { return nil }
            return serial
        })).sorted()
    }

    init?(certificates: [CertificateInfo], selection: Set<String>, includesAll: Bool = false) {
        let available = Self.availableSerialNumbers(in: certificates)
        guard !selection.isEmpty, selection.isSubset(of: Set(available)) else { return nil }
        if includesAll && selection != Set(available) { return nil }
        serialNumbers = selection.sorted()
        expectedSerialNumbers = available
        self.certificates = serialNumbers.compactMap { serial in certificates.first { $0.serialNumber == serial } }
        self.includesAll = includesAll
    }

    var title: String {
        "Revoke \(includesAll ? "all " : "")\(serialNumbers.count) development certificate\(serialNumbers.count == 1 ? "" : "s")?"
    }

    var confirmationAction: String {
        "Revoke \(includesAll ? "All " : "")\(serialNumbers.count) Certificate\(serialNumbers.count == 1 ? "" : "s")"
    }

    var confirmationMessage: String {
        let names = certificates.map { certificate in
            [certificate.name ?? "Development certificate", certificate.machineName, certificate.serialNumber]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }.map { "• \($0)" }.joined(separator: "\n")
        return "\(names)\n\nApps signed with these certificates may stop opening and must be signed and installed again. This affects apps signed by Slip and by other tools. Revocation cannot be undone."
    }
}

struct AppIDQuotaInfo: Equatable {
    let used: Int?
    let remaining: Int?
    let limit: Int?
    let message: String?

    var summary: String {
        if let used, let limit { return "\(used) of \(limit) App IDs used" }
        if let remaining { return "\(remaining) App ID\(remaining == 1 ? "" : "s") available" }
        return message ?? "Apple App ID quota"
    }
}
