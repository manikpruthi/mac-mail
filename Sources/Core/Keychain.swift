import Foundation
import Security

/// A Keychain write or delete that macOS refused (for example a denied access-control prompt).
struct KeychainError: Error, LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
        return "Couldn't \(operation) the password in the Keychain: \(detail)"
    }
}

/// Stores account passwords (Gmail App Passwords) in the login Keychain. Nothing secret touches disk otherwise.
enum Keychain {
    private static let service = "com.manikpruthi.macmail"

    private static func base(_ accountID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
    }

    /// Saves (or replaces) the password. The existing item is updated in place, so a refused write can never
    /// delete the password that was already stored; the caller learns about the failure instead (B-08).
    static func set(_ password: String, for accountID: String) throws {
        let data = Data(password.utf8)
        let query = base(accountID)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status, operation: "update") }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added, operation: "save") }
    }

    static func get(_ accountID: String) -> String? {
        var query = base(accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ accountID: String) {
        SecItemDelete(base(accountID) as CFDictionary)
    }
}
