import Foundation
import Security
import LocalAuthentication

enum KeychainStore {
    private static let service = "app.sideloom.native.apple-accounts"

    static func accounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return [] }
        let items = result as? [[String: Any]] ?? []
        let accounts = items
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for account in accounts {
            let identity: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemUpdate(
                identity as CFDictionary,
                [kSecAttrLabel as String: "Slip Apple Account"] as CFDictionary
            )
        }
        return accounts
    }

    static func password(for account: String) throws -> String {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [trimmed, trimmed.lowercased(), account]
        for candidate in candidates {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: candidate,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess,
               let data = result as? Data,
               let password = String(data: data, encoding: .utf8) {
                return password
            }
        }

        // Case-insensitive fallback among stored accounts
        for existing in accounts() {
            if existing.caseInsensitiveCompare(trimmed) == .orderedSame {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: existing,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecSuccess,
                   let data = result as? Data,
                   let password = String(data: data, encoding: .utf8) {
                    return password
                }
            }
        }

        throw SideloomError.message("The saved password is unavailable. Remove and add this account again.")
    }

    static func backgroundPasswordQuery(for account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service,
         kSecAttrAccount as String:account, kSecReturnData as String:true,
         kSecMatchLimit as String:kSecMatchLimitOne, kSecUseAuthenticationContext as String:context]
    }
    /// No authorization UI, attribute updates or account enumeration in a worker.
    static func backgroundPassword(for account: String) throws -> String {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        for candidate in Set([account,trimmed,trimmed.lowercased()]) {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(backgroundPasswordQuery(for: candidate) as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, let password = String(data:data,encoding:.utf8) { return password }
            if status != errSecItemNotFound { break }
        }
        throw SideloomError.message("Open Slip to unlock or authorize the saved Apple Account password.")
    }

    static func save(account: String, password: String) throws {
        let normalized = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let data = Data(password.utf8)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: normalized
        ]
        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrLabel as String: "Slip Apple Account"
            ] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw osStatusError(updateStatus, action: "update")
        }
        var item = identity
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Slip Apple Account"
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw osStatusError(addStatus, action: "save")
        }
    }

    static func delete(account: String) throws {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        var targetsToDelete = Set<String>([account, trimmed, normalized])

        // Find any existing accounts that match case-insensitively
        for existing in accounts() {
            if existing.caseInsensitiveCompare(trimmed) == .orderedSame {
                targetsToDelete.insert(existing)
            }
        }

        var lastError: SideloomError?
        for target in targetsToDelete {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: target
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                lastError = osStatusError(status, action: "delete")
            }
        }
        if let lastError {
            throw lastError
        }
    }

    /// Invalidate the core's session without reading its authentication token.
    static func deleteDeveloperSession(storageURL: URL) throws {
        let metadataURL = storageURL.appendingPathComponent("dev_session.json")
        var deletionError: SideloomError?
        if let data = try? Data(contentsOf: metadataURL),
           let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let reference = metadata["keychainReference"] as? String,
           !reference.isEmpty {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.slip.authentication.developer-session",
                kSecAttrAccount as String: reference
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                deletionError = osStatusError(status, action: "remove the developer session")
            }
        }
        // Deleting metadata invalidates the session even when Keychain is locked.
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            try FileManager.default.removeItem(at: metadataURL)
        }
        if let deletionError { throw deletionError }
    }

    private static func osStatusError(_ status: OSStatus, action: String) -> SideloomError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .message("Unable to \(action) the credential in macOS Keychain: \(detail)")
    }
}
