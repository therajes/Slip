import Foundation

struct AppIDPlanEntry: Identifiable {
    let name: String
    let bundleID: String
    let optional: Bool
    let reused: Bool
    var id: String { bundleID }
}

struct AppIDPlan {
    let entries: [AppIDPlanEntry]
    let checkedAt: Date?
    let remaining: Int?
    let account: String
    var resourceState: String {
        guard let checkedAt else { return "Not checked · estimates only" }
        return Date().timeIntervalSince(checkedAt) > 15 * 60 ? "Stale · refresh resource status before signing" : "Recently checked · availability may change"
    }
    var reusedCount: Int { entries.filter(\.reused).count }
    var newCount: Int { entries.count - reusedCount }
    var summary: String {
        "\(newCount) new App IDs needed; \(reusedCount) existing IDs reusable"
    }
}

extension AppModel {
    var appIDPlan: AppIDPlan {
        let workspaces = library.queue.filter { $0.status == .ready }.map(\.workspace)
        let validResources = resourcesLoaded && resourcesAccount == selectedAccount && resourcesTeamID != nil
        let existing = validResources ? Set(accountAppIDs.map(\.bundleId)) : []
        let team = validResources ? resourcesTeamID : nil
        var entries: [String: AppIDPlanEntry] = [:]
        func append(ipa: IpaInfo, bundleID: String, removed: Set<String>) {
            let signedMain = team.map { bundleID + "." + $0 } ?? bundleID
            entries[signedMain] = .init(name: ipa.appName, bundleID: signedMain, optional: false,
                                         reused: existing.contains(signedMain))
            for item in ipa.extensions where !removed.contains(item.path) {
                let prefix = ipa.bundleId + "."
                // The signing engine rejects extensions outside the parent namespace.
                let suffix = item.bundleId.hasPrefix(prefix) ? String(item.bundleId.dropFirst(prefix.count)) : item.bundleId
                let signed = signedMain + "." + suffix
                entries[signed] = .init(name: item.name, bundleID: signed, optional: true,
                                         reused: existing.contains(signed))
            }
        }
        for workspace in workspaces where workspace.account == selectedAccount {
            append(ipa: workspace.ipa, bundleID: workspace.options.bundleId ?? workspace.ipa.bundleId,
                   removed: Set(workspace.options.removedExtensions))
        }
        if let ipa { append(ipa: ipa, bundleID: effectiveBundleID, removed: removedExtensions) }
        return AppIDPlan(entries: entries.values.sorted { $0.bundleID < $1.bundleID },
                         checkedAt: validResources ? resourcesUpdatedAt : nil,
                         remaining: validResources ? appIDQuota?.remaining : nil, account: selectedAccount)
    }
}
