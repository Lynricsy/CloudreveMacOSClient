import CloudreveAPI
import Foundation
import GRDB

/// 一次取出的待应用远端变更。
public struct RemoteEventBatch: Sendable, Equatable {
    /// 本批最大序号；应用成功后据此删除。
    public var lastSeq: Int64
    public var events: [FileEvent]
    /// 本批含全量兜底请求：其覆盖同批全部事件。
    public var needsReconcile: Bool
}

/// `remote_event` 表：跨进程的远端变更队列。
///
/// 服务端在投递前就删除离线事件，扩展又随时可能被系统回收，因此推送不能直接在扩展里消费：
/// App 收到即落库，扩展在系统请求内应用成功后再删除（至少一次）。
public struct RemoteEventQueue: Sendable {
    private let db: any DatabaseWriter
    private let now: @Sendable () -> Date

    public init(db: any DatabaseWriter, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.now = now
    }

    public func append(driveID: String, events: [FileEvent]) throws {
        guard !events.isEmpty else { return }
        let encoder = JSONEncoder()
        let rows = try events.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        let date = now().timeIntervalSince1970
        try db.write { db in
            for json in rows {
                try db.execute(
                    sql: "INSERT INTO remote_event (drive_id, kind, event_json, created_at) VALUES (?, 'event', ?, ?)",
                    arguments: [driveID, json, date]
                )
            }
        }
    }

    public func requestReconcile(driveID: String) throws {
        let date = now().timeIntervalSince1970
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO remote_event (drive_id, kind, created_at) VALUES (?, 'reconcile', ?)",
                arguments: [driveID, date]
            )
        }
    }

    /// 按序取出最多 `limit` 条；队列为空返回 nil。无法解析的事件行跳过（随批次一并删除）。
    public func next(driveID: String, limit: Int) throws -> RemoteEventBatch? {
        let rows = try db.read { db in
            try Row.fetchAll(
                db, sql: "SELECT seq, kind, event_json FROM remote_event WHERE drive_id = ? ORDER BY seq LIMIT ?",
                arguments: [driveID, limit]
            )
        }
        guard let last = rows.last else { return nil }
        let decoder = JSONDecoder()
        var events: [FileEvent] = []
        var needsReconcile = false
        for row in rows {
            let kind: String = row["kind"]
            if kind == "reconcile" {
                needsReconcile = true
            } else if let json: String = row["event_json"], let event = try? decoder.decode(FileEvent.self, from: Data(json.utf8)) {
                events.append(event)
            }
        }
        return RemoteEventBatch(lastSeq: last["seq"], events: events, needsReconcile: needsReconcile)
    }

    /// 删除序号不大于 `seq` 的条目（已应用）。
    public func remove(driveID: String, throughSeq seq: Int64) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM remote_event WHERE drive_id = ? AND seq <= ?", arguments: [driveID, seq])
        }
    }
}
