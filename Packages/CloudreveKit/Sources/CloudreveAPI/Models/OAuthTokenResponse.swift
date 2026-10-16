import Foundation

/// `POST /session/oauth/token` 响应。
public struct OAuthTokenResponse: Codable, Sendable, Equatable {
    public var accessToken: String
    public var tokenType: String?
    /// 秒。
    public var expiresIn: Int
    /// 秒。
    public var refreshTokenExpiresIn: Int?
    public var refreshToken: String?
    public var scope: String?

    public init(
        accessToken: String, tokenType: String? = "Bearer", expiresIn: Int,
        refreshTokenExpiresIn: Int? = nil, refreshToken: String?, scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.refreshTokenExpiresIn = refreshTokenExpiresIn
        self.refreshToken = refreshToken
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey {
        case scope
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case refreshToken = "refresh_token"
    }
}
