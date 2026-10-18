import Foundation
import GRDB

/// 变更日志：每次本地镜像变化追加一条，File Provider 按 `seq` 增量枚举变更。
public struct ChangeLog: Sendable {
    public static let defaultKeepLast = 20000

    private let db: any DatabaseWriter
    private let now: @Sendable () -> Date

    public init(db: any DatabaseWriter, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.now = now
    }

    public func append(driveID: String, itemID: String, kind: ChangeKind) throws {
        try appendMany(driveID: driveID, itemIDs: [itemID], kind: kind)
    }

    public func appendMany(driveID: String, itemIDs: [String], kind: ChangeKind) throws {
        guard !itemIDs.isEmpty else { return }
        let date = now()
        try db.write { db in
            try Self.insert(db, driveID: driveID, itemIDs: itemIDs, kind: kind, at: date)
        }
    }

    /// 最新序号；无记录为 0。
    public func latestSeq(driveID: String) throws -> Int64 {
        try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM change_log WHERE drive_id = ?", arguments: [driveID]) ?? 0
        }
    }

    /// 最旧的保留序号；无记录为 nil。
    public func oldestSeq(driveID: String) throws -> Int64? {
        try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT MIN(seq) FROM change_log WHERE drive_id = ?", arguments: [driveID])
        }
    }

    /// `seq > afterSeq` 的变更，按 `seq` 升序。
    public func changes(driveID: String, afterSeq: Int64, limit: Int) throws -> [ChangeLogRecord] {
        try db.read { db in
            try ChangeLogRecord.fetchAll(
                db,
                sql: "SELECT * FROM change_log WHERE drive_id = ? AND seq > ? ORDER BY seq LIMIT ?",
                arguments: [driveID, afterSeq, limit]
            )
        }
    }

    /// 在同一读事务快照内校验 anchor 并取出 `seq > afterSeq` 的变更：anchor 早于已裁剪的日志或晚于最新序号时返回 nil。
    /// 校验与读取分开时，两者之间的裁剪会让被裁掉的变更（尤其删除）静默漏报。
    public func retainedChanges(driveID: String, afterSeq: Int64, limit: Int) throws -> [ChangeLogRecord]? {
        try db.read { db in
            let bounds = try Row.fetchOne(
                db, sql: "SELECT MIN(seq) AS oldest, MAX(seq) AS latest FROM change_log WHERE drive_id = ?", arguments: [driveID]
            )
            let oldest: Int64? = bounds?["oldest"]
            let latest: Int64 = bounds?["latest"] ?? 0
            if let oldest, afterSeq < oldest - 1 { return nil }
            if afterSeq > latest { return nil }
            return try ChangeLogRecord.fetchAll(
                db,
                sql: "SELECT * FROM change_log WHERE drive_id = ? AND seq > ? ORDER BY seq LIMIT ?",
                arguments: [driveID, afterSeq, limit]
            )
        }
    }

    /// 仅保留该云盘最近 `keepLast` 条。
    public func prune(driveID: String, keepLast: Int = Self.defaultKeepLast) throws {
        try db.write { db in
            guard keepLast > 0 else {
                try db.execute(sql: "DELETE FROM change_log WHERE drive_id = ?", arguments: [driveID])
                return
            }
            // 子查询取第 keepLast 新的 seq；记录不足时为 NULL，比较结果为假，不删除任何行。
            try db.execute(
                sql: """
                    DELETE FROM change_log WHERE drive_id = ? AND seq < (
                        SELECT seq FROM change_log WHERE drive_id = ? ORDER BY seq DESC LIMIT 1 OFFSET ?
                    )
                    """,
                arguments: [driveID, driveID, keepLast - 1]
            )
        }
    }

    /// 在调用方事务内追加日志（供其他 store 在同一事务中使用）。
    static func insert(_ db: Database, driveID: String, itemIDs: [String], kind: ChangeKind, at date: Date) throws {
        for itemID in itemIDs {
            try ChangeLogRecord(driveID: driveID, itemID: itemID, kind: kind, createdAt: date).insert(db)
        }
    }
}
