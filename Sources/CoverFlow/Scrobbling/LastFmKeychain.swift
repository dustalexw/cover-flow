import Foundation
import Security
import LocalAuthentication

struct LastFmKeychain {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.coverflow.lastfm", kSecAttrAccount as String: "credentials"]

    static func load() -> LastFmCredentials? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        // Loading the app must never present an unexpected Keychain dialog.
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(LastFmCredentials.self, from: data)
    }

    static func save(_ credentials: LastFmCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            status = SecItemAdd(q as CFDictionary, nil)
        }
        if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey:
                "Couldn’t save Last.fm credentials in Keychain. \(SecCopyErrorMessageString(status, nil) as String? ?? "Try again.")"])
        }
    }
}
