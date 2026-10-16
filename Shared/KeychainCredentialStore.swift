import CloudreveAPI
import Foundation
import Security

/// Keychain 操作失败。
enum KeychainError: Error, LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "钥匙串错误 \(status)：\(message)"
        }
    }
}

/// 共享访问组中的凭证存储：App 与扩展读写同一条目，任一方刷新 token 另一方立即可见。
final class KeychainCredentialStore: CredentialStore {
    static let service = "plus.ling.cloudreve.credentials"
    static let accessGroupSuffix = "plus.ling.cloudreve.shared"

    /// `<AppIdentifierPrefix>plus.ling.cloudreve.shared`；前缀由 Info.plist 的 `AppIdentifierPrefix` 提供（已含末尾点号）。
    private let accessGroup: String

    init(bundle: Bundle = .main) {
        let prefix = bundle.infoDictionary?["AppIdentifierPrefix"] as? String ?? ""
        accessGroup = prefix + Self.accessGroupSuffix
    }

    func load(driveID: String) throws -> Credentials? {
        var query = baseQuery(driveID: driveID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.status(status) }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    func save(_ credentials: Credentials, driveID: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery(driveID: driveID) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.status(updateStatus) }
        var item = baseQuery(driveID: driveID)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
    }

    func delete(driveID: String) throws {
        let status = SecItemDelete(baseQuery(driveID: driveID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    private func baseQuery(driveID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: driveID,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}
