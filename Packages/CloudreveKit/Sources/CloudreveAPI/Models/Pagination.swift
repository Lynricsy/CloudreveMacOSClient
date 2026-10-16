import Foundation

/// 列目录分页信息。游标分页时 `nextToken` 为空表示最后一页。
public struct Pagination: Codable, Sendable, Equatable {
    public var page: Int
    public var pageSize: Int
    public var totalItems: Int?
    public var nextToken: String?
    public var isCursor: Bool

    public init(page: Int = 0, pageSize: Int, totalItems: Int? = nil, nextToken: String? = nil, isCursor: Bool = true) {
        self.page = page
        self.pageSize = pageSize
        self.totalItems = totalItems
        self.nextToken = nextToken
        self.isCursor = isCursor
    }

    enum CodingKeys: String, CodingKey {
        case page
        case pageSize = "page_size"
        case totalItems = "total_items"
        case nextToken = "next_token"
        case isCursor = "is_cursor"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = try container.decodeIfPresent(Int.self, forKey: .page) ?? 0
        pageSize = try container.decodeIfPresent(Int.self, forKey: .pageSize) ?? 0
        totalItems = try container.decodeIfPresent(Int.self, forKey: .totalItems)
        nextToken = try container.decodeIfPresent(String.self, forKey: .nextToken)
        isCursor = try container.decodeIfPresent(Bool.self, forKey: .isCursor) ?? false
    }
}
