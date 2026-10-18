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

    /// 移入回收站的文件按 id 仍能查到，但 path 是 `cloudreve://trash/…`：补发的改名事件不得按事件路径把它写回挂载根。
    @Test func remoteEventForTrashedFileRemovesInsteadOfResurrecting() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/a.txt", id: "f")
        try await env.enumerateAll(env.rootID)
        env.server.relocate("/a.txt", to: "/b.txt")
        env.server.trash("/b.txt")

        _ = try await env.engine.applyRemoteEvents([FileEvent(type: .rename, fileID: "f", from: "/a.txt", to: "/b.txt")])
        #expect(try env.record("f") == nil)
        #expect(try env.logged().last == LoggedChange(id: "f", kind: .delete))
    }

    /// 本地删除一个服务端已移入回收站的文件：视为已删除，而不是因回收站路径无法解析而报错。
    @Test func deletingTrashedFileSucceeds() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/a.txt", id: "f")
        try await env.enumerateAll(env.rootID)
        env.server.trash("/a.txt")

        try await env.engine.delete(id: "f", recursive: true, baseContentVersion: nil)
        #expect(try env.record("f") == nil)
    }

    /// `my` 路径本身损坏（无法解码）不同于移入回收站：必须报错，不得把仍存在的条目当作已删除清出镜像。
    @Test func malformedMyPathFailsWithoutRemovingMirror() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/a.txt", id: "f")
        try await env.enumerateAll(env.rootID)
        var broken = try #require(env.server.node(id: "f")).response
        broken.path = "cloudreve://my/%ZZ"
        for _ in 0..<2 { env.server.overrideNext("GET", "/api/v4/file/info", with: try .envelope(encoding: broken)) }

        await #expect(throws: (any Error).self) {
            _ = try await env.engine.applyRemoteEvents([FileEvent(type: .modify, fileID: "f", from: "/a.txt")])
        }
        await #expect(throws: (any Error).self) {
            try await env.engine.delete(id: "f", recursive: true, baseContentVersion: nil)
        }
        #expect(try env.record("f")?.uri == .my("/a.txt"))
        #expect(env.server.node(id: "f") != nil)
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

    @Test func queuedEventsSurviveFailedApplyAndAreRemovedAfterSuccess() async throws {
        let env = try await EngineHarness.make()
        let queue = RemoteEventQueue(db: env.db)
        let id = env.server.addFile("/queued.txt")
        try queue.append(driveID: env.driveID, events: [FileEvent(type: .create, fileID: id, from: "/queued.txt")])

        // 应用中途失败（扩展被回收或网络错误同理）：事件不得丢失
        env.server.failNext("GET", "/api/v4/file/info", code: 500)
        await #expect(throws: (any Error).self) { try await env.engine.applyQueuedRemoteChanges() }
        #expect(try env.record(id) == nil)
        #expect(try queue.next(driveID: env.driveID, limit: 10) != nil)

        #expect(try await env.engine.applyQueuedRemoteChanges())
        #expect(try env.record(id)?.parentID == env.rootID)
        #expect(try queue.next(driveID: env.driveID, limit: 10) == nil)
        #expect(try await env.engine.applyQueuedRemoteChanges() == false)
    }

    @Test func queuedReconcileRequestRelistsEnumeratedFolders() async throws {
        let env = try await EngineHarness.make()
        try await env.enumerateAll(env.rootID)
        let added = env.server.addFile("/missed.txt")
        // 事件已被服务端丢弃，只剩兜底请求
        try RemoteEventQueue(db: env.db).requestReconcile(driveID: env.driveID)
        #expect(try await env.engine.applyQueuedRemoteChanges())
        #expect(try env.record(added) != nil)
    }

    @Test func concurrentQueueDrainsApplyEachBatchOnce() async throws {
        let env = try await EngineHarness.make()
        let queue = RemoteEventQueue(db: env.db)
        let id = env.server.addFile("/race.txt")
        try queue.append(driveID: env.driveID, events: [FileEvent(type: .create, fileID: id, from: "/race.txt")])
        env.server.setLatency("GET /api/v4/file/info", .milliseconds(200))
        await env.mock.resetRequests()

        // 两个枚举请求同时 drain：同一批只能由一方应用，另一方看到空队列
        async let first = env.engine.applyQueuedRemoteChanges()
        async let second = env.engine.applyQueuedRemoteChanges()
        let results = try await [first, second]
        #expect(results.sorted { !$0 && $1 } == [false, true])
        #expect(await env.mock.requests("GET", pathPrefix: "/api/v4/file/info").count == 1)
        #expect(try env.logged().filter { $0.id == id } == [LoggedChange(id: id, kind: .update)])
        #expect(try queue.next(driveID: env.driveID, limit: 10) == nil)
    }

    /// 全量 reconcile 中目录在两个已枚举目录间移动：不得先删后补（后代被删、enumeratedAt 丢失）。
    @Test func reconcileFollowsFolderMovedBetweenEnumeratedFolders() async throws {
        let env = try await EngineHarness.make()
        env.server.addFolder("/a", id: "A")
        env.server.addFolder("/a/D", id: "D")
        env.server.addFile("/a/D/x.txt", id: "X")
        env.server.addFolder("/z", id: "Z")
        for folder in [env.rootID, "A", "D", "Z"] { try await env.enumerateAll(folder) }
        let before = try env.latestSeq()
        env.server.relocate("/a/D", to: "/z/D")

        #expect(try await env.engine.reconcile())
        let moved = try #require(try env.record("D"))
        #expect(moved.uri == .my("/z/D"))
        #expect(moved.parentID == "Z")
        #expect(moved.enumeratedAt != nil)
        #expect(try env.record("X")?.uri == .my("/z/D/x.txt"))
        #expect(try env.logged(after: before).allSatisfy { $0.kind == .update })

        // 之后在 D 中的远端新增仍能被周期 reconcile 发现
        let added = env.server.addFile("/z/D/new.txt")
        #expect(try await env.engine.reconcile())
        #expect(try env.record(added)?.parentID == "D")
    }

    /// 目录移走后原路径被另一个新目录占用，且旧父目录先于新父目录扫描：占位清理也要延后，
    /// 不得删掉原目录子树再以未枚举状态补回。
    @Test func reconcileKeepsMovedFolderWhoseOldPathIsReused() async throws {
        let env = try await EngineHarness.make()
        env.server.addFolder("/a", id: "A")
        env.server.addFolder("/a/D", id: "D")
        env.server.addFile("/a/D/x.txt", id: "X")
        env.server.addFolder("/z", id: "Z")
        for folder in [env.rootID, "A", "D", "Z"] { try await env.enumerateAll(folder) }
        let before = try env.latestSeq()
        env.server.relocate("/a/D", to: "/z/D")
        env.server.addFolder("/a/D", id: "N")

        #expect(try await env.engine.reconcile())
        let moved = try #require(try env.record("D"))
        #expect(moved.uri == .my("/z/D"))
        #expect(moved.enumeratedAt != nil)
        #expect(try env.record("X")?.uri == .my("/z/D/x.txt"))
        #expect(try env.record("N")?.uri == .my("/a/D"))
        #expect(try env.logged(after: before).allSatisfy { $0.kind == .update })
        #expect(try env.mirrorPaths().count == 5)
    }

    /// 扫描中途失败：暂存的占位行不得残留在镜像里（按旧语义删除并记日志），下一轮可正常重建。
    @Test func failedReconcileLeavesNoParkedRows() async throws {
        let env = try await EngineHarness.make()
        env.server.addFolder("/a", id: "A")
        env.server.addFolder("/a/D", id: "D")
        env.server.addFile("/a/D/x.txt", id: "X")
        env.server.addFolder("/z", id: "Z")
        for folder in [env.rootID, "A", "D", "Z"] { try await env.enumerateAll(folder) }
        env.server.relocate("/a/D", to: "/z/D")
        env.server.addFolder("/a/D", id: "N")
        env.server.failNext("GET", "/api/v4/file", code: 50000, uri: "/z")

        await #expect(throws: SyncError.self) { try await env.engine.reconcile() }
        #expect(try env.mirrorPaths().allSatisfy { $0.isDescendant(ofOrEqualTo: .my("/")) })
        #expect(try env.mirrorPaths().count == 3)
        #expect(try env.record("D") == nil)
        #expect(try env.record("X") == nil)
        #expect(try env.record("N")?.uri == .my("/a/D"))

        #expect(try await env.engine.reconcile())
        #expect(try env.record("D")?.uri == .my("/z/D"))
    }

    /// 含兜底请求的批次也要应用同批精确事件：reconcile 只覆盖已枚举目录，未枚举目录中已知条目的变化只能靠事件。
    @Test func queuedReconcileBatchStillAppliesPreciseEvents() async throws {
        let env = try await EngineHarness.make()
        env.server.addFolder("/d", id: "D")
        try await env.enumerateAll(env.rootID)
        env.server.addFile("/d/f.txt", id: "F")
        #expect(try await env.engine.applyRemoteEvents([FileEvent(type: .create, fileID: "F", from: "/d/f.txt")]))
        env.server.addFile("/d/g.txt", id: "G")
        #expect(try await env.engine.applyRemoteEvents([FileEvent(type: .create, fileID: "G", from: "/d/g.txt")]))

        let newer = env.server.replaceContent("/d/f.txt", with: Data("changed".utf8))
        env.server.remove("/d/g.txt")
        let queue = RemoteEventQueue(db: env.db)
        try queue.append(driveID: env.driveID, events: [
            FileEvent(type: .modify, fileID: "F", from: "/d/f.txt"), FileEvent(type: .delete, fileID: "G", from: "/d/g.txt")
        ])
        try queue.requestReconcile(driveID: env.driveID)

        #expect(try await env.engine.applyQueuedRemoteChanges())
        #expect(try env.record("F")?.entityID == newer)
        #expect(try env.record("G") == nil)
        #expect(try queue.next(driveID: env.driveID, limit: 10) == nil)
    }

    /// 同一目录的两次分页枚举交错：各自跟踪本轮见过的子项，不得互相重置导致误删。
    @Test func overlappingListingsOfSameFolderAreIsolated() async throws {
        let env = try await EngineHarness.make()
        for name in ["a", "b", "c"] { env.server.addFile("/\(name).txt", id: name) }
        env.server.setPageSizeLimit(1)

        let first = try #require(try await env.engine.enumerateFolder(id: env.rootID, pageToken: nil).nextToken)
        let second = try #require(try await env.engine.enumerateFolder(id: env.rootID, pageToken: first).nextToken)
        _ = try await env.engine.enumerateFolder(id: env.rootID, pageToken: nil)
        let last = try await env.engine.enumerateFolder(id: env.rootID, pageToken: second)
        #expect(last.nextToken == nil)
        for name in ["a", "b", "c"] { #expect(try env.record(name) != nil, "\(name)") }
    }

    /// 枚举进行中由其他途径（事件、并发枚举）新增的子项不属于本轮删除差集。
    @Test func listingDoesNotDeleteItemsAddedDuringScan() async throws {
        let env = try await EngineHarness.make()
        for name in ["a", "b"] { env.server.addFile("/\(name).txt", id: name) }
        env.server.setPageSizeLimit(1)

        let token = try #require(try await env.engine.enumerateFolder(id: env.rootID, pageToken: nil).nextToken)
        env.server.addFile("/0.txt", id: "n")
        #expect(try await env.engine.applyRemoteEvents([FileEvent(type: .create, fileID: "n", from: "/0.txt")]))
        var next: String? = token
        while let current = next {
            next = try await env.engine.enumerateFolder(id: env.rootID, pageToken: current).nextToken
        }
        #expect(try env.record("n") != nil)
        #expect(try env.record("a") != nil && env.record("b") != nil)
    }

    /// 普通列目录发现已知目录换了位置：后代 uri 同步迁移，之后到达的 rename 事件不出错。
    @Test func listingThatDiscoversFolderRenameMovesDescendants() async throws {
        let env = try await EngineHarness.make()
        env.server.addFolder("/a", id: "A")
        env.server.addFile("/a/x.txt", id: "X")
        try await env.enumerateAll(env.rootID)
        try await env.enumerateAll("A")
        env.server.relocate("/a", to: "/b")

        try await env.enumerateAll(env.rootID)
        #expect(try env.record("A")?.uri == .my("/b"))
        #expect(try env.record("X")?.uri == .my("/b/x.txt"))
        _ = try await env.engine.applyRemoteEvents([FileEvent(type: .rename, fileID: "A", from: "/a", to: "/b")])
        #expect(try env.record("X")?.uri == .my("/b/x.txt"))
    }

    /// 按 id 补查到的目录已在挂载根之外：报 noSuchItem，不得列出或存储根外子项。
    @Test func enumeratingFolderMovedOutsideMountRootIsNoSuchItem() async throws {
        let env = try await EngineHarness.make(remoteRoot: .my("/work"))
        env.server.addFolder("/work")
        env.server.addFolder("/work/D", id: "D")
        env.server.addFolder("/private")
        try await env.enumerateAll(env.rootID)
        #expect(try env.record("D")?.uri == .my("/work/D"))

        env.server.relocate("/work/D", to: "/private/D")
        env.server.addFile("/private/D/secret.txt", id: "S")
        _ = try await env.engine.applyRemoteEvents([FileEvent(type: .rename, fileID: "D", from: "/D", to: "/D")])
        #expect(try env.record("D") == nil)

        await #expect(throws: SyncError.noSuchItem) { try await env.engine.enumerateFolder(id: "D", pageToken: nil) }
        #expect(try env.record("S") == nil)
        #expect(try env.record("D") == nil)
    }

    /// 目录迁移的目标位置残留陈旧镜像行：同一事务内清理占位再迁移后代，不得撞唯一索引阻塞队列。
    @Test func remoteFolderMoveOntoStaleOccupantSucceeds() async throws {
        let env = try await EngineHarness.make()
        env.server.addFolder("/a", id: "A")
        env.server.addFile("/a/x.txt", id: "X")
        try await env.enumerateAll(env.rootID)
        try await env.enumerateAll("A")
        try env.items.upsert([
            DBFixtures.item("SB", path: "/b", folder: true), DBFixtures.item("SX", path: "/b/x.txt", parent: "SB")
        ])
        env.server.relocate("/a", to: "/b")

        let queue = RemoteEventQueue(db: env.db)
        try queue.append(driveID: env.driveID, events: [FileEvent(type: .rename, fileID: "A", from: "/a", to: "/b")])
        #expect(try await env.engine.applyQueuedRemoteChanges())
        #expect(try env.record("A")?.uri == .my("/b"))
        #expect(try env.record("X")?.uri == .my("/b/x.txt"))
        #expect(try env.record("SB") == nil)
        #expect(try env.record("SX") == nil)
        #expect(try queue.next(driveID: env.driveID, limit: 10) == nil)
    }
}
