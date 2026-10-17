import Foundation

/// `GET /share` 响应：当前用户创建的分享（游标分页）。
public struct ShareListResponse: Codable, Sendable, Equatable {
    public var shares: [Share]
    public var pagination: Pagination?

    public init(shares: [Share], pagination: Pagination? = nil) {
        self.shares = shares
        self.pagination = pagination
    }

    enum CodingKeys: String, CodingKey {
        case shares, pagination
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 没有分享时服务端返回 `"shares": null`。
        shares = try container.decodeIfPresent([Share].self, forKey: .shares) ?? []
        pagination = try container.decodeIfPresent(Pagination.self, forKey: .pagination)
    }
}

/// 一条分享链接（只保留统计用到的字段）。
public struct Share: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// 访问次数。
    public var visited: Int
    public var expired: Bool

    public init(id: String, name: String, visited: Int = 0, expired: Bool = false) {
        self.id = id
        self.name = name
        self.visited = visited
        self.expired = expired
    }

    enum CodingKeys: String, CodingKey {
        case id, name, visited, expired
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        visited = try container.decodeIfPresent(Int.self, forKey: .visited) ?? 0
        expired = try container.decodeIfPresent(Bool.self, forKey: .expired) ?? false
    }
}
