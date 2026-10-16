import Foundation

/// 管理单个云盘的 access token：过期前 60 秒刷新、并发刷新单飞、
/// 识别另一进程（App/扩展）已经刷新过的 token。
public actor TokenManager {
    public typealias Refresher = @Sendable (_ refreshToken: String) async throws -> Credentials

    private let driveID: String
    private let store: any CredentialStore
    private let refresh: Refresher
    private let now: @Sendable () -> Date
    private var inflight: Task<Credentials, any Error>?

    /// access token 剩余有效期低于该值即刷新。
    static let refreshMargin: TimeInterval = 60

    public init(
        driveID: String,
        store: any CredentialStore,
        now: @escaping @Sendable () -> Date = { Date() },
        refresh: @escaping Refresher
    ) {
        self.driveID = driveID
        self.store = store
        self.now = now
        self.refresh = refresh
    }

    /// 返回可用的 access token，必要时刷新。
    public func accessToken() async throws -> String {
        guard let current = try store.load(driveID: driveID) else { throw CloudreveAPIError.credentialInvalid }
        if current.accessExpires.timeIntervalSince(now()) > Self.refreshMargin {
            return current.accessToken
        }
        return try await refreshNow().accessToken
    }

    /// 服务端以凭证失效拒绝了 `failedToken` 后调用：若存储里已有别的有效 token（另一进程刷新过）直接用，否则刷新。
    public func recover(afterUnauthorizedWith failedToken: String) async throws -> String {
        guard let stored = try store.load(driveID: driveID) else { throw CloudreveAPIError.credentialInvalid }
        if stored.accessToken != failedToken, stored.accessExpires.timeIntervalSince(now()) > Self.refreshMargin {
            return stored.accessToken
        }
        return try await refreshNow().accessToken
    }

    private func refreshNow() async throws -> Credentials {
        if let inflight { return try await inflight.value }
        let task = Task { [driveID, store, refresh, now] in
            guard let current = try store.load(driveID: driveID) else { throw CloudreveAPIError.credentialInvalid }
            guard current.refreshExpires > now() else { throw CloudreveAPIError.credentialInvalid }
            do {
                let renewed = try await refresh(current.refreshToken)
                try store.save(renewed, driveID: driveID)
                return renewed
            } catch let error as CloudreveAPIError {
                if let code = error.serverCode, CloudreveAPIError.credentialCodes.contains(code) {
                    throw CloudreveAPIError.credentialInvalid
                }
                throw error
            }
        }
        inflight = task
        defer { inflight = nil }
        return try await task.value
    }
}
