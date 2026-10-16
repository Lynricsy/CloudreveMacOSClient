import Foundation

/// 凭证持久化（macOS 上为共享 Keychain，测试为内存）。
public protocol CredentialStore: Sendable {
    func load(driveID: String) throws -> Credentials?
    func save(_ credentials: Credentials, driveID: String) throws
    func delete(driveID: String) throws
}
