import CloudreveAPI
import Foundation
import Testing
@testable import CloudreveSync

// 按服务端公布的实体 SHA-256（OpenCloudreve）校验内容。
extension SyncEngineTests {
    /// 服务端公布了 SHA-256（OpenCloudreve）：长度相同但内容不符时下载失败并删除临时文件；相符时正常交付。
    @Test func downloadVerifiesPublishedSHA256() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/f.bin", content: Data("hello world".utf8), id: "f")
        try await env.enumerateAll(env.rootID)
        env.server.publishHash(entity: try #require(try env.record("f")).entityID)

        env.server.overrideNext("GET", ServerState.downloadPrefix, with: HTTPResponse(status: 200, body: Data("hello WORLD".utf8)))
        let corrupted = EngineHarness.tempURL()
        await #expect(throws: SyncError.cannotSynchronize("下载内容与服务端 SHA-256 不符")) {
            try await env.engine.download(id: "f", version: nil, to: corrupted, progress: ignoreProgress)
        }
        #expect(!FileManager.default.fileExists(atPath: corrupted.path))
        #expect(try env.transfers.recent(driveID: env.driveID).first?.state == .failed)

        let destination = EngineHarness.tempURL()
        _ = try await env.engine.download(id: "f", version: nil, to: destination, progress: ignoreProgress)
        #expect(try Data(contentsOf: destination) == Data("hello world".utf8))
    }

    /// 实体信息查询很慢、正文很快：必须等拿到期望摘要后才开始下载正文。
    /// 传输层的分块流不限缓冲，提前开始会让正文在查询期间全部堆在内存里。
    @Test func downloadStartsBodyOnlyAfterEntityInfoArrives() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/f.bin", content: Data("hello world".utf8), id: "f")
        try await env.enumerateAll(env.rootID)
        env.server.publishHash(entity: try #require(try env.record("f")).entityID)
        env.server.setLatency("GET /api/v4/file/info", .milliseconds(300))

        let destination = EngineHarness.tempURL()
        _ = try await env.engine.download(id: "f", version: nil, to: destination, progress: ignoreProgress)
        #expect(try Data(contentsOf: destination) == Data("hello world".utf8))
        let order = env.server.completedEndpoints().filter { $0.contains("file/info") || $0.contains("file/url") || $0.contains("/dl/") }
        #expect(order == ["POST /api/v4/file/url", "GET /api/v4/file/info", "GET \(ServerState.downloadPrefix)"])
    }

    /// 历史版本：镜像只知道当前版本的大小，按服务端记录的该实体大小与 SHA-256 校验。
    @Test func downloadOldVersionVerifiedByServerEntityInfo() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/f.bin", content: Data("v1".utf8), id: "f")
        try await env.enumerateAll(env.rootID)
        let old = try #require(try env.record("f")).entityID
        env.server.replaceContent("/f.bin", with: Data("version two".utf8))
        try await env.enumerateAll(env.rootID)

        env.server.overrideNext("GET", ServerState.downloadPrefix, with: HTTPResponse(status: 200, body: Data("v".utf8)))
        await #expect(throws: SyncError.cannotSynchronize("下载长度不符")) {
            try await env.engine.download(id: "f", version: old, to: EngineHarness.tempURL(), progress: ignoreProgress)
        }

        env.server.publishHash(entity: old)
        env.server.overrideNext("GET", ServerState.downloadPrefix, with: HTTPResponse(status: 200, body: Data("v2".utf8)))
        await #expect(throws: SyncError.cannotSynchronize("下载内容与服务端 SHA-256 不符")) {
            try await env.engine.download(id: "f", version: old, to: EngineHarness.tempURL(), progress: ignoreProgress)
        }
    }

    /// 重新导入命中大小相同的同名文件且服务端公布了 SHA-256：只比对摘要，不下载服务端内容。
    @Test func createFileAdoptionComparesPublishedSHA256() async throws {
        let env = try await EngineHarness.make()
        let existing = env.server.addFile("/a.txt", content: Data("server".utf8))
        env.server.publishHash(entity: try #require(env.server.node(id: existing)).entityID)
        await env.mock.resetRequests()

        let differs = await #expect(throws: SyncError.self) {
            try await env.engine.createFile(
                name: "a.txt", parentID: env.rootID, contents: try EngineHarness.tempFile(Data("local!".utf8)), mtime: Date(),
                mayAlreadyExist: true, progress: ignoreProgress
            )
        }
        #expect(differs?.collidingItemID == existing)

        let item = try await env.engine.createFile(
            name: "a.txt", parentID: env.rootID, contents: try EngineHarness.tempFile(Data("server".utf8)), mtime: Date(),
            mayAlreadyExist: true, progress: ignoreProgress
        )
        #expect(item?.id == existing)
        #expect(await env.mock.requests("POST", pathPrefix: "/api/v4/file/url").isEmpty)
        #expect(env.server.node("/a.txt")?.content == Data("server".utf8))
    }
}
