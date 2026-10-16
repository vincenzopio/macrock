import Foundation
import Security

extension Account {
    /// Whether xodus-service's `credentials` item exists. Asking for attributes never prompts,
    /// but a locked keychain can block the call, so it runs on a dedicated thread.
    public func hasCredentials() async throws -> Bool {
        let keychainService = keychainService
        return try await runOnDedicatedThread {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: "credentials",
                kSecReturnAttributes as String: true,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status != errSecItemNotFound else { return false }
            guard status == errSecSuccess else { throw KeychainError(status: status) }
            return true
        }
    }
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}
