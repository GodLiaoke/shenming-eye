import Foundation
import Security

enum KeychainStore {
#if os(macOS)
    private static let service = "com.myrader.val.codev.mac.secure"
#else
    private static let service = "com.myrader.val.codev.secure"
#endif

    static func read(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func write(_ data: Data, account: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = identity
            insert.merge(update) { _, new in new }
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else { throw KeychainError.status(insertStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .status(code):
                return "钥匙串写入失败（OSStatus \(code)\(code == -34018 ? "：缺 keychain-access-groups 权限，多半是签名工具改过 entitlements" : "")）"
            }
        }
    }
}

/// 带"文件兜底"的凭据存储。
///
/// 为什么需要：钥匙串在少数环境下会写不进去 ——
///   · 模拟器 / 没签名的包：errSecMissingEntitlement (-34018)
///   · 签名工具改过 entitlements：同样报 -34018
/// 以前这里一失败就直接抛错，**激活明明成功了却告诉客户失败**（2026-10-04 实测就踩到）。
/// 现在：钥匙串优先；写不进去就退回 App 沙盒里的文件（Application Support），保证激活能走完。
enum SecureStore {
    static func write(_ data: Data, account: String) {
        do {
            try KeychainStore.write(data, account: account)
            removeFallback(account)
        } catch {
            // 钥匙串不行 → 落文件，别让客户卡在"激活失败"
            #if DEBUG
            print("[SecureStore] 钥匙串写入失败，改用文件兜底：\(error.localizedDescription)")
            #endif
            try? data.write(to: fallbackURL(account), options: .atomic)
        }
    }

    static func read(_ account: String) -> Data? {
        if let data = KeychainStore.read(account) { return data }
        return try? Data(contentsOf: fallbackURL(account))
    }

    static func delete(_ account: String) {
        KeychainStore.delete(account)
        removeFallback(account)
    }

    private static func fallbackURL(_ account: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("phoenix-\(account).bin")
    }

    private static func removeFallback(_ account: String) {
        try? FileManager.default.removeItem(at: fallbackURL(account))
    }
}
