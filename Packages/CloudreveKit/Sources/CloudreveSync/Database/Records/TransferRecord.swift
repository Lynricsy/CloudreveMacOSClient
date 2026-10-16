import Foundation
import GRDB

/// `transfer` 表：上传/下载活动，供菜单栏弹窗展示与通知。
public struct TransferRecord: SyncRecord, Equatable, Identifiable {
    public static let databaseTableName = "transfer"

    public var id: String
    public var driveID: String
    public var kind: TransferKind
    public var itemID: String?
    public var name: String
    public var uri: String
    public var totalBytes: Int64
    public var doneBytes: Int64
    public var state: TransferState
    public var error: String?
    public var startedAt: Date
    public var finishedAt: Date?
    public var notified: Bool

    public init(
        id: String, driveID: String, kind: TransferKind, itemID: String?, name: String, uri: String,
        totalBytes: Int64, doneBytes: Int64 = 0, state: TransferState = .running, error: String? = nil,
        startedAt: Date, finishedAt: Date? = nil, notified: Bool = false
    ) {
        self.id = id
        self.driveID = driveID
        self.kind = kind
        self.itemID = itemID
        self.name = name
        self.uri = uri
        self.totalBytes = totalBytes
        self.doneBytes = doneBytes
        self.state = state
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.notified = notified
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, uri, state, error, notified
        case driveID = "drive_id"
        case itemID = "item_id"
        case totalBytes = "total_bytes"
        case doneBytes = "done_bytes"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}
