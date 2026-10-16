import CloudreveAPI
import Foundation
import GRDB

/// 本地镜像条目（`item` 表）的读写。
public struct ItemStore: Sendable {
    private let db: any DatabaseWriter
    private let now: @Sendable () -> Date

    public init(db: any DatabaseWriter, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.now = now
    }

    public func get(driveID: String, id: String) throws -> ItemRecord? {
        try db.read { db in try Self.fetch(db, driveID: driveID, id: id) }
    }

    public func getByURI(driveID: String, uri: CloudreveURI) throws -> ItemRecord? {
        try db.read { db in
            try ItemRecord.fetchOne(db, sql: "SELECT * FROM item WHERE drive_id = ? AND uri = ?", arguments: [driveID, uri.description])
        }
    }

    public func children(driveID: String, parentID: String) throws -> [ItemRecord] {
        try db.read { db in
            try ItemRecord.fetchAll(
                db, sql: "SELECT * FROM item WHERE drive_id = ? AND parent_id = ? ORDER BY name", arguments: [driveID, parentID]
            )
        }
    }

    /// `uriPrefix` 之下的所有后代（不含其自身），按 uri 排序。
    public func descendants(driveID: String, uriPrefix: CloudreveURI) throws -> [ItemRecord] {
        try db.read { db in try Self.fetchDescendants(db, driveID: driveID, uriPrefix: uriPrefix.description) }
    }

    /// 插入或更新条目，返回新增或追踪字段（name/parent_id/size/entity_id/updated_at/is_folder）有变化的 id。
    /// 已有 `enumerated_at` 保留不覆盖。同一 uri 被另一个 id 占用时（远端删除后同名重建），
    /// 旧行及其后代被删除并在同一事务内记 `delete` 变更，保证 `(drive_id, uri)` 唯一。
    @discardableResult
    public func upsert(_ records: [ItemRecord]) throws -> [String] {
        let date = now()
        return try db.write { db in
            var changed: [String] = []
            for record in records {
                try Self.removeStale(db, occupying: record, at: date)
                guard let existing = try Self.fetch(db, driveID: record.driveID, id: record.id) else {
                    try record.insert(db)
                    changed.append(record.id)
                    continue
                }
                var merged = record
                merged.enumeratedAt = record.enumeratedAt ?? existing.enumeratedAt
                if merged.differsInTrackedFields(from: existing) {
                    changed.append(record.id)
                }
                if merged.differsInStoredColumns(from: existing) {
                    try merged.update(db)
                }
            }
            return changed
        }
    }

    /// 仅删除给定 id 的行（后代由调用方通过 `descendants` 一并传入）。
    public func delete(driveID: String, ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.write { db in
            for id in ids {
                try ItemRecord.deleteOne(db, key: ["drive_id": driveID, "id": id])
            }
        }
    }

    /// 把 `oldPrefix` 之下所有后代的 uri 前缀改为 `newPrefix`（目录自身由调用方 upsert）。
    public func reprefixURIs(driveID: String, oldPrefix: CloudreveURI, newPrefix: CloudreveURI) throws {
        let old = oldPrefix.description
        let bounds = Self.descendantBounds(old)
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE item SET uri = ? || substr(uri, length(?) + 1)
                    WHERE drive_id = ? AND uri > ? AND uri < ?
                    """,
                arguments: [newPrefix.description, old, driveID, bounds.lower, bounds.upper]
            )
        }
    }

    public func markEnumerated(driveID: String, id: String, at date: Date) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE item SET enumerated_at = ? WHERE drive_id = ? AND id = ?",
                arguments: [date.timeIntervalSince1970, driveID, id]
            )
        }
    }

    /// 曾完整列过的目录（含根），按 uri 排序（父目录先于子目录）。
    public func enumeratedFolders(driveID: String) throws -> [ItemRecord] {
        try db.read { db in
            try ItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM item WHERE drive_id = ? AND is_folder AND enumerated_at IS NOT NULL ORDER BY uri",
                arguments: [driveID]
            )
        }
    }

    /// 按 rowid 分页遍历非根条目（working set）。返回本页与「下一页起点 rowid」；没有更多时为 nil。
    public func page(driveID: String, afterRowID: Int64, limit: Int) throws -> ([ItemRecord], Int64?) {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT rowid AS item_rowid, * FROM item
                    WHERE drive_id = ? AND parent_id IS NOT NULL AND rowid > ?
                    ORDER BY rowid LIMIT ?
                    """,
                arguments: [driveID, afterRowID, limit + 1]
            )
            let pageRows = rows.prefix(limit)
            let records = try pageRows.map { try ItemRecord(row: $0) }
            let next: Int64? = rows.count > limit ? pageRows.last?["item_rowid"] : nil
            return (records, next)
        }
    }
}

extension ItemStore {
    static func fetch(_ db: Database, driveID: String, id: String) throws -> ItemRecord? {
        try ItemRecord.fetchOne(db, key: ["drive_id": driveID, "id": id])
    }

    static func fetchDescendants(_ db: Database, driveID: String, uriPrefix: String) throws -> [ItemRecord] {
        let bounds = descendantBounds(uriPrefix)
        return try ItemRecord.fetchAll(
            db,
            sql: "SELECT * FROM item WHERE drive_id = ? AND uri > ? AND uri < ? ORDER BY uri",
            arguments: [driveID, bounds.lower, bounds.upper]
        )
    }

    /// 后代 uri 的二进制区间 `(prefix + "/", prefix + "0")`：`'0'` 紧随 `'/'`，区间恰好覆盖以 `prefix/` 开头的所有字符串。
    /// 不用 LIKE：SQLite 的 LIKE 对 ASCII 不区分大小写，且需转义 `%`/`_`；区间比较区分大小写并可走 `(drive_id, uri)` 索引。
    static func descendantBounds(_ prefix: String) -> (lower: String, upper: String) {
        (prefix + "/", prefix + "0")
    }

    /// 删除占用 `record.uri` 的其他 id 的行（及其后代），并记 `delete` 变更。
    private static func removeStale(_ db: Database, occupying record: ItemRecord, at date: Date) throws {
        let uri = record.uri.description
        let stale = try ItemRecord.fetchAll(
            db, sql: "SELECT * FROM item WHERE drive_id = ? AND uri = ? AND id != ?", arguments: [record.driveID, uri, record.id]
        )
        guard let staleItem = stale.first else { return }
        var ids = [staleItem.id]
        if staleItem.isFolder {
            ids += try fetchDescendants(db, driveID: record.driveID, uriPrefix: uri).map(\.id)
        }
        for id in ids {
            try ItemRecord.deleteOne(db, key: ["drive_id": record.driveID, "id": id])
        }
        try ChangeLog.insert(db, driveID: record.driveID, itemIDs: ids, kind: .delete, at: date)
    }
}
