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
            let renewed: Credentials
            do {
                renewed = try await refresh(current.refreshToken)
            } catch let error as CloudreveAPIError {
                // 旧 refresh token 被拒可能是另一进程已重新授权：存储里已有新凭证则直接使用
                if let replaced = try Self.replacement(of: current, in: store, driveID: driveID) { return replaced }
                if let code = error.serverCode, CloudreveAPIError.credentialCodes.contains(code) {
                    throw CloudreveAPIError.credentialInvalid
                }
                throw error
            }
            // 刷新在途期间凭证可能已被另一进程重新授权或随云盘移除：在存储锁内比对后再写回，
            // 迟到的结果不得覆盖新凭证（改用新凭证）或复活已删除的条目（抛凭证失效）。
            let stored = try store.update(driveID: driveID) { latest in
                guard let latest else { throw CloudreveAPIError.credentialInvalid }
                return latest.refreshToken == current.refreshToken ? renewed : nil
            }
            guard let stored else { throw CloudreveAPIError.credentialInvalid }
            return stored
        }
        inflight = task
        defer { inflight = nil }
        return try await task.value
    }

    /// 重新读取存储：refresh token 已被替换时返回新凭证；条目已删除时抛 `.credentialInvalid`；未变化返回 nil。
    private static func replacement(of used: Credentials, in store: any CredentialStore, driveID: String) throws -> Credentials? {
        guard let latest = try store.load(driveID: driveID) else { throw CloudreveAPIError.credentialInvalid }
        return latest.refreshToken == used.refreshToken ? nil : latest
    }
}
