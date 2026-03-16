import Foundation
import Security

/// Thin wrapper around the macOS Keychain for storing API keys.
/// Service: "com.shadow.app.llm", Account: provider-specific (e.g. "anthropic-api-key").
///
/// When running inside XCTest, all operations are no-ops that return nil/false.
/// This prevents the macOS Keychain password prompt that fires on ad-hoc-signed
/// test binaries (each rebuild changes the code signature, invalidating any
/// prior "Always Allow" grants).
enum KeychainHelper {

    /// True when the process is hosted by XCTest (xctest or Xcode test runner).
    /// Evaluated once and cached.
    private static let isRunningTests: Bool = {
        NSClassFromString("XCTestCase") != nil
    }()

    /// Save data to the Keychain. Overwrites if the item already exists.
    static func save(service: String, account: String, data: Data) -> Bool {
        guard !isRunningTests else { return false }

        // Delete existing item first (update semantics)
        delete(service: service, account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Load data from the Keychain. Returns nil if not found.
    static func load(service: String, account: String) -> Data? {
        guard !isRunningTests else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Delete an item from the Keychain.
    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        guard !isRunningTests else { return true }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
