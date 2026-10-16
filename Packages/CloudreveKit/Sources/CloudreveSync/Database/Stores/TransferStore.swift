import Foundation
import GRDB

/// 传输活动（`transfer` 表）的读写。
public struct TransferStore: Sendable {
    public static let defaultRetention: TimeInterval = 7 * 24 * 3600

    private let db: any DatabaseWriter
    private let now: @Sendable () -> Date

    public init(db: any DatabaseWriter, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.now = now
    }

    /// 记录一次开始的传输，返回新行 id（UUID 字符串）。
    public func start(driveID: String, kind: TransferKind, itemID: String?, name: String, uri: String, total: Int64) throws -> String {
        let record = TransferRecord(
            id: UUID().uuidString, driveID: driveID, kind: kind, itemID: itemID, name: name, uri: uri, totalBytes: total, startedAt: now()
        )
        try db.write { db in try record.insert(db) }
        return record.id
    }

    public func progress(id: String, done: Int64) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE transfer SET done_bytes = ? WHERE id = ?", arguments: [done, id])
        }
    }

    /// 结束传输：`error` 为 nil → `done`（已传字节补齐为总量），否则 `failed`。
    public func finish(id: String, error: String?) throws {
        let state: TransferState = error == nil ? .done : .failed
        let finishedAt = now().timeIntervalSince1970
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE transfer SET state = ?, error = ?, finished_at = ?,
                        done_bytes = CASE WHEN ? THEN total_bytes ELSE done_bytes END
                    WHERE id = ?
                    """,
                arguments: [state, error, finishedAt, error == nil, id]
            )
        }
    }

    /// 最近活动：进行中的按开始时间倒序在前，其余按结束时间倒序。`driveID` 为 nil 表示全部云盘。
    public func recent(driveID: String?, limit: Int = 50) throws -> [TransferRecord] {
        try db.read { db in
            try TransferRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM transfer WHERE (?1 IS NULL OR drive_id = ?1)
                    ORDER BY state = 'running' DESC,
                        CASE WHEN state = 'running' THEN started_at ELSE finished_at END DESC
                    LIMIT ?2
                    """,
                arguments: [driveID, limit]
            )
        }
    }

    /// 进行中的传输数；`driveID` 为 nil 表示全部云盘。
    public func runningCount(driveID: String?) throws -> Int {
        try db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transfer WHERE state = 'running' AND (?1 IS NULL OR drive_id = ?1)",
                arguments: [driveID]
            ) ?? 0
        }
    }

    /// 清理：已结束的行超过 `olderThan` 或不在最近 `keepLast` 条内即删除；
    /// 开始时间早于 `olderThan` 仍为 running 的行视为进程中断遗留，一并删除。
    public func prune(olderThan age: TimeInterval = Self.defaultRetention, keepLast: Int = 200) throws {
        let cutoff = now().timeIntervalSince1970 - age
        try db.write { db in
            try db.execute(
                sql: """
                    DELETE FROM transfer WHERE
                        (state = 'running' AND started_at < ?1)
                        OR (state != 'running' AND (finished_at < ?1 OR id NOT IN (
                            SELECT id FROM transfer WHERE state != 'running' ORDER BY finished_at DESC LIMIT ?2
                        )))
                    """,
                arguments: [cutoff, max(0, keepLast)]
            )
        }
    }

    /// 尚未通知的失败传输，按结束时间升序。
    public func unnotifiedFailures() throws -> [TransferRecord] {
        try db.read { db in
            try TransferRecord.fetchAll(
                db, sql: "SELECT * FROM transfer WHERE state = 'failed' AND NOT notified ORDER BY finished_at"
            )
        }
    }

    public func markNotified(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.write { db in
            _ = try TransferRecord.filter(keys: ids).updateAll(db, Column("notified").set(to: true))
        }
    }
}
