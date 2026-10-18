import CloudreveAPI
import Foundation
import Testing
@testable import CloudreveSync

// 新建、删除与下载。
extension SyncEngineTests {
    // MARK: - 新建目录

    @Test func createFolderStoresAndLogs() async throws {
        let env = try await EngineHarness.make()
        let item = try await env.engine.createFolder(name: "新建 文件夹", parentID: env.rootID, mayAlreadyExist: false)
        #expect(item.isFolder)
        #expect(item.parentID == env.rootID)
        #expect(item.uri == .my("/新建 文件夹"))
        #expect(env.server.node("/新建 文件夹")?.id == item.id)
        #expect(try env.logged() == [LoggedChange(id: item.id, kind: .update)])
    }

    @Test func createFolderConflictBranches() async throws {
        let env = try await EngineHarness.make()
        let existing = env.server.addFolder("/docs")
        let file = env.server.addFile("/notes")
        let item = try await env.engine.createFolder(name: "docs", parentID: env.rootID, mayAlreadyExist: true)
        #expect(item.id == existing)
        #expect(try env.record(existing)?.uri == .my("/docs"))
        let error = await #expect(throws: SyncError.self) {
            try await env.engine.createFolder(name: "docs", parentID: env.rootID, mayAlreadyExist: false)
        }
        #expect(error?.collidingItemID == existing)
        // 同名的是文件：即使允许已存在也不能把文件当成目录返回
        let fileError = await #expect(throws: SyncError.self) {
            try await env.engine.createFolder(name: "notes", parentID: env.rootID, mayAlreadyExist: true)
        }
        #expect(fileError?.collidingItemID == file)
    }

    // MARK: - 新建文件

    @Test(arguments: ["~$报告.docx", ".DS_Store", "debug.log"])
    func createFileIgnoredNameIsExcluded(name: String) async throws {
        let env = try await EngineHarness.make()
        let url = try EngineHarness.tempFile(Data("x".utf8))
        await #expect(throws: SyncError.excludedFromSync) {
            try await env.engine.createFile(
                name: name, parentID: env.rootID, contents: url, mtime: Date(), mayAlreadyExist: false, progress: ignoreProgress
            )
        }
        #expect(await env.mock.requests.isEmpty)
        #expect(try env.transfers.recent(driveID: nil).isEmpty)
    }

    @Test func createFileUploadsChunksAndRecordsTransfer() async throws {
        let env = try await EngineHarness.make()
        env.server.addFolder("/docs", id: "docs")
        try await env.enumerateAll(env.rootID)
        let content = Data("0123456789".utf8)
        let progress = ProgressRecorder()
        let item = try #require(try await env.engine.createFile(
            name: "报告 1.txt", parentID: "docs", contents: try EngineHarness.tempFile(content), mtime: Date(),
            mayAlreadyExist: false, progress: progress.handler
        ))
        let node = try #require(env.server.node("/docs/报告 1.txt"))
        #expect(node.content == content)
        #expect(item.id == node.id)
        #expect(item.entityID == node.entityID)
        #expect(item.size == 10)
        #expect(item.parentID == "docs")
        #expect(await env.mock.requests("POST", pathPrefix: "/api/v4/file/upload/").count == 3)
        #expect(progress.last == 10)
        let transfer = try #require(try env.transfers.recent(driveID: env.driveID).first)
        #expect(transfer.kind == .upload)
        #expect(transfer.state == .done)
        #expect(transfer.doneBytes == 10 && transfer.totalBytes == 10)
        #expect(try env.logged().contains(LoggedChange(id: item.id, kind: .update)))
    }

    @Test func createEmptyFileUsesCreateEndpoint() async throws {
        let env = try await EngineHarness.make()
        let item = try #require(try await env.engine.createFile(
            name: "empty.txt", parentID: env.rootID, contents: nil, mtime: Date(), mayAlreadyExist: false, progress: ignoreProgress
        ))
        #expect(env.server.node("/empty.txt")?.content == Data())
        #expect(item.size == 0)
        #expect(await env.mock.requests("PUT", pathPrefix: "/api/v4/file/upload").isEmpty)
    }

    /// 系统重新导入（mayAlreadyExist）命中服务端同名文件：内容不同 → 冲突（不得把服务端版本当成上传成功）；
    /// 内容逐字节相同 → 返回服务端条目；不允许已存在 → 冲突。
    @Test func createFileConflictBranches() async throws {
        let env = try await EngineHarness.make()
        let existing = env.server.addFile("/a.txt", content: Data("server".utf8))
        let local = try EngineHarness.tempFile(Data("local!".utf8))
        let differs = await #expect(throws: SyncError.self) {
            try await env.engine.createFile(
                name: "a.txt", parentID: env.rootID, contents: local, mtime: Date(), mayAlreadyExist: true, progress: ignoreProgress
            )
        }
        #expect(differs?.collidingItemID == existing)
        #expect(env.server.node("/a.txt")?.content == Data("server".utf8))
        #expect(try env.record(existing)?.uri == .my("/a.txt"))

        let same = try EngineHarness.tempFile(Data("server".utf8))
        let item = try await env.engine.createFile(
            name: "a.txt", parentID: env.rootID, contents: same, mtime: Date(), mayAlreadyExist: true, progress: ignoreProgress
        )
        #expect(item?.id == existing)

        let refused = await #expect(throws: SyncError.self) {
            try await env.engine.createFile(
                name: "a.txt", parentID: env.rootID, contents: same, mtime: Date(), mayAlreadyExist: false, progress: ignoreProgress
            )
        }
        #expect(refused?.collidingItemID == existing)
        #expect(env.server.node("/a.txt")?.content == Data("server".utf8))
    }

    /// 无内容的重新导入：服务端有同名文件则返回它，没有则返回 nil（不得凭空新建空文件）。
    @Test func createFileWithoutContentsMayReturnNil() async throws {
        let env = try await EngineHarness.make()
        let missing = try await env.engine.createFile(
            name: "ghost.txt", parentID: env.rootID, contents: nil, mtime: Date(), mayAlreadyExist: true, progress: ignoreProgress
        )
        #expect(missing == nil)
        #expect(env.server.node("/ghost.txt") == nil)

        let existing = env.server.addFile("/real.txt", content: Data("data".utf8))
        let found = try await env.engine.createFile(
            name: "real.txt", parentID: env.rootID, contents: nil, mtime: Date(), mayAlreadyExist: true, progress: ignoreProgress
        )
        #expect(found?.id == existing)
        #expect(env.server.node("/real.txt")?.content == Data("data".utf8))
    }

    // MARK: - 名称冲突与规范化

    /// 本地镜像中已有大小写不同或 Unicode 规范等价的同名条目：新建、重命名、移动都报冲突并带上该条目。
    @Test func caseOrNormalizationVariantOfSiblingCollides() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/a.txt", id: "a")
        env.server.addFolder("/caf\u{E9}", id: "cafe")
        env.server.addFile("/other.txt", id: "o")
        env.server.addFolder("/dst", id: "dst")
        env.server.addFile("/dst/OTHER.TXT", id: "dO")
        try await env.enumerateAll(env.rootID)
        try await env.enumerateAll("dst")

        let create = await #expect(throws: SyncError.self) {
            try await env.engine.createFile(
                name: "A.TXT", parentID: env.rootID, contents: try EngineHarness.tempFile(Data("x".utf8)), mtime: Date(),
                mayAlreadyExist: false, progress: ignoreProgress
            )
        }
        #expect(create?.collidingItemID == "a")
        let folder = await #expect(throws: SyncError.self) {
            try await env.engine.createFolder(name: "CAFE\u{301}", parentID: env.rootID, mayAlreadyExist: false)
        }
        #expect(folder?.collidingItemID == "cafe")
        let rename = await #expect(throws: SyncError.self) { try await env.engine.rename(id: "o", newName: "A.txt") }
        #expect(rename?.collidingItemID == "a")
        let move = await #expect(throws: SyncError.self) { try await env.engine.move(id: "o", toParentID: "dst") }
        #expect(move?.collidingItemID == "dO")
        #expect(env.server.childNames("/") == ["a.txt", "caf\u{E9}", "dst", "other.txt"])

        // 只改大小写的自身重命名不算冲突
        let renamed = try await env.engine.rename(id: "a", newName: "A.txt")
        #expect(renamed.name == "A.txt")
    }

    /// 发往服务端的名称统一为 NFC；仅规范化形式不同的改名也要生效（不能用 String == 判断未改名）。
    @Test func namesAreSentAsNFCAndNormalizationOnlyRenameApplies() async throws {
        let env = try await EngineHarness.make()
        let created = try await env.engine.createFolder(name: "e\u{301}t\u{E9}", parentID: env.rootID, mayAlreadyExist: false)
        #expect(Array(created.name.unicodeScalars) == Array("\u{E9}t\u{E9}".unicodeScalars))
        #expect(env.server.node(id: created.id)?.name.unicodeScalars.elementsEqual("\u{E9}t\u{E9}".unicodeScalars) == true)

        env.server.addFile("/nfd-e\u{301}.txt", id: "nfd")
        try await env.enumerateAll(env.rootID)
        let renamed = try await env.engine.rename(id: "nfd", newName: "nfd-\u{E9}.txt")
        #expect(renamed.name.unicodeScalars.elementsEqual("nfd-\u{E9}.txt".unicodeScalars))
        #expect(env.server.node(id: "nfd")?.name.unicodeScalars.elementsEqual("nfd-\u{E9}.txt".unicodeScalars) == true)

        await env.mock.resetRequests()
        let result = try await env.engine.modify(
            id: "nfd", fields: [.filename], newName: "nfd-e\u{301}.txt", newParentID: nil, contents: nil, mtime: nil,
            baseContentVersion: nil, failOnConflict: true, progress: ignoreProgress
        )
        #expect(result.pendingFields.isEmpty)
        // NFC 化后与当前名称相同：不发重命名请求
        #expect(await env.mock.requests("POST", pathPrefix: "/api/v4/file/rename").isEmpty)
    }

    // MARK: - 删除

    @Test func deleteIsIdempotentWhenRemoteMissing() async throws {
        let env = try await EngineHarness.make()
        try env.items.upsert([DBFixtures.item("gone", path: "/gone.txt"), DBFixtures.item("gone2", path: "/gone2.txt")])
        let before = try env.latestSeq()
        try await env.engine.delete(id: "gone")
        #expect(try env.record("gone") == nil)
        env.server.failNext("DELETE", "/api/v4/file", code: 404)
        try await env.engine.delete(id: "gone2")
        #expect(try env.record("gone2") == nil)
        #expect(try env.logged(after: before) == [LoggedChange(id: "gone", kind: .delete), LoggedChange(id: "gone2", kind: .delete)])

        await env.mock.resetRequests()
        try await env.engine.delete(id: "gone")
        #expect(await env.mock.requests.isEmpty)
    }

    @Test func deleteFolderRemovesDescendantsLocally() async throws {
        let env = try await EngineHarness.make()
        env.server.addFolder("/a", id: "A")
        env.server.addFile("/a/x.txt", id: "X")
        env.server.addFolder("/a/sub", id: "S")
        env.server.addFile("/a/sub/y.txt", id: "Y")
        env.server.addFile("/keep.txt", id: "K")
        for folder in [env.rootID, "A", "S"] { try await env.enumerateAll(folder) }
        let before = try env.latestSeq()

        try await env.engine.delete(id: "A")
        let logged = try env.logged(after: before)
        #expect(Set(logged.map(\.id)) == ["A", "X", "S", "Y"])
        #expect(logged.allSatisfy { $0.kind == .delete })
        for id in ["A", "X", "S", "Y"] { #expect(try env.record(id) == nil) }
        #expect(try env.record("K") != nil)
        #expect(env.server.node("/a") == nil)
    }

    @Test func nonRecursiveDeleteRefusesFolderWithRemoteChildren() async throws {
        let env = try await EngineHarness.make()
        env.server.addFolder("/a", id: "A")
        env.server.addFolder("/empty", id: "E")
        try await env.enumerateAll(env.rootID)
        // 远端新增、本地尚未见过的子项：非递归删除必须拒绝，不得连带删除
        env.server.addFile("/a/new.txt", id: "N")
        await #expect(throws: SyncError.directoryNotEmpty) {
            try await env.engine.delete(id: "A", recursive: false)
        }
        #expect(env.server.node("/a") != nil)
        #expect(try env.record("A") != nil)

        try await env.engine.delete(id: "E", recursive: false)
        #expect(env.server.node("/empty") == nil)
        #expect(try env.record("E") == nil)
    }

    /// 系统给出删除基准版本：服务端内容已变（别处改过）时拒绝删除，并先把服务端最新条目写回镜像（产生 update）、
    /// 随错误带出；相同则删除。
    @Test func deleteWithStaleBaseVersionIsRejected() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/f.txt", content: Data("v1".utf8), id: "f")
        try await env.enumerateAll(env.rootID)
        let base = try #require(try env.record("f")).entityID
        let newer = env.server.replaceContent("/f.txt", with: Data("v2".utf8))
        let before = try env.latestSeq()

        let error = await #expect(throws: SyncError.self) {
            try await env.engine.delete(id: "f", recursive: true, baseContentVersion: base)
        }
        guard case .deletionRejected(let latest)? = error else {
            Issue.record("应为 deletionRejected，实际 \(String(describing: error))")
            return
        }
        #expect(latest?.id == "f")
        #expect(latest?.entityID == newer)
        #expect(env.server.node("/f.txt") != nil)
        #expect(try env.record("f")?.entityID == newer)
        #expect(try env.logged(after: before) == [LoggedChange(id: "f", kind: .update)])

        try await env.engine.delete(id: "f", recursive: true, baseContentVersion: newer)
        #expect(env.server.node("/f.txt") == nil)
        #expect(try env.record("f") == nil)
    }

    /// 镜像路径过期（远端已移动，原路径被另一个文件占用）：删除必须按 id 找到当前位置，不得误删占位文件。
    @Test func deleteResolvesCurrentServerPathByID() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/a.txt", id: "f")
        try await env.enumerateAll(env.rootID)
        env.server.addFolder("/sub", id: "sub")
        env.server.relocate("/a.txt", to: "/sub/a.txt")
        env.server.addFile("/a.txt", id: "other")

        try await env.engine.delete(id: "f", recursive: true, baseContentVersion: nil)
        #expect(env.server.node(id: "f") == nil)
        #expect(env.server.node(id: "other") != nil)
        #expect(try env.record("f") == nil)
    }

    @Test func renameAndMoveResolveCurrentServerPathByID() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/a.txt", id: "f")
        env.server.addFile("/m.txt", id: "m")
        env.server.addFolder("/dst", id: "dst")
        try await env.enumerateAll(env.rootID)
        env.server.relocate("/a.txt", to: "/b.txt")
        env.server.relocate("/m.txt", to: "/n.txt")

        let renamed = try await env.engine.rename(id: "f", newName: "c.txt")
        #expect(renamed.uri == .my("/c.txt"))
        #expect(env.server.node(id: "f")?.segments == ["c.txt"])
        #expect(try env.record("f")?.uri == .my("/c.txt"))

        let moved = try await env.engine.move(id: "m", toParentID: "dst")
        #expect(moved.uri == .my("/dst/n.txt"))
        #expect(moved.name == "n.txt")
        #expect(env.server.node(id: "m")?.segments == ["dst", "n.txt"])

        env.server.remove("/c.txt")
        await #expect(throws: SyncError.noSuchItem) { try await env.engine.rename(id: "f", newName: "d.txt") }
        #expect(try env.record("f") == nil)
    }

    /// 镜像名称已过期（远端先改名）时，冲突检查用服务端当前名称与当前父目录，而不是镜像里的旧值。
    @Test func moveAndRenameCheckCollisionsAtResolvedLocation() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/a.txt", id: "f")
        env.server.addFolder("/dst", id: "dst")
        env.server.addFile("/dst/B.TXT", id: "dB")
        env.server.addFolder("/src", id: "src")
        env.server.addFile("/src/g.txt", id: "g")
        env.server.addFile("/src/C.TXT", id: "sC")
        env.server.addFile("/dst/c.md", id: "dC")
        for folder in [env.rootID, "dst", "src"] { try await env.enumerateAll(folder) }

        // 镜像里是 a.txt，服务端已改名为 b.txt：移入 dst 会与 B.TXT 冲突
        env.server.relocate("/a.txt", to: "/b.txt")
        let move = await #expect(throws: SyncError.self) { try await env.engine.move(id: "f", toParentID: "dst") }
        #expect(move?.collidingItemID == "dB")
        #expect(env.server.node(id: "f")?.segments == ["b.txt"])

        // 镜像里 g 在 src（有 C.TXT），服务端已移到 dst（有 c.md）：改名 C.md 与 dst 的 c.md 冲突，与 src 的 C.TXT 无关
        env.server.relocate("/src/g.txt", to: "/dst/g.txt")
        let rename = await #expect(throws: SyncError.self) { try await env.engine.rename(id: "g", newName: "C.md") }
        #expect(rename?.collidingItemID == "dC")
        let renamed = try await env.engine.rename(id: "g", newName: "c.txt")
        #expect(renamed.uri == .my("/dst/c.txt"))
    }

    /// 仅 Unicode 规范化不同的目录改名（NFD → NFC）：镜像中的名称、目录 uri 与后代 uri 都按实际字节更新。
    @Test func normalizationOnlyFolderRenameMovesDescendants() async throws {
        let env = try await EngineHarness.make()
        env.server.addFolder("/e\u{301}", id: "E")
        env.server.addFile("/e\u{301}/x.txt", id: "X")
        try await env.enumerateAll(env.rootID)
        try await env.enumerateAll("E")
        let before = try env.latestSeq()

        _ = try await env.engine.rename(id: "E", newName: "\u{E9}")
        let nfc = CloudreveURI(segments: ["\u{E9}"])
        #expect(try env.record("E")?.name.unicodeScalars.elementsEqual("\u{E9}".unicodeScalars) == true)
        #expect(try env.record("E")?.uri.description == nfc.description)
        #expect(try env.record("X")?.uri.description == nfc.appending("x.txt").description)
        #expect(try env.logged(after: before) == [LoggedChange(id: "E", kind: .update)])
        // 之后按镜像 uri 列子目录访问的是新位置
        try await env.enumerateAll("E")
        #expect(try env.record("X") != nil)
    }

    // MARK: - 下载

    @Test func downloadWritesBytesAndRecordsTransfer() async throws {
        let env = try await EngineHarness.make()
        let content = Data("hello world".utf8)
        env.server.addFile("/f.bin", content: content, id: "f")
        try await env.enumerateAll(env.rootID)
        let destination = EngineHarness.tempURL()
        let progress = ProgressRecorder()
        let item = try await env.engine.download(id: "f", version: nil, to: destination, progress: progress.handler)
        #expect(item.id == "f")
        #expect(try Data(contentsOf: destination) == content)
        #expect(progress.last == 11)
        let transfer = try #require(try env.transfers.recent(driveID: env.driveID).first)
        #expect(transfer.kind == .download)
        #expect(transfer.state == .done)
        #expect(transfer.doneBytes == 11)
    }

    /// 请求指定版本：返回该版本内容，条目的内容版本与大小描述该版本（File Provider 要求与请求一致），镜像不变。
    @Test func downloadRequestedOldVersionReturnsThatVersion() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/f.bin", content: Data("v1".utf8), id: "f")
        try await env.enumerateAll(env.rootID)
        let old = try #require(try env.record("f")).entityID
        let newer = env.server.replaceContent("/f.bin", with: Data("version two".utf8))
        try await env.enumerateAll(env.rootID)

        let destination = EngineHarness.tempURL()
        let item = try await env.engine.download(id: "f", version: old, to: destination, progress: ignoreProgress)

        #expect(try Data(contentsOf: destination) == Data("v1".utf8))
        #expect(item.entityID == old)
        #expect(item.size == 2)
        #expect(try env.record("f")?.entityID == newer)
    }

    /// 文件被移到挂载根内一个镜像尚未见过的目录：下载时补查祖先目录并照常下载，不得当成已删除。
    @Test func downloadOfFileMovedIntoUnknownFolderRefreshesAncestors() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/f.bin", content: Data("hello".utf8), id: "f")
        try await env.enumerateAll(env.rootID)
        env.server.addFolder("/new", id: "N")
        env.server.addFolder("/new/deep", id: "ND")
        env.server.relocate("/f.bin", to: "/new/deep/f.bin")

        let destination = EngineHarness.tempURL()
        let item = try await env.engine.download(id: "f", version: nil, to: destination, progress: ignoreProgress)
        #expect(try Data(contentsOf: destination) == Data("hello".utf8))
        #expect(item.uri == .my("/new/deep/f.bin"))
        #expect(item.parentID == "ND")
        #expect(try env.record("ND")?.parentID == "N")
        #expect(try env.record("N")?.parentID == env.rootID)
        #expect(try env.logged().allSatisfy { $0.kind == .update })
    }

    /// 明确请求的版本即使等于镜像当前版本，取不到时也只能失败，不得悄悄返回另一个版本。
    @Test func downloadExplicitVersionNeverReturnsAnotherVersion() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/f.bin", content: Data("v1".utf8), id: "f")
        try await env.enumerateAll(env.rootID)
        let current = try #require(try env.record("f")).entityID
        env.server.replaceContent("/f.bin", with: Data("version two".utf8))
        env.server.failNext("POST", "/api/v4/file/url", code: 40044)

        let destination = EngineHarness.tempURL()
        await #expect(throws: SyncError.cannotSynchronize("请求的版本已不存在")) {
            try await env.engine.download(id: "f", version: current, to: destination, progress: ignoreProgress)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try env.record("f")?.entityID == current)
    }

    @Test func downloadLengthMismatchFailsAndRemovesFile() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/f.bin", content: Data("hello world".utf8), id: "f")
        try await env.enumerateAll(env.rootID)
        env.server.overrideNext("GET", ServerState.downloadPrefix, with: HTTPResponse(status: 200, body: Data("abc".utf8)))
        let destination = EngineHarness.tempURL()
        await #expect(throws: SyncError.cannotSynchronize("下载长度不符")) {
            try await env.engine.download(id: "f", version: nil, to: destination, progress: ignoreProgress)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try env.transfers.recent(driveID: env.driveID).first?.state == .failed)
    }

    /// 尚未交付给系统的临时文件在任何失败或取消时都要删除。
    @Test func downloadFailuresRemoveTemporaryFile() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/f.bin", content: Data("hello world".utf8), id: "f")
        try await env.enumerateAll(env.rootID)

        env.server.failNext("POST", "/api/v4/file/url", code: 50000)
        let urlFailure = EngineHarness.tempURL()
        await #expect(throws: SyncError.self) {
            try await env.engine.download(id: "f", version: nil, to: urlFailure, progress: ignoreProgress)
        }
        #expect(!FileManager.default.fileExists(atPath: urlFailure.path))

        env.server.overrideNext("GET", ServerState.downloadPrefix, with: HTTPResponse(status: 503, body: Data("busy".utf8)))
        let httpFailure = EngineHarness.tempURL()
        await #expect(throws: SyncError.serverUnreachable) {
            try await env.engine.download(id: "f", version: nil, to: httpFailure, progress: ignoreProgress)
        }
        #expect(!FileManager.default.fileExists(atPath: httpFailure.path))

        env.server.setLatency("GET \(ServerState.downloadPrefix)", .seconds(5))
        let cancelled = EngineHarness.tempURL()
        let task = Task { try await env.engine.download(id: "f", version: nil, to: cancelled, progress: ignoreProgress) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: cancelled.path))
    }

    /// 镜像中的当前版本已被服务端清理（40044）或文件已被移动：按 id 刷新后下载，不得报 noSuchItem（系统会删除本地条目）。
    @Test func downloadOfStaleCurrentVersionRefreshesByID() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/f.bin", content: Data("v1".utf8), id: "f")
        try await env.enumerateAll(env.rootID)
        let newer = env.server.replaceContent("/f.bin", with: Data("version two".utf8))
        env.server.failNext("POST", "/api/v4/file/url", code: 40044)

        let destination = EngineHarness.tempURL()
        let item = try await env.engine.download(id: "f", version: nil, to: destination, progress: ignoreProgress)
        #expect(try Data(contentsOf: destination) == Data("version two".utf8))
        #expect(item.entityID == newer)
        #expect(item.size == 11)
        #expect(try env.record("f")?.entityID == newer)

        env.server.relocate("/f.bin", to: "/g.bin")
        let moved = EngineHarness.tempURL()
        let movedItem = try await env.engine.download(id: "f", version: nil, to: moved, progress: ignoreProgress)
        #expect(try Data(contentsOf: moved) == Data("version two".utf8))
        #expect(movedItem.uri == .my("/g.bin"))
    }

    @Test func downloadOfRemotelyDeletedFileIsNoSuchItem() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/f.bin", id: "f")
        try await env.enumerateAll(env.rootID)
        env.server.remove("/f.bin")
        await #expect(throws: SyncError.noSuchItem) {
            try await env.engine.download(id: "f", version: nil, to: EngineHarness.tempURL(), progress: ignoreProgress)
        }
    }

    @Test func downloadUnavailableVersionFailsWithoutClaimingItemDeleted() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/f.bin", id: "f")
        try await env.enumerateAll(env.rootID)
        await #expect(throws: SyncError.cannotSynchronize("请求的版本已不存在")) {
            try await env.engine.download(id: "f", version: "gone-entity", to: EngineHarness.tempURL(), progress: ignoreProgress)
        }
        #expect(try env.record("f") != nil)
    }
}
