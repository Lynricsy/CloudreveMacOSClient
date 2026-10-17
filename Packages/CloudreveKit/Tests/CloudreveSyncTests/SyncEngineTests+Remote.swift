import CloudreveAPI
import Foundation
import Testing
@testable import CloudreveSync

// 远端事件应用与全量兜底。
extension SyncEngineTests {
    @Test func remoteCreateWithKnownParentIsStored() async throws {
        let env = try await EngineHarness.make()
        let id = env.server.addFile("/new.txt")
        let changed = try await env.engine.applyRemoteEvents([FileEvent(type: .create, fileID: id, from: "/new.txt")])
        #expect(changed)
        let record = try #require(try env.record(id))
        #expect(record.parentID == env.rootID)
        #expect(record.uri == .my("/new.txt"))
        #expect(try env.logged() == [LoggedChange(id: id, kind: .update)])
    }

    @Test func remoteCreateUnderUnknownParentIsIgnored() async throws {
        let env = try await EngineHarness.make()
        env.server.addFolder("/unknown")
        let id = env.server.addFile("/unknown/z.txt")
        let changed = try await env.engine.applyRemoteEvents([FileEvent(type: .create, fileID: id, from: "/unknown/z.txt")])
        #expect(!changed)
        #expect(try env.record(id) == nil)
        #expect(try env.latestSeq() == 0)
    }

    @Test func remoteModifyUpdatesEntity() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/m.txt", id: "m")
        try await env.enumerateAll(env.rootID)
        let before = try env.latestSeq()
        let newer = env.server.replaceContent("/m.txt", with: Data("changed".utf8))
        let event = FileEvent(type: .modify, fileID: "m", from: "/m.txt")

        #expect(try await env.engine.applyRemoteEvents([event]))
        #expect(try env.record("m")?.entityID == newer)
        #expect(try env.record("m")?.size == 7)
        #expect(try env.logged(after: before) == [LoggedChange(id: "m", kind: .update)])
        // 重复事件（服务端去抖后重发）不产生新日志
        #expect(try await env.engine.applyRemoteEvents([event]) == false)
    }

    @Test func remoteModifyOfVanishedFileRemovesLocalRow() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/m.txt", id: "m")
        try await env.enumerateAll(env.rootID)
        env.server.remove("/m.txt")
        #expect(try await env.engine.applyRemoteEvents([FileEvent(type: .modify, fileID: "m", from: "/m.txt")]))
        #expect(try env.record("m") == nil)
    }

    @Test func remoteDeleteMatchesByIDNotPath() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/d.txt", id: "d")
        try await env.enumerateAll(env.rootID)
        // 旧 id 已不在镜像中，原路径现属新 id：迟到的旧 delete 事件不得删除新条目
        try env.items.upsert([DBFixtures.item("new", path: "/p.txt")])
        let before = try env.latestSeq()
        env.server.remove("/d.txt")

        let changed = try await env.engine.applyRemoteEvents([
            FileEvent(type: .delete, fileID: "d", from: "/stale-path.txt"),
            FileEvent(type: .delete, fileID: "old", from: "/p.txt")
        ])
        #expect(changed)
        #expect(try env.record("d") == nil)
        #expect(try env.record("new") != nil)
        #expect(try env.logged(after: before) == [LoggedChange(id: "d", kind: .delete)])
    }

    /// Verification 7：远端重命名目录 → 后代 uri 改前缀，日志只记目录本身。
    @Test func remoteRenameOfFolderReprefixesDescendants() async throws {
        let env = try await EngineHarness.make()
        env.server.addFolder("/a", id: "A")
        env.server.addFile("/a/x.txt", id: "X")
        try await env.enumerateAll(env.rootID)
        try await env.enumerateAll("A")
        let before = try env.latestSeq()
        env.server.relocate("/a", to: "/b")

        let changed = try await env.engine.applyRemoteEvents([FileEvent(type: .rename, fileID: "A", from: "/a", to: "/b")])
        #expect(changed)
        #expect(try env.record("X")?.uri.description == "cloudreve://my/b/x.txt")
        #expect(try env.record("X")?.parentID == "A")
        #expect(try env.record("A")?.uri == .my("/b"))
        #expect(try env.logged(after: before) == [LoggedChange(id: "A", kind: .update)])
    }

    @Test func reconcileDiscoversRemoteAddAndDelete() async throws {
        let env = try await EngineHarness.make()
        env.server.addFolder("/docs", id: "docs")
        env.server.addFile("/docs/old.txt", id: "old")
        env.server.addFile("/keep.txt", id: "keep")
        try await env.enumerateAll(env.rootID)
        try await env.enumerateAll("docs")
        #expect(try await env.engine.reconcile() == false)

        let before = try env.latestSeq()
        let added = env.server.addFile("/docs/new.txt")
        env.server.remove("/docs/old.txt")
        #expect(try await env.engine.reconcile())
        #expect(try env.record(added)?.parentID == "docs")
        #expect(try env.record("old") == nil)
        #expect(try env.record("keep") != nil)
        #expect(Set(try env.logged(after: before)) == [LoggedChange(id: added, kind: .update), LoggedChange(id: "old", kind: .delete)])
        #expect(try DriveStore(db: env.db).get(id: env.driveID)?.lastReconcileAt != nil)

        // 已枚举目录在远端整体消失：父目录重列时连同后代删除，子目录本身跳过
        env.server.remove("/docs")
        #expect(try await env.engine.reconcile())
        #expect(try env.record("docs") == nil)
        #expect(try env.record(added) == nil)
    }
}
