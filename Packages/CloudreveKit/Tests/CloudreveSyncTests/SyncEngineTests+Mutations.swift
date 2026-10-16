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
        let item = try await env.engine.createFolder(name: "docs", parentID: env.rootID, mayAlreadyExist: true)
        #expect(item.id == existing)
        #expect(try env.record(existing)?.uri == .my("/docs"))
        await #expect(throws: SyncError.filenameCollision) {
            try await env.engine.createFolder(name: "docs", parentID: env.rootID, mayAlreadyExist: false)
        }
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
        let item = try await env.engine.createFile(
            name: "报告 1.txt", parentID: "docs", contents: try EngineHarness.tempFile(content), mtime: Date(),
            mayAlreadyExist: false, progress: progress.handler
        )
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
        let item = try await env.engine.createFile(
            name: "empty.txt", parentID: env.rootID, contents: nil, mtime: Date(), mayAlreadyExist: false, progress: ignoreProgress
        )
        #expect(env.server.node("/empty.txt")?.content == Data())
        #expect(item.size == 0)
        #expect(await env.mock.requests("PUT", pathPrefix: "/api/v4/file/upload").isEmpty)
    }

    @Test func createFileConflictBranches() async throws {
        let env = try await EngineHarness.make()
        let existing = env.server.addFile("/a.txt", content: Data("server".utf8))
        let url = try EngineHarness.tempFile(Data("local".utf8))
        let item = try await env.engine.createFile(
            name: "a.txt", parentID: env.rootID, contents: url, mtime: Date(), mayAlreadyExist: true, progress: ignoreProgress
        )
        #expect(item.id == existing)
        #expect(env.server.node("/a.txt")?.content == Data("server".utf8))
        await #expect(throws: SyncError.filenameCollision) {
            try await env.engine.createFile(
                name: "a.txt", parentID: env.rootID, contents: url, mtime: Date(), mayAlreadyExist: false, progress: ignoreProgress
            )
        }
        let states = try env.transfers.recent(driveID: env.driveID).map(\.state)
        #expect(states.sorted { $0.rawValue < $1.rawValue } == [.done, .failed])
    }

    // MARK: - 删除

    @Test func deleteIsIdempotentWhenRemoteMissing() async throws {
        let env = try await EngineHarness.make()
        try env.items.upsert([DBFixtures.item("gone", path: "/gone.txt"), DBFixtures.item("gone2", path: "/gone2.txt")])
        try await env.engine.delete(id: "gone")
        #expect(try env.record("gone") == nil)
        env.server.failNext("DELETE", "/api/v4/file", code: 404)
        try await env.engine.delete(id: "gone2")
        #expect(try env.record("gone2") == nil)
        #expect(try env.logged() == [LoggedChange(id: "gone", kind: .delete), LoggedChange(id: "gone2", kind: .delete)])

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

    @Test func downloadSpecificVersionSkipsLengthCheck() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/f.bin", content: Data("v1".utf8), id: "f")
        try await env.enumerateAll(env.rootID)
        let newer = env.server.replaceContent("/f.bin", with: Data("version two".utf8))
        let destination = EngineHarness.tempURL()
        _ = try await env.engine.download(id: "f", version: newer, to: destination, progress: ignoreProgress)
        #expect(try Data(contentsOf: destination) == Data("version two".utf8))
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

    @Test func downloadOfRemotelyDeletedFileIsNoSuchItem() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/f.bin", id: "f")
        try await env.enumerateAll(env.rootID)
        env.server.remove("/f.bin")
        await #expect(throws: SyncError.noSuchItem) {
            try await env.engine.download(id: "f", version: nil, to: EngineHarness.tempURL(), progress: ignoreProgress)
        }
    }
}
