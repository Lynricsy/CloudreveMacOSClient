import Foundation
import GRDB
import Testing
@testable import CloudreveSync

@Suite struct ChangeLogStoreTests {
    @Test func appendAndQuery() throws {
        let db = try DBFixtures.database(drives: ["d1", "d2"])
        let log = ChangeLog(db: db)
        #expect(try log.latestSeq(driveID: "d1") == 0)
        #expect(try log.oldestSeq(driveID: "d1") == nil)
        try log.append(driveID: "d1", itemID: "a", kind: .update)
        try log.append(driveID: "d2", itemID: "x", kind: .update)
        try log.appendMany(driveID: "d1", itemIDs: ["b", "c"], kind: .delete)
        #expect(try log.latestSeq(driveID: "d1") == 4)
        #expect(try log.oldestSeq(driveID: "d1") == 1)
        let changes = try log.changes(driveID: "d1", afterSeq: 1, limit: 10)
        #expect(changes.map(\.itemID) == ["b", "c"])
        #expect(changes.map(\.kind) == [.delete, .delete])
        #expect(try log.changes(driveID: "d1", afterSeq: 0, limit: 1).map(\.seq) == [1])
    }

    @Test func pruneKeepsLatestAndSeqNeverReused() throws {
        let db = try DBFixtures.database(drives: ["d1", "d2"])
        let log = ChangeLog(db: db)
        try db.write { db in
            try db.execute(sql: """
                WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 30000)
                INSERT INTO change_log (seq, drive_id, item_id, kind, created_at)
                SELECT x, 'd1', 'i' || x, 'update', 0 FROM n
                """)
        }
        try log.append(driveID: "d2", itemID: "keep", kind: .update)
        try log.prune(driveID: "d1", keepLast: 20000)
        #expect(try log.oldestSeq(driveID: "d1") == 10001)
        #expect(try log.latestSeq(driveID: "d1") == 30000)
        #expect(try log.changes(driveID: "d1", afterSeq: 10000, limit: 1).first?.seq == 10001)
        #expect(try log.oldestSeq(driveID: "d2") == 30001)

        // 记录不足 keepLast 时不删除
        try log.prune(driveID: "d2", keepLast: 5)
        #expect(try log.oldestSeq(driveID: "d2") == 30001)

        try log.prune(driveID: "d1", keepLast: 0)
        #expect(try log.oldestSeq(driveID: "d1") == nil)
        try log.append(driveID: "d1", itemID: "after", kind: .update)
        #expect(try log.latestSeq(driveID: "d1") == 30002)
    }

    /// anchor 校验与读取在同一快照：裁剪边界之外或超过最新序号返回 nil，边界之内正常读取。
    @Test func retainedChangesChecksAnchorInSameRead() throws {
        let db = try DBFixtures.database(drives: ["d1"])
        let log = ChangeLog(db: db)
        #expect(try log.retainedChanges(driveID: "d1", afterSeq: 0, limit: 10) == [])
        #expect(try log.retainedChanges(driveID: "d1", afterSeq: 1, limit: 10) == nil)
        try log.appendMany(driveID: "d1", itemIDs: (1...10).map { "i\($0)" }, kind: .update)
        try log.prune(driveID: "d1", keepLast: 5)
        #expect(try log.retainedChanges(driveID: "d1", afterSeq: 4, limit: 10) == nil)
        #expect(try log.retainedChanges(driveID: "d1", afterSeq: 5, limit: 2)?.map(\.itemID) == ["i6", "i7"])
        #expect(try log.retainedChanges(driveID: "d1", afterSeq: 10, limit: 10) == [])
        #expect(try log.retainedChanges(driveID: "d1", afterSeq: 11, limit: 10) == nil)
    }
}
