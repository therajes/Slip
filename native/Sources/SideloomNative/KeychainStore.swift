import Foundation
import Security

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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw SideloomError.message("The saved password is unavailable. Remove and add this account again.")
        }
        return password
    }

    static func save(account: String, password: String) throws {
        let data = Data(password.utf8)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw osStatusError(status, action: "delete")
        }
    }

    private static func osStatusError(_ status: OSStatus, action: String) -> SideloomError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .message("Unable to \(action) the credential in macOS Keychain: \(detail)")
    }
}
