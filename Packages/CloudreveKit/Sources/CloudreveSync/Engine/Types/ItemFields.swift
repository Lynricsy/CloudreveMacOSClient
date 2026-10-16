import Foundation

/// 与 NSFileProviderItemFields 一一对应的字段集合（引擎不依赖 FileProvider 框架）。
public struct ItemFields: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let filename = ItemFields(rawValue: 1 << 0)
    public static let contents = ItemFields(rawValue: 1 << 1)
    public static let parent = ItemFields(rawValue: 1 << 2)
    public static let contentModificationDate = ItemFields(rawValue: 1 << 3)
    public static let creationDate = ItemFields(rawValue: 1 << 4)
    public static let lastUsedDate = ItemFields(rawValue: 1 << 5)
    public static let extendedAttributes = ItemFields(rawValue: 1 << 6)
    public static let fileSystemFlags = ItemFields(rawValue: 1 << 7)
    public static let tagData = ItemFields(rawValue: 1 << 8)
    public static let favoriteRank = ItemFields(rawValue: 1 << 9)
    public static let typeAndCreator = ItemFields(rawValue: 1 << 10)

    /// 需要与服务端同步的字段；其余字段（日期、xattr、标签…）视为本地即已应用。
    public static let synced: ItemFields = [.filename, .parent, .contents]
}
