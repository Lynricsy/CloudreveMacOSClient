import Foundation

/// `modify` 的结果：`pendingFields` 为仍未应用、需系统稍后重试的字段。
public struct ModifyResult: Sendable {
    public var item: SyncItem
    public var pendingFields: ItemFields
    public var shouldFetchContent: Bool

    public init(item: SyncItem, pendingFields: ItemFields, shouldFetchContent: Bool) {
        self.item = item
        self.pendingFields = pendingFields
        self.shouldFetchContent = shouldFetchContent
    }
}
