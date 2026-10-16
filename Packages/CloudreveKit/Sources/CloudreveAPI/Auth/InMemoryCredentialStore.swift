import Foundation
import Synchronization

/// 内存凭证存储（测试用）。
public final class InMemoryCredentialStore: CredentialStore {
    private let storage = Mutex<[String: Credentials]>([:])

    public init(_ initial: [String: Credentials] = [:]) {
        storage.withLock { $0 = initial }
    }

    public func load(driveID: String) throws -> Credentials? {
        storage.withLock { $0[driveID] }
    }

    public func save(_ credentials: Credentials, driveID: String) throws {
        storage.withLock { $0[driveID] = credentials }
    }

    public func delete(driveID: String) throws {
        _ = storage.withLock { $0.removeValue(forKey: driveID) }
    }
}
