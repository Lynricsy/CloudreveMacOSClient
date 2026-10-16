import Foundation
import GRDB

/// `change_log` 表：File Provider 变更枚举的数据源，`seq` 即 sync anchor。
public struct ChangeLogRecord: SyncRecord, Equatable {
    public static let databaseTableName = "change_log"

    /// 自增序号；插入前为 nil。
    public var seq: Int64?
    public var driveID: String
    public var itemID: String
    public var kind: ChangeKind
    public var createdAt: Date

    public init(seq: Int64? = nil, driveID: String, itemID: String, kind: ChangeKind, createdAt: Date) {
        self.seq = seq
        self.driveID = driveID
        self.itemID = itemID
        self.kind = kind
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case seq, kind
        case driveID = "drive_id"
        case itemID = "item_id"
        case createdAt = "created_at"
    }
}
