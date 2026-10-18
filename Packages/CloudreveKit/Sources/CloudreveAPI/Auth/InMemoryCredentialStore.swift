import Foundation
import Synchronization

/// 内存凭证存储（测试；App 授权时用它隔离校验新凭证，校验通过后才写入共享钥匙串）。
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

    public func update(driveID: String, _ transform: (Credentials?) throws -> Credentials?) throws -> Credentials? {
        try storage.withLock { storage in
            guard let next = try transform(storage[driveID]) else { return storage[driveID] }
            storage[driveID] = next
            return next
        }
    }
}
