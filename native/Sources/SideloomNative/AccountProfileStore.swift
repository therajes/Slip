import AppKit
import CryptoKit
import Foundation

struct AccountProfile: Codable, Hashable, Identifiable {
    let email: String
    var displayName: String
    var imagePath: String?

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
        let saved: [AccountProfile]
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([AccountProfile].self, from: data) {
            saved = decoded
        } else {
            saved = []
        }

        let savedByEmail = Dictionary(uniqueKeysWithValues: saved.map { ($0.email.lowercased(), $0) })
        return Dictionary(uniqueKeysWithValues: accounts.map { email in
            let key = email.lowercased()
            return (key, savedByEmail[key] ?? AccountProfile(
                email: key,
                displayName: inferredName(from: key),
                imagePath: nil
            ))
        })
    }

    static func upsert(
        email: String,
        displayName: String?,
        imageURL: URL? = nil
    ) throws {
        let key = email.lowercased()
        var profiles = Array(loadAll().values)
        var profile = profiles.first(where: { $0.email == key }) ?? AccountProfile(
            email: key,
            displayName: inferredName(from: key),
            imagePath: nil
        )

        if let displayName {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { profile.displayName = trimmed }
        }
        if let imageURL {
            profile.imagePath = try persistImage(from: imageURL, for: key).path
        }

        profiles.removeAll { $0.email == key }
        profiles.append(profile)
        try save(profiles)
    }

    static func removeImage(for email: String) throws {
        let key = email.lowercased()
        var profiles = Array(loadAll().values)
        guard let index = profiles.firstIndex(where: { $0.email == key }) else { return }
        if let imagePath = profiles[index].imagePath {
            try? FileManager.default.removeItem(atPath: imagePath)
        }
        profiles[index].imagePath = nil
        try save(profiles)
    }

    static func delete(_ email: String) throws {
        let key = email.lowercased()
        var profiles = Array(loadAll().values)
        if let imagePath = profiles.first(where: { $0.email == key })?.imagePath {
            try? FileManager.default.removeItem(atPath: imagePath)
        }
        profiles.removeAll { $0.email == key }
        try save(profiles)
    }

    private static func loadAll() -> [String: AccountProfile] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let profiles = try? JSONDecoder().decode([AccountProfile].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: profiles.map { ($0.email.lowercased(), $0) })
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

    private static func persistImage(from source: URL, for email: String) throws -> URL {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: source),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SideloomError.message("The selected profile picture could not be read.")
        }

        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "app.sideloom.native/Account Profiles", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
        let destination = directory.appending(path: "\(digest).png")
        try png.write(to: destination, options: .atomic)
        return destination
    }
}
