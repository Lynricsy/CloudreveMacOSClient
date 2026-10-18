import Foundation
import GRDB
import Testing
@testable import CloudreveSync

@Suite struct TransferStoreTests {
    private let driveID = DBFixtures.driveID

    private func start(_ store: TransferStore, _ name: String, drive: String = DBFixtures.driveID) throws -> String {
        try store.start(driveID: drive, kind: .download, itemID: nil, name: name, uri: "cloudreve://my/\(name)", total: 100)
    }

    @Test func lifecycleAndRecentOrdering() throws {
        let clock = DatabaseTestClock()
        let db = try DBFixtures.database(drives: [DBFixtures.driveID, "other"])
        let store = TransferStore(db: db, now: clock.provider)

        let doneEarly = try start(store, "done-early")
        clock.advance(1)
        let runningOld = try start(store, "running-old")
        clock.advance(1)
        let failed = try start(store, "failed")
        clock.advance(1)
        try store.finish(id: doneEarly, error: nil)
        clock.advance(1)
        let runningNew = try start(store, "running-new")
        clock.advance(1)
        try store.finish(id: failed, error: "版本冲突，已另存为 x", isConflict: true)
        _ = try start(store, "elsewhere", drive: "other")
        try store.progress(id: runningOld, done: 42)

        let recent = try store.recent(driveID: driveID)
        #expect(recent.map(\.name) == ["running-new", "running-old", "failed", "done-early"])
        #expect(recent[1].doneBytes == 42)
        #expect(recent[2].state == .failed && recent[2].error == "版本冲突，已另存为 x" && recent[2].isConflict)
        #expect(recent[3].state == .done && recent[3].doneBytes == 100 && !recent[3].isConflict)
        #expect(recent[3].finishedAt == DBFixtures.epoch.addingTimeInterval(3))
        #expect(try store.recent(driveID: nil).count == 5)
        #expect(try store.recent(driveID: driveID, limit: 1).map(\.id) == [runningNew])
        #expect(try store.runningCount(driveID: driveID) == 2)
        #expect(try store.runningCount(driveID: nil) == 3)
    }

    @Test func notificationTracking() throws {
        let store = TransferStore(db: try DBFixtures.database())
        let first = try start(store, "a")
        let second = try start(store, "b")
        let ok = try start(store, "c")
        try store.finish(id: first, error: "boom")
        try store.finish(id: second, error: "boom2")
        try store.finish(id: ok, error: nil)
        #expect(try store.unnotifiedFailures().map(\.id) == [first, second])
        try store.markNotified(ids: [first])
        #expect(try store.unnotifiedFailures().map(\.id) == [second])
    }

    @Test func pruneKeepsLatest200AndDropsOld() throws {
        let clock = DatabaseTestClock()
        let db = try DBFixtures.database()
        let store = TransferStore(db: db, now: clock.provider)
        let stuck = try start(store, "stuck")
        var finished: [String] = []
        for index in 0..<250 {
            clock.advance(60)
            let id = try start(store, "f\(index)")
            try store.finish(id: id, error: nil)
            finished.append(id)
        }
        let active = try start(store, "active")

        try store.prune()
        let remaining = try store.recent(driveID: nil, limit: 1000)
        #expect(remaining.count == 202)
        #expect(Set(remaining.map(\.id)) == Set(finished.suffix(200) + [stuck, active]))

        // 8 天后：已结束的全部过期；早于期限仍为 running 的行视为遗留一并删除
        clock.advance(8 * 24 * 3600)
        let fresh = try start(store, "fresh")
        try store.prune()
        #expect(try store.recent(driveID: nil, limit: 1000).map(\.id) == [fresh])
    }
}
