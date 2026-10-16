import CloudreveAPI
import Foundation
import Testing
@testable import CloudreveSync

/// 同步引擎行为测试（内存库 + TestServer）。修改类、传输类与远端事件类测试见同名扩展文件。
@Suite struct SyncEngineTests {
    // MARK: - 查询

    @Test func rootItemUsesDriveNameAndUnknownIDThrows() async throws {
        let env = try await EngineHarness.make()
        let root = try await env.engine.item(id: env.rootID)
        #expect(root.name == "我的云盘")
        #expect(root.parentID == nil)
        #expect(root.isFolder)
        await #expect(throws: SyncError.noSuchItem) { try await env.engine.item(id: "missing") }
    }

    @Test func workingSetExcludesRoot() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/a.txt", id: "a")
        env.server.addFolder("/d", id: "d")
        try await env.enumerateAll(env.rootID)
        let (items, next) = try await env.engine.workingSetItems(afterRowID: 0, limit: 500)
        #expect(Set(items.map(\.id)) == ["a", "d"])
        #expect(next == nil)
    }

    // MARK: - 目录枚举

    /// Verification 5：删除差集只在末页计算。
    @Test func pagedEnumerationDeletesOnlyAtLastPage() async throws {
        let env = try await EngineHarness.make()
        try env.items.upsert(["a", "b", "c"].map { DBFixtures.item($0, path: "/\($0).txt") })
        env.server.addFile("/a.txt", id: "a")
        env.server.addFile("/b.txt", id: "b")
        env.server.setPageSizeLimit(1)
        let before = try env.latestSeq()

        let first = try await env.engine.enumerateFolder(id: env.rootID, pageToken: nil)
        #expect(first.items.map(\.id) == ["a"])
        let token = try #require(first.nextToken)
        #expect(try env.record("c") != nil)
        #expect(try env.logged(after: before).allSatisfy { $0.kind == .update })

        let second = try await env.engine.enumerateFolder(id: env.rootID, pageToken: token)
        #expect(second.items.map(\.id) == ["b"])
        #expect(second.nextToken == nil)
        #expect(try env.record("c") == nil)
        #expect(try env.logged(after: before).filter { $0.kind == .delete } == [LoggedChange(id: "c", kind: .delete)])
        #expect(try env.record(env.rootID)?.enumeratedAt != nil)
    }

    /// 扩展重启后从中间页继续：没有首页记录，末页不做删除差集。
    @Test func resumedListingSkipsDeleteDiff() async throws {
        let env = try await EngineHarness.make()
        try env.items.upsert([DBFixtures.item("c", path: "/c.txt")])
        env.server.addFile("/a.txt", id: "a")
        env.server.addFile("/b.txt", id: "b")
        env.server.setPageSizeLimit(1)
        let page = try await env.engine.enumerateFolder(id: env.rootID, pageToken: "cursor-1")
        #expect(page.items.map(\.id) == ["b"])
        #expect(page.nextToken == nil)
        #expect(try env.record("c") != nil)
    }

    @Test func enumeratingUnknownFolderFetchesItsInfo() async throws {
        let env = try await EngineHarness.make()
        env.server.addFolder("/docs", id: "docs")
        env.server.addFile("/docs/x.txt", id: "x")
        let page = try await env.engine.enumerateFolder(id: "docs", pageToken: nil)
        #expect(page.items.map(\.uri) == [.my("/docs/x.txt")])
        #expect(try env.record("docs")?.parentID == env.rootID)
        #expect(try env.record("x")?.parentID == "docs")
    }

    // MARK: - 变更枚举

    @Test func changesMergePerItemLaterWins() async throws {
        let env = try await EngineHarness.make()
        try env.items.upsert([DBFixtures.item("a", path: "/a.txt"), DBFixtures.item("b", path: "/b.txt")])
        let base = try env.latestSeq()
        let log = env.changeLog
        try log.append(driveID: env.driveID, itemID: "a", kind: .delete)
        try log.append(driveID: env.driveID, itemID: "b", kind: .update)
        try log.append(driveID: env.driveID, itemID: "a", kind: .update)
        try log.append(driveID: env.driveID, itemID: "b", kind: .delete)
        try log.append(driveID: env.driveID, itemID: "ghost", kind: .update)

        let batch = try await env.engine.changes(since: base)
        #expect(batch.updated.map(\.id) == ["a"])
        #expect(batch.deleted == ["b", "ghost"])
        #expect(batch.anchor == base + 5)
        #expect(!batch.moreComing)
        #expect(try await env.engine.currentAnchor() == batch.anchor)

        let tail = try await env.engine.changes(since: batch.anchor)
        #expect(tail.updated.isEmpty && tail.deleted.isEmpty)
        #expect(tail.anchor == batch.anchor)
    }

    /// Verification 9：裁剪后过旧的 anchor 过期，裁剪边界之内的 anchor 正常分批。
    @Test func changesReportExpiredAnchorAfterPrune() async throws {
        let env = try await EngineHarness.make()
        try env.changeLog.appendMany(driveID: env.driveID, itemIDs: (1...30000).map { "i\($0)" }, kind: .delete)
        try await env.engine.maintenance()
        #expect(try env.changeLog.oldestSeq(driveID: env.driveID) == 10001)

        await #expect(throws: SyncError.syncAnchorExpired) { try await env.engine.changes(since: 5) }
        let batch = try await env.engine.changes(since: 10001)
        #expect(batch.deleted.count == 1000)
        #expect(batch.deleted.first == "i10002")
        #expect(batch.anchor == 11001)
        #expect(batch.moreComing)
        #expect(try await env.engine.changes(since: 10000).deleted.first == "i10001")
        await #expect(throws: SyncError.syncAnchorExpired) { try await env.engine.changes(since: 30001) }
    }

    // MARK: - 凭证

    @Test func credentialFailureMarksDriveExpired() async throws {
        let env = try await EngineHarness.make()
        env.server.failNext("POST", "/api/v4/file/create", code: 401)
        env.server.failNext("POST", "/api/v4/session/token/refresh", code: 40020)
        await #expect(throws: SyncError.notAuthenticated) {
            try await env.engine.createFolder(name: "docs", parentID: env.rootID, mayAlreadyExist: false)
        }
        #expect(try env.driveStatus() == .credentialExpired)
        #expect(await env.mock.requests("POST", pathPrefix: "/api/v4/session/token/refresh").count == 1)
        #expect(env.server.node("/docs") == nil)
    }
}
