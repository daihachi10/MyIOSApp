import Foundation
import Security

enum KeychainStore {
    private static let service = "com.daihachi10.MyIOSApp.ssh"

    static func loadPassword() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func savePassword(_ password: String) throws {
        let delete: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(delete as CFDictionary)
        guard !password.isEmpty else { return }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecValueData as String: Data(password.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unableToSave(status) }
    }
}

enum KeychainError: LocalizedError { case unableToSave(OSStatus); var errorDescription: String? { "SSHパスワードをKeychainへ保存できませんでした" } }
