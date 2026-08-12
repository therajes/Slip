import Foundation

struct AccountProfile: Codable, Hashable, Identifiable {
    let email: String
    var displayName: String

    var id: String { email }

    var initials: String {
        let pieces = displayName
            .split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "_" || $0 == "-" })
            .prefix(3)
        let value = pieces.compactMap(\.first).map(String.init).joined().uppercased()
        return value.isEmpty ? "A" : value
    }
}

enum AccountProfileStore {
    private static let defaultsKey = "appleAccountProfiles"

    static func load(for accounts: [String]) -> [String: AccountProfile] {
        removeLegacyProfilePictures()
        let saved: [AccountProfile]
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([AccountProfile].self, from: data) {
            saved = decoded
        } else {
            saved = []
        }

        var savedByEmail: [String: AccountProfile] = [:]
        for profile in saved {
            let sanitized = sanitizedProfile(profile)
            savedByEmail[sanitized.email] = sanitized
        }
        let result = Dictionary(uniqueKeysWithValues: accounts.map { email in
            let key = email.lowercased()
            return (key, savedByEmail[key] ?? AccountProfile(
                email: key,
                displayName: inferredName(from: key)
            ))
        })
        // Re-encode the current initials-only schema so obsolete image-path fields
        // disappear from preferences as soon as this release runs.
        try? save(Array(result.values))
        return result
    }

    static func upsert(email: String, displayName: String?) throws {
        let key = email.lowercased()
        var profiles = Array(loadAll().values)
        var profile = profiles.first(where: { $0.email == key }) ?? AccountProfile(
            email: key,
            displayName: inferredName(from: key)
        )

        if let displayName {
            let trimmed = displayName
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { profile.displayName = String(trimmed.prefix(80)) }
        }
        profiles.removeAll { $0.email == key }
        profiles.append(profile)
        try save(profiles)
    }

    static func delete(_ email: String) throws {
        let key = email.lowercased()
        var profiles = Array(loadAll().values)
        profiles.removeAll { $0.email == key }
        try save(profiles)
    }

    private static func loadAll() -> [String: AccountProfile] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let profiles = try? JSONDecoder().decode([AccountProfile].self, from: data) else {
            return [:]
        }
        var result: [String: AccountProfile] = [:]
        for profile in profiles {
            let sanitized = sanitizedProfile(profile)
            result[sanitized.email] = sanitized
        }
        return result
    }

    private static func save(_ profiles: [AccountProfile]) throws {
        let sorted = profiles.sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
        let data = try JSONEncoder().encode(sorted)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func inferredName(from email: String) -> String {
        let local = email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? email
        let pieces = local
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .map { String($0).capitalized }
        return pieces.isEmpty ? "Apple Account" : pieces.joined(separator: " ")
    }

    private static func sanitizedProfile(_ profile: AccountProfile) -> AccountProfile {
        let email = profile.email
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .lowercased()
        let name = profile.displayName
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AccountProfile(
            email: String(email.prefix(254)),
            displayName: name.isEmpty ? inferredName(from: email) : String(name.prefix(80))
        )
    }

    private static func removeLegacyProfilePictures() {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return }
        let legacyDirectory = directory
            .appending(path: "app.sideloom.native/Account Profiles", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: legacyDirectory)
    }
}
