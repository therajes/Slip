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
extension SigningCheck {
    func applies(removing paths: Set<String>) -> Bool {
        guard let component else { return true }
        return !paths.contains { component == $0 || component.hasPrefix($0 + "/") }
    }
    var displayTitle: String {
        title ?? id.split(separator: ".").map { $0.replacingOccurrences(of: "_", with: " ").capitalized }.joined(separator: " · ")
    }
    var whyItMatters: String {
        explanation ?? (stage == "postProvision" || stage == "post-provision" ? "The issued profile must authorize these capabilities before Slip transfers the app. Differences can change app functionality." : "This evidence helps identify compatibility issues before signing. Missing evidence remains unknown and cannot guarantee installation success.")
    }
}
struct SigningReadinessPanel: View {
    let preflight: SigningPreflight
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(preflight.checks.filter { $0.severity == .block }.count) blocking · \(preflight.checks.filter { $0.severity == .warning }.count) warnings").font(.headline)
                Text("Offline and account checks are preliminary. Only the newly issued profile can confirm signing capabilities.").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(Set(preflight.checks.map(\.stage))).sorted(), id: \.self) { stage in
                    Text(stage.replacingOccurrences(of: "_", with: " ").capitalized).font(.subheadline.weight(.semibold))
                    ForEach(preflight.checks.filter { $0.stage == stage }) { check in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Why this matters").fontWeight(.semibold)
                                Text(check.whyItMatters)
                                Grid(alignment: .topLeading, horizontalSpacing: 18) {
                                    GridRow { Text("Observed").fontWeight(.semibold); Text("Expected / permitted").fontWeight(.semibold) }
                                    GridRow { Text(check.observed ?? "Unknown"); Text(check.expected ?? "Not established") }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if let resolution = check.resolution { Text(resolution).fontWeight(.medium) }
                                Text("Evidence: \(check.evidence)").foregroundStyle(.secondary)
                                if let component = check.component { Text("Affected component: " + component).font(.caption.monospaced()) }
                                DisclosureGroup("Technical key") { Text(check.id).font(.caption.monospaced()) }
                            }.font(.caption).textSelection(.enabled).padding(.vertical, 8)
                        } label: {
                            Label(check.displayTitle, systemImage: check.severity == .block ? "xmark.octagon" : check.severity == .pass ? "checkmark.circle" : check.severity == .unknown ? "questionmark.circle" : "exclamationmark.triangle")
                                .foregroundStyle(check.severity == .block ? Color.red : check.severity == .warning ? Color.orange : Color.primary)
                        }
                    }
                }
            }
        } label: { Label("Installation Readiness", systemImage: "checkmark.shield") }
    }
}
