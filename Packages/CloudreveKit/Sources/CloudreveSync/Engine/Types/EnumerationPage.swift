import Foundation

/// 目录枚举的一页。`nextToken == nil` 表示最后一页。
public struct EnumerationPage: Sendable {
    public var items: [SyncItem]
    public var nextToken: String?

    public init(items: [SyncItem], nextToken: String?) {
        self.items = items
        self.nextToken = nextToken
    }
}
