import Foundation
import Security

/// What the Mac keeps after pairing. The relay stores only a SHA-256 of `token`.
struct DeviceCredentials: Codable, Equatable {
    var relayURL: String
    var deviceID: String
    var token: String
}

enum Keychain {
    private static let service = "com.neversleep.app.device"
    private static let account = "relay"

    static func load() -> DeviceCredentials? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(DeviceCredentials.self, from: data)
    }

    @discardableResult
    static func save(_ creds: DeviceCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(creds) else { return false }
        delete()
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
