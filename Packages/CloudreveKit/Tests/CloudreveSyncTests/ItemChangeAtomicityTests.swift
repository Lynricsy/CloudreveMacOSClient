import Foundation
import GRDB
import Testing
@testable import CloudreveSync

/// 镜像与变更日志同事务：日志写入失败时镜像回滚，重放仍能产生通知。
@Suite struct ItemChangeAtomicityTests {
    private func failChangeLogInserts(_ db: any DatabaseWriter) throws {
        try db.write { try $0.execute(sql: "CREATE TRIGGER fail_log BEFORE INSERT ON change_log BEGIN SELECT RAISE(ABORT, 'boom'); END") }
    }

    private func restoreChangeLogInserts(_ db: any DatabaseWriter) throws {
        try db.write { try $0.execute(sql: "DROP TRIGGER fail_log") }
    }

    @Test func upsertInterruptedBeforeLogIsReplayable() throws {
        let db = try DBFixtures.database()
        let store = ItemStore(db: db)
        let log = ChangeLog(db: db)
        try failChangeLogInserts(db)
        #expect(throws: (any Error).self) { try store.upsert([DBFixtures.item("f1", path: "/a.txt")]) }
        #expect(try store.get(driveID: DBFixtures.driveID, id: "f1") == nil)

        try restoreChangeLogInserts(db)
        #expect(try store.upsert([DBFixtures.item("f1", path: "/a.txt")]) == ["f1"])
        #expect(try log.changes(driveID: DBFixtures.driveID, afterSeq: 0, limit: 10).map(\.itemID) == ["f1"])
    }

    @Test func deleteInterruptedBeforeLogIsReplayable() throws {
        let db = try DBFixtures.database()
        let store = ItemStore(db: db)
        let log = ChangeLog(db: db)
        try store.upsert([DBFixtures.item("f1", path: "/a.txt")])
        let before = try log.latestSeq(driveID: DBFixtures.driveID)
        try failChangeLogInserts(db)
        #expect(throws: (any Error).self) { try store.delete(driveID: DBFixtures.driveID, ids: ["f1"]) }
        #expect(try store.get(driveID: DBFixtures.driveID, id: "f1") != nil)

        try restoreChangeLogInserts(db)
        try store.delete(driveID: DBFixtures.driveID, ids: ["f1"])
        let logged = try log.changes(driveID: DBFixtures.driveID, afterSeq: before, limit: 10)
        #expect(logged.map(\.itemID) == ["f1"])
        #expect(logged.map(\.kind) == [.delete])
    }
}
