import CloudreveAPI
import Foundation
import Security

/// Keychain 操作失败。
enum KeychainError: Error, LocalizedError {
    case status(OSStatus)
    case lock(Int32)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "钥匙串错误 \(status)：\(message)"
        case .lock(let code):
            return "凭证锁文件错误 \(code)：\(String(cString: strerror(code)))"
        }
    }
}

/// 共享访问组中的凭证存储：App 与扩展读写同一条目，任一方刷新 token 另一方立即可见。
///
/// 写操作（save / delete / update）在 App Group 容器内锁文件的 `flock` 排他锁内执行，App 与扩展进程、
/// 同进程内的多个线程互斥，保证 `update` 的读改写不会被另一方的写入穿插。读操作不加锁（单条读取本身原子）。
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
        try Self.withLock { try write(credentials, driveID: driveID) }
    }

    func delete(driveID: String) throws {
        try Self.withLock {
            let status = SecItemDelete(baseQuery(driveID: driveID) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
        }
    }

    /// 锁内读当前值 → `transform`；结果非 nil 则写入并返回新值，nil 则不写、返回读到的当前值。`transform` 抛错时不写。
    func update(driveID: String, _ transform: (Credentials?) throws -> Credentials?) throws -> Credentials? {
        try Self.withLock {
            let current = try load(driveID: driveID)
            guard let next = try transform(current) else { return current }
            try write(next, driveID: driveID)
            return next
        }
    }

    /// 调用方须已持有锁。
    private func write(_ credentials: Credentials, driveID: String) throws {
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

    private func baseQuery(driveID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: driveID,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    // MARK: - 跨进程锁

    /// App 与扩展共用的锁文件（App Group 容器内，与数据库同目录）。
    private static let lockPath = AppGroupPaths.databaseURL.deletingLastPathComponent()
        .appending(path: "credentials.lock", directoryHint: .notDirectory).path(percentEncoded: false)

    /// 每次打开新的文件描述：`flock` 锁属于打开的文件描述，因此同进程不同线程之间同样互斥；关闭描述即释放锁，
    /// 进程崩溃时由内核释放，不会遗留死锁。
    private static func withLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw KeychainError.lock(errno) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw KeychainError.lock(errno) }
        }
        return try body()
    }
}
