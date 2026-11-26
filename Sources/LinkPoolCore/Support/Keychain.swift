import Foundation
import Security

/// Keychain-backed secret storage. One generic-password item per account.
///
/// Ad-hoc signed builds get a new code hash on every rebuild, which makes the
/// item's ACL reject `SecItemCopyMatching` (the system would otherwise show an
/// "allow access" prompt that a menu-bar app cannot reliably present). The
/// `/usr/bin/security` fallback keeps the tool usable across rebuilds without
/// weakening storage to a plain file.
public enum Keychain {
    private static let service = "com.nytsai.linkpool"

    private static func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private static func cli(_ args: [String]) -> String? {
        guard let output = Shell.run("/usr/bin/security", args, timeout: 10) else { return nil }
        return output.trimmingCharacters(in: .newlines)
    }

    @discardableResult
    public static func set(_ value: String, for key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        var q = query(key)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            q.merge(attrs) { _, new in new }
            if SecItemAdd(q as CFDictionary, nil) == errSecSuccess { return true }
        }
        Log.shared.warn("keychain", "SecItem 写入失败 status=\(status)，改用 security 命令")

        // `-U` updates an existing item; the CLI is Apple-signed and its ACL is
        // stable across our rebuilds.
        if Shell.run("/usr/bin/security",
                     ["add-generic-password", "-U", "-s", service, "-a", key, "-w", value],
                     timeout: 10) != nil {
            return true
        }
        Log.shared.error("keychain", "写入钥匙串失败（security 命令也失败）")
        return false
    }

    public static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        // errSecItemNotFound is the only "real" missing-password case; every
        // other status is an access/entitlement problem worth a fallback.
        if status != errSecItemNotFound {
            Log.shared.warn("keychain", "SecItem 读取失败 status=\(status)，尝试 security 命令")
        }
        if let text = cli(["find-generic-password", "-s", service, "-a", key, "-w"]), !text.isEmpty {
            return text
        }
        return nil
    }

    @discardableResult
    public static func delete(_ key: String) -> Bool {
        let status = SecItemDelete(query(key) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return true }
        Log.shared.warn("keychain", "SecItem 删除失败 status=\(status)，改用 security 命令")
        return Shell.run("/usr/bin/security",
                         ["delete-generic-password", "-s", service, "-a", key], timeout: 10) != nil
    }
}
