import Foundation

/// 设置页概览需要的账号信息。只用 O(1) 或小分页的接口：
/// 不调用 `folder_summary`（服务端会递归遍历整棵目录树，且只缓存 5 分钟）。
public struct AccountOverview: Sendable, Equatable {
    public var user: User
    public var serverVersion: String
    /// 云盘根目录所用的存储策略。
    public var storagePolicy: StoragePolicy?
    public var shares: ShareSummary
    public var trash: PagedCount

    public init(user: User, serverVersion: String, storagePolicy: StoragePolicy?, shares: ShareSummary, trash: PagedCount) {
        self.user = user
        self.serverVersion = serverVersion
        self.storagePolicy = storagePolicy
        self.shares = shares
        self.trash = trash
    }
}

/// 分享统计。`count` 截断时 `visits` 与 `expired` 只含已统计的部分。
public struct ShareSummary: Sendable, Equatable {
    public var count: PagedCount
    /// 累计访问次数。
    public var visits: Int
    public var expired: Int

    public init(count: PagedCount, visits: Int, expired: Int) {
        self.count = count
        self.visits = visits
        self.expired = expired
    }
}

/// 分页计数；超过页数上限时 `isTruncated` 为真，`count` 是下限。
public struct PagedCount: Sendable, Equatable {
    public var count: Int
    public var isTruncated: Bool

    public init(count: Int, isTruncated: Bool = false) {
        self.count = count
        self.isTruncated = isTruncated
    }
}

extension CloudreveClient {
    /// 分享列表最多翻 20 页（每页 100）。
    static let shareMaxPages = 20
    /// 回收站最多翻 5 页（每页 2000，服务端上限）。
    static let trashMaxPages = 5
    static let trashPageSize = 2000

    /// 并发拉取概览所需的各项数据；任一请求失败即整体失败。
    public func accountOverview(rootURI: CloudreveURI) async throws -> AccountOverview {
        async let user = me()
        async let version = ping()
        async let root = listFiles(uri: rootURI, pageSize: 1)
        async let shares = shareStats()
        async let trash = trashCount()
        return try await AccountOverview(
            user: user, serverVersion: version, storagePolicy: root.storagePolicy, shares: shares, trash: trash
        )
    }

    private func shareStats() async throws -> ShareSummary {
        var summary = ShareSummary(count: PagedCount(count: 0, isTruncated: true), visits: 0, expired: 0)
        var token: String?
        for _ in 0..<Self.shareMaxPages {
            let page = try await listShares(pageSize: 100, nextPageToken: token)
            summary.count.count += page.shares.count
            summary.visits += page.shares.reduce(0) { $0 + $1.visited }
            summary.expired += page.shares.count { $0.expired }
            token = page.pagination?.nextToken
            if token?.isEmpty ?? true {
                summary.count.isTruncated = false
                return summary
            }
        }
        return summary
    }

    private func trashCount() async throws -> PagedCount {
        var count = 0
        var token: String?
        for _ in 0..<Self.trashMaxPages {
            let page = try await listFiles(
                uri: CloudreveURI(fs: "trash", segments: []), pageSize: Self.trashPageSize, nextPageToken: token
            )
            count += page.files.count
            token = page.pagination?.nextToken
            if token?.isEmpty ?? true { return PagedCount(count: count) }
        }
        return PagedCount(count: count, isTruncated: true)
    }
}
