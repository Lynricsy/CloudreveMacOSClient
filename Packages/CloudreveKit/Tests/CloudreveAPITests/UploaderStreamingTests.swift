import Foundation
import Testing
@testable import CloudreveAPI

/// 上传请求体从磁盘文件发送，内存占用与文件/分片大小无关。
///
/// 无法直接测量进程内存；以可观察行为断言：发往传输层的请求体是 `.file`（由 URLSession 从磁盘流式读取），
/// 而不是整块读入内存的 `.data`。
@Suite struct UploaderStreamingTests {
    private typealias Fixture = UploaderFixtures

    /// 路由处理器收到的是原始请求（MockTransport 只在记录里把文件请求体转为快照）。
    private static func fileBody(_ request: HTTPRequest) -> Data? {
        guard case .file(let url) = request.body else { return nil }
        return try? Data(contentsOf: url)
    }

    @Test(arguments: [Int64(0), 4])
    func chunksAreSentFromDisk(chunkSize: Int64) async throws {
        let mock = MockTransport()
        await Fixture.routeSession(mock, Fixture.session(type: "local", chunkSize: chunkSize))
        let bodies = Recorder<Data?>()
        await mock.route("POST", "/api/v4/file/upload/s1/") { request in
            bodies.append(Self.fileBody(request))
            return .envelope()
        }
        await Fixture.routeFileInfo(mock)
        let progress = ProgressLog()
        let uploader = Uploader(client: Fixture.client(mock), store: InMemoryUploadProgressStore(), sleep: { _ in })
        let data = Fixture.bytes(10)
        _ = try await Fixture.upload(uploader, data: data, progress: progress)
        let expected = chunkSize == 0
            ? [data]
            : [data.subdata(in: 0..<4), data.subdata(in: 4..<8), data.subdata(in: 8..<10)]
        #expect(bodies.values == expected)
        // 进度仍按已发送字节推进
        #expect(progress.values == (chunkSize == 0 ? [0, 5, 10] : [0, 2, 4, 6, 8, 9, 10]))
    }

    @Test func upyunMultipartIsSentFromDisk() async throws {
        let mock = MockTransport()
        let uploadURL = "https://v0.api.upyun.com/bucket"
        await Fixture.routeSession(mock, Fixture.session(type: "upyun", chunkSize: 0, uploadURLs: [uploadURL], credential: "c"))
        let bodies = Recorder<Data?>()
        await mock.route("POST", uploadURL) { request in
            bodies.append(Self.fileBody(request))
            return HTTPResponse(status: 200)
        }
        await Fixture.routeFileInfo(mock)
        let progress = ProgressLog()
        let uploader = Uploader(client: Fixture.client(mock), store: InMemoryUploadProgressStore(), sleep: { _ in })
        _ = try await Fixture.upload(uploader, data: Data("hello".utf8), progress: progress)
        let body = try #require(bodies.values.first ?? nil)
        #expect(String(decoding: body, as: UTF8.self).contains("\r\n\r\nhello\r\n--"))
        #expect(progress.values.last == 5)
    }

    /// 暂存文件在分片完成与失败后都会删除；记录的摘要是实际上传内容的 SHA-256。
    @Test func stagedChunksAreRemovedAndDigestsRecorded() async throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let mock = MockTransport()
        await Fixture.routeSession(mock, Fixture.session(type: "local", chunkSize: 4))
        await mock.route("POST", "/api/v4/file/upload/s1/") { request in
            request.url.lastPathComponent == "2" ? HTTPResponse(status: 500, body: Data("boom".utf8)) : .envelope()
        }
        let store = InMemoryUploadProgressStore()
        let uploader = Uploader(client: Fixture.client(mock), store: store, stagingDirectory: staging, sleep: { _ in })
        let data = Fixture.bytes(10)
        await #expect(throws: CloudreveAPIError.http(status: 500, body: "boom")) {
            _ = try await Fixture.upload(uploader, data: data)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        let kept = try #require(try store.loadSession(uri: Fixture.uri.description))
        #expect(kept.chunkDigests == [0: Fixture.sha256(data.subdata(in: 0..<4)), 1: Fixture.sha256(data.subdata(in: 4..<8))])
        #expect(kept.overwrite == .create)
    }
}
