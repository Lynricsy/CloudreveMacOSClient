import Foundation
import Testing
import Synchronization
@testable import CloudreveAPI

@Suite struct TokenManagerTests {
    @Test func concurrentAccessTokenRefreshesOnce() async throws {
        let store = InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials(accessIn: 10)])
        let refreshes = Counter()
        let manager = TokenManager(driveID: Fixtures.driveID, store: store) { _ in
            _ = await refreshes.increment()
            try await Task.sleep(for: .milliseconds(50))
            return Fixtures.credentials(access: "fresh")
        }
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 { group.addTask { try await manager.accessToken() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(tokens == Array(repeating: "fresh", count: 10))
        #expect(await refreshes.current == 1)
    }

    @Test func recoverUsesTokenRefreshedByOtherProcess() async throws {
        let store = InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials(access: "other-process")])
        let refreshes = Counter()
        let manager = TokenManager(driveID: Fixtures.driveID, store: store) { _ in
            _ = await refreshes.increment()
            return Fixtures.credentials(access: "fresh")
        }
        let token = try await manager.recover(afterUnauthorizedWith: "stale")
        #expect(token == "other-process")
        #expect(await refreshes.current == 0)
    }

    @Test func expiredRefreshTokenIsInvalid() async throws {
        let store = InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials(accessIn: -10, refreshIn: -10)])
        let manager = TokenManager(driveID: Fixtures.driveID, store: store) { _ in Fixtures.credentials(access: "never") }
        await #expect(throws: CloudreveAPIError.credentialInvalid) {
            _ = try await manager.accessToken()
        }
    }

    @Test func missingCredentialsIsInvalid() async throws {
        let manager = TokenManager(driveID: "none", store: InMemoryCredentialStore()) { _ in Fixtures.credentials() }
        await #expect(throws: CloudreveAPIError.credentialInvalid) {
            _ = try await manager.accessToken()
        }
    }

    @Test func lateRefreshDoesNotOverwriteReauthorizedCredentials() async throws {
        let store = InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials(accessIn: 10)])
        let reauthorized = Fixtures.credentials(access: "reauthorized")
        let manager = TokenManager(driveID: Fixtures.driveID, store: store) { _ in
            // 刷新请求在途时另一进程重新授权写入了新凭证，随后旧刷新结果才返回
            try store.save(reauthorized, driveID: Fixtures.driveID)
            return Fixtures.credentials(access: "late")
        }
        #expect(try await manager.accessToken() == "reauthorized")
        #expect(try store.load(driveID: Fixtures.driveID) == reauthorized)
    }

    @Test func lateRefreshDoesNotResurrectDeletedCredentials() async throws {
        let store = InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials(accessIn: 10)])
        let manager = TokenManager(driveID: Fixtures.driveID, store: store) { _ in
            // 刷新请求在途时用户移除了云盘
            try store.delete(driveID: Fixtures.driveID)
            return Fixtures.credentials(access: "late")
        }
        await #expect(throws: CloudreveAPIError.credentialInvalid) {
            _ = try await manager.accessToken()
        }
        #expect(try store.load(driveID: Fixtures.driveID) == nil)
    }

    /// 替换发生在写回过程中：刷新结果已返回、写回前的检查之后，另一进程才写入新授权。
    @Test func reauthorizationDuringWritebackIsNotOverwritten() async throws {
        let store = RacingCredentialStore([Fixtures.driveID: Fixtures.credentials(accessIn: 10)])
        let reauthorized = Fixtures.credentials(access: "reauthorized")
        store.interjectBeforeNextWrite { $0[Fixtures.driveID] = reauthorized }
        let manager = TokenManager(driveID: Fixtures.driveID, store: store) { _ in Fixtures.credentials(access: "late") }
        #expect(try await manager.accessToken() == "reauthorized")
        #expect(try store.load(driveID: Fixtures.driveID) == reauthorized)
    }

    /// 删除发生在写回过程中：迟到的刷新结果不得复活已删除的凭证。
    @Test func deletionDuringWritebackIsNotResurrected() async throws {
        let store = RacingCredentialStore([Fixtures.driveID: Fixtures.credentials(accessIn: 10)])
        store.interjectBeforeNextWrite { $0[Fixtures.driveID] = nil }
        let manager = TokenManager(driveID: Fixtures.driveID, store: store) { _ in Fixtures.credentials(access: "late") }
        await #expect(throws: CloudreveAPIError.credentialInvalid) {
            _ = try await manager.accessToken()
        }
        #expect(try store.load(driveID: Fixtures.driveID) == nil)
    }

    @Test func refreshWritesBackWhenUnchanged() async throws {
        let store = InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials(accessIn: 10)])
        let fresh = Fixtures.credentials(access: "fresh")
        let manager = TokenManager(driveID: Fixtures.driveID, store: store) { _ in fresh }
        #expect(try await manager.accessToken() == "fresh")
        #expect(try store.load(driveID: Fixtures.driveID) == fresh)
    }
}

/// 模拟另一进程在「本进程写入提交之前的最后时刻」改写存储。
///
/// 一次性的 `interjection` 在下一次写操作的临界区内、本进程读取与写入之前执行：
/// 对 `save` 而言即「检查之后、写入之前」被抢先；对原子 `update` 而言即另一进程恰在拿到锁前完成写入，
/// 这是互斥下唯一合法的交错，`transform` 必须看到它。
final class RacingCredentialStore: CredentialStore {
    private struct State {
        var values: [String: Credentials]
        var interjection: (@Sendable (inout [String: Credentials]) -> Void)?
    }

    private let state: Mutex<State>

    init(_ initial: [String: Credentials]) {
        state = Mutex(State(values: initial))
    }

    func interjectBeforeNextWrite(_ interjection: @escaping @Sendable (inout [String: Credentials]) -> Void) {
        state.withLock { $0.interjection = interjection }
    }

    func load(driveID: String) throws -> Credentials? {
        state.withLock { $0.values[driveID] }
    }

    func save(_ credentials: Credentials, driveID: String) throws {
        state.withLock { state in
            Self.interject(&state)
            state.values[driveID] = credentials
        }
    }

    func delete(driveID: String) throws {
        _ = state.withLock { $0.values.removeValue(forKey: driveID) }
    }

    func update(driveID: String, _ transform: (Credentials?) throws -> Credentials?) throws -> Credentials? {
        try state.withLock { state in
            Self.interject(&state)
            guard let next = try transform(state.values[driveID]) else { return state.values[driveID] }
            state.values[driveID] = next
            return next
        }
    }

    private static func interject(_ state: inout State) {
        guard let interjection = state.interjection else { return }
        state.interjection = nil
        interjection(&state.values)
    }
}
