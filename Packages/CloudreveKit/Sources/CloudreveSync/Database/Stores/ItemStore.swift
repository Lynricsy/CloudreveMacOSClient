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

    /// 插入或更新条目，返回新增或追踪字段（name/parent_id/size/entity_id/updated_at/is_folder）有变化的 id，
    /// 并在同一事务内为它们记 `update` 变更：镜像与日志分开提交时，进程在两者之间被回收会永久丢失通知
    /// （重放时字段已无变化，不会再产生 update）。已有 `enumerated_at` 保留不覆盖。
    ///
    /// 同一事务内还保证镜像路径一致：
    /// - 已知目录的 uri 变化（远端重命名/移动，无论从列目录、事件还是本地操作得知）时，后代 uri 随之迁移；
    /// - 新位置被其他 id 占用（远端删除后同名重建、陈旧镜像行）时，占位行及其后代（迁移目录时为新位置下的全部陈旧行）
    ///   先被删除并记 `delete` 变更，保证 `(drive_id, uri)` 唯一。
    ///
    /// uri 一律按存储的编码文本比较：`CloudreveURI ==` 按规范等价比较，会漏掉仅 Unicode 规范化不同的目录改名。
    ///
    /// `parking` 非 nil（全量扫描期间）时占位者不立即删除，而是连同子树暂存到 `parking/<id>` 之下：它可能只是移走了，
    /// 稍后在扫描到的新位置按 id 迁回（保留 `enumerated_at` 与子树）；整轮结束仍留在暂存区的由调用方 `purgeParked` 删除。
    @discardableResult
    public func upsert(_ records: [ItemRecord], parkingOccupantsUnder parking: CloudreveURI? = nil) throws -> [String] {
        let date = now()
        return try db.write { db in
            var changed: [String] = []
            for record in records {
                let existing = try Self.fetch(db, driveID: record.driveID, id: record.id)
                let newURI = record.uri.description
                let movedFolder = existing.flatMap { $0.isFolder && $0.uri.description != newURI ? $0.uri.description : nil }
                try Self.removeOccupants(db, of: record, existing: existing, movingFrom: movedFolder, parking: parking, at: date)
                if let movedFolder {
                    try Self.relocateSubtree(db, driveID: record.driveID, id: record.id, from: movedFolder, to: newURI)
                }
                guard let existing else {
                    try record.insert(db)
                    try ChangeLog.insert(db, driveID: record.driveID, itemIDs: [record.id], kind: .update, at: date)
                    changed.append(record.id)
                    continue
                }
                var merged = record
                merged.enumeratedAt = record.enumeratedAt ?? existing.enumeratedAt
                if merged.differsInTrackedFields(from: existing) {
                    try ChangeLog.insert(db, driveID: record.driveID, itemIDs: [record.id], kind: .update, at: date)
                    changed.append(record.id)
                }
                if merged.differsInStoredColumns(from: existing) {
                    try merged.update(db)
                }
            }
            return changed
        }
    }

    /// 仅删除给定 id 的行（后代由调用方通过 `descendants` 一并传入），同一事务内记 `delete` 变更。
    public func delete(driveID: String, ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let date = now()
        try db.write { db in
            for id in ids {
                try ItemRecord.deleteOne(db, key: ["drive_id": driveID, "id": id])
            }
            try ChangeLog.insert(db, driveID: driveID, itemIDs: ids, kind: .delete, at: date)
        }
    }

    /// 删除 `parentID` 下本轮列目录未出现（不在 `seen` 中）、且 `seq` 之后没有任何变更日志的子项（目录连同后代），
    /// 同一事务记 `delete`。`seq` 之后有变更的子项是本轮开始后由其他途径（事件、并发枚举、本地操作）写入或移入的，
    /// 本轮的分页结果不能证明它们已在远端消失。
    public func removeUnseenChildren(driveID: String, parentID: String, seen: Set<String>, unchangedAfter seq: Int64) throws {
        let date = now()
        try db.write { db in
            let candidates = try ItemRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM item WHERE drive_id = ? AND parent_id = ? AND id NOT IN (
                        SELECT item_id FROM change_log WHERE drive_id = ? AND seq > ?
                    ) ORDER BY uri
                    """,
                arguments: [driveID, parentID, driveID, seq]
            )
            var ids: [String] = []
            for stale in candidates where !seen.contains(stale.id) {
                ids.append(stale.id)
                if stale.isFolder {
                    ids += try Self.fetchDescendants(db, driveID: driveID, uriPrefix: stale.uri.description).map(\.id)
                }
            }
            guard !ids.isEmpty else { return }
            for id in ids {
                try ItemRecord.deleteOne(db, key: ["drive_id": driveID, "id": id])
            }
            try ChangeLog.insert(db, driveID: driveID, itemIDs: ids, kind: .delete, at: date)
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
    /// 删除全量扫描结束后仍留在暂存区 `parking` 之下的行（被占位且本轮未在别处出现的条目及其后代），记 `delete` 变更。
    public func purgeParked(driveID: String, parking: CloudreveURI) throws {
        let date = now()
        try db.write { db in
            let ids = try Self.fetchDescendants(db, driveID: driveID, uriPrefix: parking.description).map(\.id)
            guard !ids.isEmpty else { return }
            for id in ids {
                try ItemRecord.deleteOne(db, key: ["drive_id": driveID, "id": id])
            }
            try ChangeLog.insert(db, driveID: driveID, itemIDs: ids, kind: .delete, at: date)
        }
    }

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

    /// 编码后的 `uri` 是否为 `prefix` 本身或其后代（逐字节比较）。
    static func isWithin(_ uri: String, _ prefix: String) -> Bool {
        uri.utf8.elementsEqual(prefix.utf8) || uri.utf8.starts(with: (prefix + "/").utf8)
    }

    /// 清理占用 `record.uri` 的其他 id 的行及其后代：删除并记 `delete` 变更，或在 `parking` 非 nil 时暂存（见 `upsert`）。
    /// `oldPrefix` 非 nil 表示 `record` 是从该位置迁来的已知目录：新位置之下的所有其他行都是陈旧占位（迁移后会与后代撞
    /// 唯一索引），一并删除；但仍在旧位置之下的行（迁移中的后代）保留。
    private static func removeOccupants(
        _ db: Database, of record: ItemRecord, existing: ItemRecord?, movingFrom oldPrefix: String?, parking: CloudreveURI?,
        at date: Date
    ) throws {
        let uri = record.uri.description
        var occupant = try ItemRecord.fetchOne(
            db, sql: "SELECT * FROM item WHERE drive_id = ? AND uri = ? AND id != ?", arguments: [record.driveID, uri, record.id]
        )
        // 暂存会把占位者整棵子树带走；`record` 自身就在其中（如 /p/a 迁到 /p）时只能按原逻辑删除其余行
        if let current = occupant, let parking, !(existing.map { isWithin($0.uri.description, uri) } ?? false) {
            let parked = parking.appending(current.id).description
            try relocateSubtree(db, driveID: record.driveID, id: current.id, from: uri, to: parked)
            occupant = nil
        }
        var stale = occupant.map { [$0] } ?? []
        if oldPrefix != nil || occupant?.isFolder == true {
            stale += try fetchDescendants(db, driveID: record.driveID, uriPrefix: uri)
        }
        stale.removeAll { row in
            row.id == record.id || oldPrefix.map { isWithin(row.uri.description, $0) } == true
        }
        guard !stale.isEmpty else { return }
        let ids = stale.map(\.id)
        for id in ids {
            try ItemRecord.deleteOne(db, key: ["drive_id": record.driveID, "id": id])
        }
        try ChangeLog.insert(db, driveID: record.driveID, itemIDs: ids, kind: .delete, at: date)
    }

    /// 把条目自身及其全部后代的 uri 前缀从 `oldPrefix` 改为 `newPrefix`（编码文本；目标位置的占位已由调用方清理）。
    private static func relocateSubtree(_ db: Database, driveID: String, id: String, from oldPrefix: String, to newPrefix: String) throws {
        // 自身先占住新位置，旧位置随即空出（如 /p/a → /p 时后代 /p/a/a 要迁入 /p/a）
        try db.execute(sql: "UPDATE item SET uri = ? WHERE drive_id = ? AND id = ?", arguments: [newPrefix, driveID, id])
        let sql = "UPDATE item SET uri = ? || substr(uri, length(?) + 1) WHERE drive_id = ? AND uri > ? AND uri < ?"
        func move(from old: String, to new: String) throws {
            let bounds = descendantBounds(old)
            try db.execute(sql: sql, arguments: [new, old, driveID, bounds.lower, bounds.upper])
        }
        // 新位置是旧位置的祖先时，逐行改写可能与尚未改写的另一后代暂时同名而撞唯一索引：经临时前缀中转
        guard isWithin(oldPrefix, newPrefix) else {
            try move(from: oldPrefix, to: newPrefix)
            return
        }
        let temporary = "\u{1}" + UUID().uuidString
        try move(from: oldPrefix, to: temporary)
        try move(from: temporary, to: newPrefix)
    }
}
