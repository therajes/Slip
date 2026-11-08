import SwiftUI

enum SigningCheckSeverity: String, Codable, Hashable, Sendable { case pass, warning, block, unknown }
struct SigningCheck: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var severity: SigningCheckSeverity
    var stage: String
    var evidence: String
    var component: String?
    var observed: String?
    var expected: String?
    var resolution: String?
    var title: String?
    var explanation: String?
}
struct SigningPreflight: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var checks: [SigningCheck]
}
struct SigningReadinessPanel: View {
    let preflight: SigningPreflight
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(preflight.checks.filter { $0.severity == .block }.count) blocking · \(preflight.checks.filter { $0.severity == .warning }.count) warnings")
                    .font(.headline)
                Text("Offline and account checks are preliminary. Only the newly issued profile can confirm signing capabilities.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(preflight.checks) { check in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            if let explanation = check.explanation { Text(explanation) }
                            if let observed = check.observed { Text("Observed: \(observed)") }
                            if let expected = check.expected { Text("Expected: \(expected)") }
                            if let resolution = check.resolution { Text(resolution).fontWeight(.medium) }
                            Text("Evidence: \(check.evidence) · \(check.stage)").foregroundStyle(.secondary)
                            if let component = check.component { Text(component).font(.caption.monospaced()) }
                            DisclosureGroup("Technical key") { Text(check.id).font(.caption.monospaced()) }
                        }.font(.caption).textSelection(.enabled).padding(.vertical, 8)
                    } label: {
                        Label(check.title ?? check.id, systemImage: check.severity == .block ? "xmark.octagon" : check.severity == .pass ? "checkmark.circle" : check.severity == .unknown ? "questionmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(check.severity == .block ? Color.red : check.severity == .warning ? Color.orange : Color.primary)
                    }
                }
            }
        } label: { Label("Installation Readiness", systemImage: "checkmark.shield") }
    }
}
