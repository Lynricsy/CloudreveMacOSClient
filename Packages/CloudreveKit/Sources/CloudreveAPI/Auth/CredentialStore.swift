import Foundation

/// 凭证持久化（macOS 上为共享 Keychain，测试为内存）。
///
/// App 与扩展是不同进程，实现方须让 `save`、`delete`、`update` 在同一把（跨进程）锁内互斥。
public protocol CredentialStore: Sendable {
    func load(driveID: String) throws -> Credentials?
    func save(_ credentials: Credentials, driveID: String) throws
    func delete(driveID: String) throws
    /// 原子读改写：在锁内读取当前值并交给 `transform`；返回非 nil 则写入，返回 nil 则不写（也不删除）。
    /// `transform` 抛错时不写，错误原样抛出。返回最终存储中的值（写入时为新值，否则为读到的当前值）。
    func update(driveID: String, _ transform: (Credentials?) throws -> Credentials?) throws -> Credentials?
}
