import Foundation

/// 当前用户（`GET /user/me`）。
public struct User: Codable, Sendable, Equatable {
    public var id: String
    public var email: String?
    public var nickname: String?
    public var avatar: String?

    public init(id: String, email: String? = nil, nickname: String? = nil, avatar: String? = nil) {
        self.id = id
        self.email = email
        self.nickname = nickname
        self.avatar = avatar
    }
}
