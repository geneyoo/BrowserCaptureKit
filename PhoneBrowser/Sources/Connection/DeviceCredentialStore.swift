import Foundation
import Security

/// Pairing outcome. Stored in the Keychain; never exported.
struct DeviceCredential: Codable, Equatable {
    let relayURL: URL
    let deviceID: String
    let token: String

    private enum CodingKeys: String, CodingKey {
        case relayURL = "relayUrl"
        case deviceID = "deviceId"
        case token
    }

    /// `/v1/device` on the relay, over `ws` or `wss` to match the pairing URL.
    var webSocketURL: URL? {
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)
        components?.scheme = relayURL.scheme == "https" ? "wss" : "ws"
        components?.path = "/v1/device"
        components?.query = nil
        return components?.url
    }
}

enum DeviceCredentialStore {
    private static let service = "com.geneyoo.phonebrowser.device"
    private static let account = "relay"

    static func load() -> DeviceCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(DeviceCredential.self, from: data)
    }

    static func save(_ credential: DeviceCredential) throws {
        let data = try JSONEncoder().encode(credential)
        clear()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
