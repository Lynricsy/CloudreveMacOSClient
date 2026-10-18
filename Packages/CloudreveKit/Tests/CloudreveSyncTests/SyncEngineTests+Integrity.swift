import CloudreveAPI
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Testing
@testable import CloudreveSync

// 按服务端公布的实体 SHA-256（OpenCloudreve）校验内容。
extension SyncEngineTests {
    private static let digestMismatch = SyncError.integrityCheckFailed("下载内容与服务端 SHA-256 不符")

    /// 服务端公布了 SHA-256（OpenCloudreve）：长度相同但内容不符时下载失败并删除临时文件；相符时正常交付。
    @Test func downloadVerifiesPublishedSHA256() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/f.bin", content: Data("hello world".utf8), id: "f")
        try await env.enumerateAll(env.rootID)
        env.server.publishHash(entity: try #require(try env.record("f")).entityID)

        env.server.overrideNext("GET", ServerState.downloadPrefix, with: HTTPResponse(status: 200, body: Data("hello WORLD".utf8)))
        let corrupted = EngineHarness.tempURL()
        await #expect(throws: Self.digestMismatch) {
            try await env.engine.download(id: "f", version: nil, to: corrupted, progress: ignoreProgress)
        }
        #expect(!FileManager.default.fileExists(atPath: corrupted.path))
        #expect(try env.transfers.recent(driveID: env.driveID).first?.state == .failed)

        let destination = EngineHarness.tempURL()
        _ = try await env.engine.download(id: "f", version: nil, to: destination, progress: ignoreProgress)
        #expect(try Data(contentsOf: destination) == Data("hello world".utf8))
    }

    /// 服务端给出的摘要按规范化后使用：大写照常校验，格式无效视为未公布（只校验长度），都不得拒绝正确内容。
    @Test func downloadNormalizesPublishedDigest() async throws {
        let env = try await EngineHarness.make()
        let content = Data("hello world".utf8)
        env.server.addFile("/f.bin", content: content, id: "f")
        try await env.enumerateAll(env.rootID)
        let entity = try #require(try env.record("f")).entityID
        let upper = ContentDigest.hex(SHA256.hash(data: content)).uppercased()

        env.server.publishHash(entity: entity, sha256: upper)
        let accepted = EngineHarness.tempURL()
        _ = try await env.engine.download(id: "f", version: nil, to: accepted, progress: ignoreProgress)
        #expect(try Data(contentsOf: accepted) == content)
        env.server.overrideNext("GET", ServerState.downloadPrefix, with: HTTPResponse(status: 200, body: Data("hello WORLD".utf8)))
        await #expect(throws: Self.digestMismatch) {
            try await env.engine.download(id: "f", version: nil, to: EngineHarness.tempURL(), progress: ignoreProgress)
        }

        env.server.publishHash(entity: entity, sha256: "not-a-digest")
        let lengthOnly = EngineHarness.tempURL()
        _ = try await env.engine.download(id: "f", version: nil, to: lengthOnly, progress: ignoreProgress)
        #expect(try Data(contentsOf: lengthOnly) == content)
    }

    /// 实体信息查询暂时失败（5xx 等）不得拖垮本可完成的下载：退回只校验长度。
    @Test func downloadFallsBackToLengthCheckWhenEntityInfoUnavailable() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/f.bin", content: Data("hello world".utf8), id: "f")
        try await env.enumerateAll(env.rootID)
        env.server.publishHash(entity: try #require(try env.record("f")).entityID)

        env.server.overrideNext("GET", "/api/v4/file/info", with: HTTPResponse(status: 503, body: Data("busy".utf8)))
        let destination = EngineHarness.tempURL()
        _ = try await env.engine.download(id: "f", version: nil, to: destination, progress: ignoreProgress)
        #expect(try Data(contentsOf: destination) == Data("hello world".utf8))
    }

    /// 实体信息查询很慢：与取下载地址并发，但拿到期望摘要后才开始请求正文。
    /// 传输层的分块流不限缓冲，提前开始会让正文在查询期间全部堆在内存里。
    ///
    /// 正确实现在闸门打开前不可能请求正文，因此本用例不会误报；反过来，回退修复后能否被发现取决于下载任务
    /// 在观察窗口内是否被调度到（无法证明「不会发生」），窗口只降低漏报概率。
    @Test func downloadStartsBodyOnlyAfterEntityInfoArrives() async throws {
        let env = try await EngineHarness.make()
        env.server.addFile("/f.bin", content: Data("hello world".utf8), id: "f")
        try await env.enumerateAll(env.rootID)
        env.server.publishHash(entity: try #require(try env.record("f")).entityID)
        let gate = env.server.hold("GET /api/v4/file/info")
        defer { gate.open() }

        let destination = EngineHarness.tempURL()
        let task = Task { try await env.engine.download(id: "f", version: nil, to: destination, progress: ignoreProgress) }
        defer { task.cancel() }
        // 两个检查点：实体信息请求已到达并被挂起（与取地址并发），下载地址已取得
        try await env.server.waitUntilRequested("GET", "/api/v4/file/info")
        try await env.server.waitUntilCompleted("POST /api/v4/file/url")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await env.mock.requests("GET", pathPrefix: ServerState.downloadPrefix).isEmpty)

        gate.open()
        _ = try await task.value
        #expect(try Data(contentsOf: destination) == Data("hello world".utf8))
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
        await #expect(throws: Self.digestMismatch) {
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
