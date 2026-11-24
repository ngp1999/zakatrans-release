import Foundation
import Security

/// 设备标识和账号凭据存在钥匙串：删 App 重装也还在，同一台设备不会重复建号。
enum Keychain {
    private static let service = "com.zakatrans.livecap"

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    /// 首次启动生成一个稳定的设备号；重装后从这里读回同一个
    static func deviceID() -> String {
        if let v = get("device_id"), v.count >= 16 { return v }
        let v = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        set(v, for: "device_id")
        return v
    }
}
