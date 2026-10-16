import Foundation

/// `POST /session/token/refresh` 响应（时间为 RFC3339）。
public struct RefreshResponse: Decodable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var accessExpires: Date
    public var refreshExpires: Date

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accessExpires = "access_expires"
        case refreshExpires = "refresh_expires"
    }
}
