import CloudreveAPI
import Foundation
import GRDB
import Testing
@testable import CloudreveSync

@Suite struct ItemStoreTests {
    private let driveID = DBFixtures.driveID

    @Test func upsertDetectsChanges() throws {
        let db = try DBFixtures.database()
        let store = ItemStore(db: db)
        let file = DBFixtures.item("f1", path: "/a.txt")
        #expect(try store.upsert([file]) == ["f1"])
        #expect(try store.upsert([file]).isEmpty)

        var changed = file
        changed.entityID = "e2"
        #expect(try store.upsert([changed]) == ["f1"])
        #expect(try store.get(driveID: driveID, id: "f1")?.entityID == "e2")

        // 毫秒内的时间抖动不算变化
        var jitter = changed
        jitter.updatedAt = changed.updatedAt.addingTimeInterval(0.0001)
        #expect(try store.upsert([jitter]).isEmpty)

        var later = changed
        later.updatedAt = changed.updatedAt.addingTimeInterval(1)
        #expect(try store.upsert([later]) == ["f1"])
    }

    @Test func upsertKeepsEnumeratedAtAndWritesUntrackedURI() throws {
        let db = try DBFixtures.database()
        let store = ItemStore(db: db)
        let folder = DBFixtures.item("d1", path: "/docs", folder: true)
        try store.upsert([folder])
        try store.markEnumerated(driveID: driveID, id: "d1", at: DBFixtures.epoch)
        try store.upsert([folder])
        #expect(try store.get(driveID: driveID, id: "d1")?.enumeratedAt == DBFixtures.epoch)
        #expect(try store.enumeratedFolders(driveID: driveID).map(\.id) == ["d1"])
    }

    @Test func upsertReplacesStaleRowAtSameURI() throws {
        let clock = DatabaseTestClock()
        let db = try DBFixtures.database()
        let store = ItemStore(db: db, now: clock.provider)
        try store.upsert([
            DBFixtures.item("old", path: "/dir", folder: true),
            DBFixtures.item("child", path: "/dir/x.txt", parent: "old")
        ])
        let before = try ChangeLog(db: db).latestSeq(driveID: driveID)
        #expect(try store.upsert([DBFixtures.item("new", path: "/dir", folder: true)]) == ["new"])
        #expect(try store.get(driveID: driveID, id: "old") == nil)
        #expect(try store.get(driveID: driveID, id: "child") == nil)
        let log = try ChangeLog(db: db).changes(driveID: driveID, afterSeq: before, limit: 10)
        #expect(log.map(\.itemID) == ["old", "child", "new"])
        #expect(log.map(\.kind) == [.delete, .delete, .update])
        #expect(log.allSatisfy { $0.createdAt == clock.now })
    }

    @Test func descendantsUseExactPrefix() throws {
        let db = try DBFixtures.database()
        let store = ItemStore(db: db)
        try store.upsert([
            DBFixtures.item("a", path: "/a", folder: true),
            DBFixtures.item("a1", path: "/a/x.txt", parent: "a"),
            DBFixtures.item("a2", path: "/a/sub", parent: "a", folder: true),
            DBFixtures.item("a3", path: "/a/sub/y.txt", parent: "a2"),
            DBFixtures.item("ab", path: "/ab", folder: true),
            DBFixtures.item("ab1", path: "/ab/z.txt", parent: "ab"),
            DBFixtures.item("upper", path: "/A", folder: true),
            DBFixtures.item("upper1", path: "/A/q.txt", parent: "upper"),
            DBFixtures.item("pct", path: "/50%_off", folder: true),
            DBFixtures.item("pct1", path: "/50%_off/in.txt", parent: "pct"),
            DBFixtures.item("pctx", path: "/50%Xoff", folder: true),
            DBFixtures.item("pctx1", path: "/50%Xoff/out.txt", parent: "pctx"),
            DBFixtures.item("u", path: "/a_b", folder: true),
            DBFixtures.item("u1", path: "/a_b/k.txt", parent: "u"),
            DBFixtures.item("ux", path: "/aXb", folder: true),
            DBFixtures.item("ux1", path: "/aXb/m.txt", parent: "ux")
        ])
        #expect(try Set(store.descendants(driveID: driveID, uriPrefix: .my("/a")).map(\.id)) == ["a1", "a2", "a3"])
        #expect(try store.descendants(driveID: driveID, uriPrefix: .my("/50%_off")).map(\.id) == ["pct1"])
        #expect(try store.descendants(driveID: driveID, uriPrefix: .my("/a_b")).map(\.id) == ["u1"])
        #expect(try store.descendants(driveID: driveID, uriPrefix: .my("/A")).map(\.id) == ["upper1"])
        #expect(try store.descendants(driveID: driveID, uriPrefix: .my("/")).count == 16)
    }

    @Test func upsertOfMovedFolderRewritesDescendantsOnly() throws {
        let db = try DBFixtures.database()
        let store = ItemStore(db: db)
        try store.upsert([
            DBFixtures.item("a", path: "/a", folder: true),
            DBFixtures.item("a1", path: "/a/x.txt", parent: "a"),
            DBFixtures.item("a2", path: "/a/中 文", parent: "a", folder: true),
            DBFixtures.item("a3", path: "/a/中 文/y.txt", parent: "a2"),
            DBFixtures.item("ab1", path: "/ab.txt")
        ])
        let before = try ChangeLog(db: db).latestSeq(driveID: driveID)
        #expect(try store.upsert([DBFixtures.item("a", path: "/b/新", folder: true)]) == ["a"])
        #expect(try store.get(driveID: driveID, id: "a")?.uri == .my("/b/新"))
        #expect(try store.get(driveID: driveID, id: "a1")?.uri == .my("/b/新/x.txt"))
        #expect(try store.get(driveID: driveID, id: "a3")?.uri == .my("/b/新/中 文/y.txt"))
        #expect(try store.get(driveID: driveID, id: "ab1")?.uri == .my("/ab.txt"))
        #expect(try store.getByURI(driveID: driveID, uri: .my("/b/新/中 文"))?.id == "a2")
        // 只有目录自身的 update，后代不产生日志
        #expect(try ChangeLog(db: db).changes(driveID: driveID, afterSeq: before, limit: 10).map(\.itemID) == ["a"])
    }

    /// 目录迁到自己原来的祖先位置（/p/a → /p）：新位置下的陈旧行被清理，同名嵌套后代经临时前缀迁移不撞唯一索引。
    @Test func upsertOfFolderMovedOntoAncestorPath() throws {
        let db = try DBFixtures.database()
        let store = ItemStore(db: db)
        try store.upsert([
            DBFixtures.item("p", path: "/p", folder: true),
            DBFixtures.item("sib", path: "/p/sib.txt", parent: "p"),
            DBFixtures.item("a", path: "/p/a", parent: "p", folder: true),
            DBFixtures.item("aa", path: "/p/a/a", parent: "a", folder: true),
            DBFixtures.item("y", path: "/p/a/a/y", parent: "aa"),
            DBFixtures.item("y2", path: "/p/a/y", parent: "a")
        ])
        try store.upsert([DBFixtures.item("a", path: "/p", folder: true)])
        #expect(try store.get(driveID: driveID, id: "p") == nil)
        #expect(try store.get(driveID: driveID, id: "sib") == nil)
        #expect(try store.get(driveID: driveID, id: "aa")?.uri == .my("/p/a"))
        #expect(try store.get(driveID: driveID, id: "y")?.uri == .my("/p/a/y"))
        #expect(try store.get(driveID: driveID, id: "y2")?.uri == .my("/p/y"))
    }

    @Test func pageExcludesRootAndPagesByRowID() throws {
        let db = try DBFixtures.database(drives: [DBFixtures.driveID, "other"])
        let store = ItemStore(db: db)
        try store.upsert((1...5).map { DBFixtures.item("f\($0)", path: "/f\($0).txt") })
        try store.upsert([DBFixtures.item("o1", path: "/o.txt", driveID: "other")])

        let (first, next) = try store.page(driveID: driveID, afterRowID: 0, limit: 2)
        #expect(first.map(\.id) == ["f1", "f2"])
        let cursor = try #require(next)
        let (second, next2) = try store.page(driveID: driveID, afterRowID: cursor, limit: 2)
        #expect(second.map(\.id) == ["f3", "f4"])
        let (third, next3) = try store.page(driveID: driveID, afterRowID: try #require(next2), limit: 2)
        #expect(third.map(\.id) == ["f5"])
        #expect(next3 == nil)

        let (all, end) = try store.page(driveID: driveID, afterRowID: 0, limit: 5)
        #expect(all.count == 5 && !all.contains { $0.id == DBFixtures.rootID })
        #expect(end == nil)
    }

    @Test func childrenAndDelete() throws {
        let db = try DBFixtures.database()
        let store = ItemStore(db: db)
        try store.upsert([DBFixtures.item("b", path: "/b.txt"), DBFixtures.item("a", path: "/a.txt")])
        #expect(try store.children(driveID: driveID, parentID: DBFixtures.rootID).map(\.id) == ["a", "b"])
        try store.delete(driveID: driveID, ids: ["a"])
        #expect(try store.children(driveID: driveID, parentID: DBFixtures.rootID).map(\.id) == ["b"])
    }
}
