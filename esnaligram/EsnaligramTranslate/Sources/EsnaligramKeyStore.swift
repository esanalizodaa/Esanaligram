import Foundation
import Security

/// Kullanıcının kendi DeepInfra anahtarı (iOS Keychain). Yoksa derlemeye gömülü anahtar.
public enum EsnaligramKeyStore {
    static let service = "esnaligram.deepinfra"
    static let account = "apiKey"
    public static var userKey: String? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
                  let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
            return s
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
            SecItemDelete(base as CFDictionary)
            guard let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(v.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
    public static func effectiveKey(embedded: String) -> String? {
        if let k = userKey { return k }
        let e = embedded.trimmingCharacters(in: .whitespacesAndNewlines)
        return (e.isEmpty || e.hasPrefix("__")) ? nil : e
    }
}
