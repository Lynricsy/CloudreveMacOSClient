import Foundation

/// 当前用户（`GET /user/me`）。
public struct User: Codable, Sendable, Equatable {
    public var id: String
    public var email: String?
    public var nickname: String?
    public var avatar: String?
    public var createdAt: Date?
    public var group: UserGroup?

    public init(
        id: String, email: String? = nil, nickname: String? = nil, avatar: String? = nil,
        createdAt: Date? = nil, group: UserGroup? = nil
    ) {
        self.id = id
        self.email = email
        self.nickname = nickname
        self.avatar = avatar
        self.createdAt = createdAt
        self.group = group
    }

    enum CodingKeys: String, CodingKey {
        case id, email, nickname, avatar, group
        case createdAt = "created_at"
    }
}

/// 用户所在用户组（`/user/me` 的 `group` 字段）。
public struct UserGroup: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// 回收站保留时长（秒）；服务端未下发时为 nil。
    public var trashRetention: Int?

    public init(id: String, name: String, trashRetention: Int? = nil) {
        self.id = id
        self.name = name
        self.trashRetention = trashRetention
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case trashRetention = "trash_retention"
    }
}
