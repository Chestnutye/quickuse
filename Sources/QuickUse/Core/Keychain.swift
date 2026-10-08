import Foundation
import Security

/// 钥匙串里的通用密码读写。
enum Keychain {
    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func set(_ secret: String, service: String, account: String) {
        let query = baseQuery(service: service, account: account)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrLabel as String] = "QuickUse: \(account)"
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 只检查条目是否存在，不读取内容，因此不会触发钥匙串授权弹窗。
    static func exists(service: String, account: String) -> Bool {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(service: String, account: String) {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }
}
