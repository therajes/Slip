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
              image.size.width > 0,
              image.size.height > 0,
              let png = normalizedProfilePNG(from: image) else {
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

    /// Stores a small, square copy rather than retaining an arbitrarily large source image.
    /// This keeps account rows predictable and avoids decoding a multi-megapixel photo on
    /// every redraw.
    private static func normalizedProfilePNG(from image: NSImage) -> Data? {
        let pixels = 512
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        let width = image.size.width
        let height = image.size.height
        let side = min(width, height)
        let source = NSRect(
            x: (width - side) / 2,
            y: (height - side) / 2,
            width: side,
            height: side
        )
        let destination = NSRect(x: 0, y: 0, width: pixels, height: pixels)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.setFill()
        destination.fill()
        image.draw(
            in: destination,
            from: source,
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
