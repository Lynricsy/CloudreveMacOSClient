import CloudreveAPI
import Foundation
import Testing
@testable import CloudreveSync

// modify：字段顺序、部分失败与内容冲突。
extension SyncEngineTests {
    private static let original = Data("old".utf8)

    /// 服务端与本地镜像都有 `/name.txt`（id `a`）与目录 `/dst`（id `dst`）。
    private static func modifyFixture() async throws -> (EngineHarness, entity: String) {
        let env = try await EngineHarness.make()
        let entity = try #require(env.server.node(id: env.server.addFile("/name.txt", content: original, id: "a"))?.entityID)
        env.server.addFolder("/dst", id: "dst")
        try await env.enumerateAll(env.rootID)
        await env.mock.resetRequests()
        return (env, entity)
    }

    private static func modify(
        _ env: EngineHarness, fields: ItemFields, newName: String? = nil, newParentID: String? = nil,
        content: Data? = nil, base: String?, failOnConflict: Bool = true
    ) async throws -> ModifyResult {
        try await env.engine.modify(
            id: "a", fields: fields, newName: newName, newParentID: newParentID,
            contents: try content.map(EngineHarness.tempFile), mtime: Date(), baseContentVersion: base,
            failOnConflict: failOnConflict, progress: ignoreProgress
        )
    }

    @Test func modifyAppliesRenameMoveContentsInOrder() async throws {
        let (env, entity) = try await Self.modifyFixture()
        let result = try await Self.modify(
            env, fields: [.filename, .parent, .contents, .tagData], newName: "b.txt", newParentID: "dst",
            content: Data("new content".utf8), base: entity
        )
        #expect(result.pendingFields.isEmpty)
        #expect(!result.shouldFetchContent)
        #expect(result.item.uri == .my("/dst/b.txt"))
        #expect(result.item.parentID == "dst")
        let node = try #require(env.server.node("/dst/b.txt"))
        #expect(node.id == "a")
        #expect(node.content == Data("new content".utf8))
        #expect(result.item.entityID == node.entityID && node.entityID != entity)
        #expect(try env.record("a")?.uri == .my("/dst/b.txt"))

        let calls = await env.mock.requests.map { "\($0.method) \($0.url.path)" }
        let order = ["POST /api/v4/file/rename", "POST /api/v4/file/move", "PUT /api/v4/file/upload"].compactMap(calls.firstIndex(of:))
        #expect(order.count == 3)
        #expect(order == order.sorted())
    }

    @Test func modifyPartialFailureReturnsPendingFields() async throws {
        let (env, entity) = try await Self.modifyFixture()
        env.server.failNext("POST", "/api/v4/file/move", code: 40073)
        let result = try await Self.modify(
            env, fields: [.filename, .parent, .contents], newName: "b.txt", newParentID: "dst",
            content: Data("new".utf8), base: entity
        )
        #expect(result.pendingFields == [.parent, .contents])
        #expect(!result.shouldFetchContent)
        #expect(result.item.name == "b.txt")
        #expect(result.item.parentID == env.rootID)
        #expect(env.server.node("/b.txt")?.content == Self.original)
        #expect(await env.mock.requests("PUT", pathPrefix: "/api/v4/file/upload").isEmpty)
    }

    @Test func modifyFirstStepFailureThrows() async throws {
        let (env, entity) = try await Self.modifyFixture()
        env.server.failNext("POST", "/api/v4/file/rename", code: 40004)
        await #expect(throws: SyncError.filenameCollision(existing: nil)) {
            try await Self.modify(env, fields: [.filename, .parent], newName: "b.txt", newParentID: "dst", base: entity)
        }
        #expect(try env.record("a")?.uri == .my("/name.txt"))
        #expect(await env.mock.requests("POST", pathPrefix: "/api/v4/file/move").isEmpty)
    }

    @Test func modifyUnsyncedFieldsTouchesNothing() async throws {
        let (env, entity) = try await Self.modifyFixture()
        let result = try await Self.modify(env, fields: [.contentModificationDate, .tagData, .extendedAttributes], base: entity)
        #expect(result.pendingFields.isEmpty)
        #expect(result.item.id == "a")
        #expect(await env.mock.requests.isEmpty)
    }

    /// Verification 6：内容冲突时另存副本并让系统重新下载服务端版本；`failOnConflict` 时直接报冲突。
    @Test func contentConflictProducesCopy() async throws {
        let (env, entity) = try await Self.modifyFixture()
        let local = Data("local edit".utf8)
        await #expect(throws: SyncError.versionConflict) {
            try await Self.modify(env, fields: [.contents], content: local, base: "old", failOnConflict: true)
        }
        #expect(env.server.childNames("/").allSatisfy { !$0.hasPrefix(ConflictNaming.prefix) })

        let result = try await Self.modify(env, fields: [.contents], content: local, base: "old", failOnConflict: false)
        #expect(result.shouldFetchContent)
        #expect(result.pendingFields.isEmpty)
        #expect(result.item.id == "a")
        #expect(result.item.entityID == entity)
        #expect(env.server.node("/name.txt")?.content == Self.original)

        let copyName = ConflictNaming.conflictCopyName(for: "name.txt", at: env.clock.now)
        #expect(copyName.hasPrefix("__conflict__") && copyName.hasSuffix("_name.txt"))
        let copy = try #require(env.server.node("/\(copyName)"))
        #expect(copy.content == local)
        #expect(try env.record(copy.id)?.parentID == env.rootID)
        #expect(try env.logged().contains(LoggedChange(id: copy.id, kind: .update)))

        let transfers = try env.transfers.recent(driveID: env.driveID)
        let conflictRows = transfers.filter { $0.itemID == "a" }
        #expect(conflictRows.count == 2)
        #expect(conflictRows.allSatisfy { $0.state == .failed })
        // 两条冲突分支（报冲突、另存副本）都标记 isConflict（App 据此发冲突通知）
        #expect(conflictRows.allSatisfy { $0.isConflict })
        #expect(conflictRows.compactMap(\.error).contains("版本冲突，已另存为 \(copyName)"))
        #expect(transfers.contains { $0.name == copyName && $0.state == .done && !$0.isConflict })
    }

    /// 系统未提供基准版本时不以镜像 entity 为锁：镜像已被远端事件刷新到用户未见过的版本，覆盖也必须按冲突处理。
    @Test func modifyWithoutBaseRejectsEvenWhenMirrorWasRefreshed() async throws {
        let (env, _) = try await Self.modifyFixture()
        let remote = Data("edited elsewhere".utf8)
        env.server.replaceContent("/name.txt", with: remote)
        try await env.enumerateAll(env.rootID)
        #expect(try env.record("a")?.entityID == env.server.node("/name.txt")?.entityID)
        await #expect(throws: SyncError.versionConflict) {
            try await Self.modify(env, fields: [.contents], content: Data("mine".utf8), base: nil, failOnConflict: true)
        }
        #expect(env.server.node("/name.txt")?.content == remote)
        #expect(try env.transfers.recent(driveID: env.driveID).first?.isConflict == true)
    }

    /// 内容变更却没有本地文件：在任何字段生效前拒绝，不改名、不把服务端内容覆盖为空。
    @Test func modifyContentsWithoutFileTouchesNothing() async throws {
        let (env, entity) = try await Self.modifyFixture()
        await #expect(throws: SyncError.self) {
            try await Self.modify(env, fields: [.filename, .contents], newName: "b.txt", content: nil, base: entity)
        }
        #expect(env.server.node("/name.txt")?.content == Self.original)
        #expect(await env.mock.requests.isEmpty)
    }

    /// 镜像路径已过期（远端改名后原路径被另一个文件占用）：内容覆盖必须写到该 id 的当前位置，而不是覆盖占位者。
    @Test func modifyContentsTargetsCurrentServerLocationByID() async throws {
        let (env, entity) = try await Self.modifyFixture()
        env.server.relocate("/name.txt", to: "/renamed.txt")
        env.server.addFile("/name.txt", content: Data("other".utf8), id: "other")

        let result = try await Self.modify(env, fields: [.contents], content: Data("mine".utf8), base: entity)
        #expect(env.server.node(id: "a")?.content == Data("mine".utf8))
        #expect(env.server.node(id: "other")?.content == Data("other".utf8))
        #expect(result.item.uri == .my("/renamed.txt"))
        #expect(try env.record("a")?.uri == .my("/renamed.txt"))
    }

    /// 目标目录远端已换路径且原路径被另一个目录占用：移动必须按目标 id 解析当前路径。
    @Test func moveTargetsDestinationFolderByID() async throws {
        let (env, entity) = try await Self.modifyFixture()
        env.server.relocate("/dst", to: "/dst2")
        env.server.addFolder("/dst", id: "impostor")

        let result = try await Self.modify(env, fields: [.parent], newParentID: "dst", base: entity)
        #expect(env.server.node(id: "a")?.segments == ["dst2", "name.txt"])
        #expect(env.server.childNames("/dst").isEmpty)
        #expect(result.item.uri == .my("/dst2/name.txt"))
        #expect(result.item.parentID == "dst")
    }
}
