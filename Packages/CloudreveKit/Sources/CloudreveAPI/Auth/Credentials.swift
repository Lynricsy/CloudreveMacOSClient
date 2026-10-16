import Foundation

/// 一个云盘的登录凭证。
public struct Credentials: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var accessExpires: Date
    public var refreshExpires: Date

    /// desktop client 默认 refresh token 有效期：90 天。
    public static let defaultRefreshLifetime = 7_776_000

    public init(accessToken: String, refreshToken: String, accessExpires: Date, refreshExpires: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessExpires = accessExpires
        self.refreshExpires = refreshExpires
    }

    /// 由 OAuth 换 token 响应计算绝对过期时间。
    public init(oauth: OAuthTokenResponse, now: Date) throws {
        guard let refreshToken = oauth.refreshToken, !refreshToken.isEmpty else {
            throw CloudreveAPIError.missingRefreshToken
        }
        self.init(
            accessToken: oauth.accessToken,
            refreshToken: refreshToken,
            accessExpires: now.addingTimeInterval(TimeInterval(oauth.expiresIn)),
            refreshExpires: now.addingTimeInterval(TimeInterval(oauth.refreshTokenExpiresIn ?? Self.defaultRefreshLifetime))
        )
    }

    init(refresh: RefreshResponse) {
        self.init(
            accessToken: refresh.accessToken,
            refreshToken: refresh.refreshToken,
            accessExpires: refresh.accessExpires,
            refreshExpires: refresh.refreshExpires
        )
    }
}
