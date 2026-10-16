import Foundation
import GRDB

/// 云盘（`drive` 表）的读写。
public struct DriveStore: Sendable {
    private let db: any DatabaseWriter
    private let now: @Sendable () -> Date

    public init(db: any DatabaseWriter, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.now = now
    }

    /// 全部云盘，按添加时间升序。
    public func all() throws -> [DriveRecord] {
        try db.read { db in try DriveRecord.order(Column("created_at"), Column("id")).fetchAll(db) }
    }

    public func get(id: String) throws -> DriveRecord? {
        try db.read { db in try DriveRecord.fetchOne(db, key: id) }
    }

    /// 同一事务写入云盘与其根目录条目。
    public func insert(_ drive: DriveRecord, rootItem: ItemRecord) throws {
        try db.write { db in
            try drive.insert(db)
            try rootItem.insert(db)
        }
    }

    /// 删除云盘；`item`/`transfer` 经外键级联删除，无外键的 `change_log`/`upload_session` 在同一事务内清理。
    public func delete(id: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM change_log WHERE drive_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM upload_session WHERE drive_id = ?", arguments: [id])
            _ = try DriveRecord.deleteOne(db, key: id)
        }
    }

    public func updateStatus(id: String, _ status: DriveStatus) throws {
        try update(id: id, sql: "status = ?", [status])
    }

    public func updateCapacity(id: String, total: Int64, used: Int64) throws {
        let assignments = "capacity_total = ?, capacity_used = ?, capacity_updated_at = ?"
        try update(id: id, sql: assignments, [total, used, now().timeIntervalSince1970])
    }

    public func updateIgnorePatterns(id: String, _ patterns: [String]) throws {
        let json = String(decoding: try JSONEncoder().encode(patterns), as: UTF8.self)
        try update(id: id, sql: "ignore_patterns = ?", [json])
    }

    public func updateLastReconcile(id: String) throws {
        try update(id: id, sql: "last_reconcile_at = ?", [now().timeIntervalSince1970])
    }

    private func update(id: String, sql assignments: String, _ values: StatementArguments) throws {
        let arguments = values + [id]
        try db.write { db in
            try db.execute(sql: "UPDATE drive SET \(assignments) WHERE id = ?", arguments: arguments)
        }
    }
}
