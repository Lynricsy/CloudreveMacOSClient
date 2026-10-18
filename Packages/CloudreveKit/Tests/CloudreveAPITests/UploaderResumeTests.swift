import Foundation
import Testing
@testable import CloudreveAPI

/// 断点续传：会话复用校验与完成阶段恢复。
@Suite struct UploaderResumeTests {
    private typealias Fixture = UploaderFixtures
    private static let completeURL = "https://s3.example.com/bucket/obj?uploadId=u1"
    private static let partURLs = (1...3).map { "https://s3.example.com/bucket/obj?partNumber=\($0)&uploadId=u1" }

    private static func localSession(_ id: String) -> UploadSession {
        var session = Fixture.session(type: "local", chunkSize: 4)
        session.sessionID = id
        return session
    }

    /// 首个会话 `s1` 的分片 1 始终失败（可重试错误耗尽后保留会话），第二个会话 `s2` 正常。
    private func interruptedLocalServer() async -> MockTransport {
        let mock = MockTransport()
        await Fixture.routeSessions(mock, ids: ["s1", "s2"], make: Self.localSession)
        await mock.route("POST", "/api/v4/file/upload/s1/") { request in
            request.url.lastPathComponent == "1" ? HTTPResponse(status: 500, body: Data("boom".utf8)) : .envelope()
        }
        await mock.route("POST", "/api/v4/file/upload/s2/") { _ in .envelope() }
        await mock.route("DELETE", "/api/v4/file/upload") { _ in .envelope() }
        await Fixture.routeFileInfo(mock)
        return mock
    }

    private func interrupt(_ uploader: Uploader, data: Data, overwrite: OverwriteMode = .create) async {
        await #expect(throws: CloudreveAPIError.http(status: 500, body: "boom")) {
            _ = try await Fixture.upload(uploader, data: data, overwrite: overwrite)
        }
    }

    @Test func sameSizeDifferentContentWithEarlierMTimeIsNotReused() async throws {
        let mock = await interruptedLocalServer()
        let store = InMemoryUploadProgressStore()
        let uploader = Uploader(client: Fixture.client(mock), store: store, sleep: { _ in })
        let original = Fixture.bytes(10)
        await interrupt(uploader, data: original)
        #expect(try store.loadSession(uri: Fixture.uri.description)?.chunksDone.keys.sorted() == [0])

        await mock.resetRequests()
        var changed = original
        changed[1] = 0xFF
        // 修改时间早于会话创建（例如从备份恢复）：只凭时间无法发现分片 0 已是旧内容
        _ = try await Fixture.upload(uploader, data: changed, lastModified: Date(timeIntervalSince1970: 1_000_000_000))
        let deletes = await mock.requests("DELETE", pathPrefix: "/api/v4/file/upload")
        #expect(try Fixture.json(deletes.first?.bodyData)["id"] as? String == "s1")
        #expect(await mock.requests("PUT", pathPrefix: "/api/v4/file/upload").count == 1)
        let chunks = await mock.requests("POST", pathPrefix: "/api/v4/file/upload/s2/")
        #expect(chunks.map(\.bodyData) == [changed.subdata(in: 0..<4), changed.subdata(in: 4..<8), changed.subdata(in: 8..<10)])
        #expect(await mock.requests("POST", pathPrefix: "/api/v4/file/upload/s1/").isEmpty)
        #expect(try store.loadSession(uri: Fixture.uri.description) == nil)
    }

    @Test func differentPreviousIsNotReused() async throws {
        let mock = await interruptedLocalServer()
        let store = InMemoryUploadProgressStore()
        let uploader = Uploader(client: Fixture.client(mock), store: store, sleep: { _ in })
        let data = Fixture.bytes(10)
        await interrupt(uploader, data: data, overwrite: .version(previous: "e1"))

        await mock.resetRequests()
        _ = try await Fixture.upload(uploader, data: data, overwrite: .version(previous: "e2"))
        let created = try #require(await mock.requests("PUT", pathPrefix: "/api/v4/file/upload").first)
        #expect(try Fixture.json(created.bodyData)["previous"] as? String == "e2")
        #expect(await mock.requests("POST", pathPrefix: "/api/v4/file/upload/s2/").count == 3)
        #expect(await mock.requests("POST", pathPrefix: "/api/v4/file/upload/s1/").isEmpty)
    }

    @Test func createAfterVersionIsNotReused() async throws {
        let mock = await interruptedLocalServer()
        let uploader = Uploader(client: Fixture.client(mock), store: InMemoryUploadProgressStore(), sleep: { _ in })
        let data = Fixture.bytes(10)
        await interrupt(uploader, data: data, overwrite: .version(previous: "e1"))

        await mock.resetRequests()
        _ = try await Fixture.upload(uploader, data: data, overwrite: .create)
        #expect(await mock.requests("PUT", pathPrefix: "/api/v4/file/upload").count == 1)
        #expect(await mock.requests("POST", pathPrefix: "/api/v4/file/upload/s1/").isEmpty)
    }

    @Test func sameContentIsReusedEvenIfTouched() async throws {
        let mock = await interruptedLocalServer()
        let store = InMemoryUploadProgressStore()
        let uploader = Uploader(client: Fixture.client(mock), store: store, sleep: { _ in })
        let data = Fixture.bytes(10)
        await interrupt(uploader, data: data, overwrite: .version(previous: "e1"))
        // 前缀更长的路由优先：分片 1 恢复正常
        await mock.route("POST", "/api/v4/file/upload/s1/1") { _ in .envelope() }

        await mock.resetRequests()
        // 内容未变、仅修改时间更新：已完成分片的摘要一致，可安全复用
        _ = try await Fixture.upload(
            uploader, data: data, overwrite: .version(previous: "e1"), lastModified: Date().addingTimeInterval(3600)
        )
        #expect(await mock.requests("PUT", pathPrefix: "/api/v4/file/upload").isEmpty)
        #expect(await mock.requests("DELETE", pathPrefix: "/api/v4/file/upload").isEmpty)
        let chunks = await mock.requests("POST", pathPrefix: "/api/v4/file/upload/s1/")
        #expect(chunks.map(\.url.lastPathComponent) == ["1", "2"])
    }

    // MARK: - 完成阶段

    private func routeS3(_ mock: MockTransport) async {
        await Fixture.routeSession(mock, Fixture.session(
            type: "s3", chunkSize: 4, uploadURLs: Self.partURLs, completeURL: Self.completeURL
        ))
        await mock.route("PUT", "https://s3.example.com/bucket/obj?partNumber=") { request in
            HTTPResponse(status: 200, headers: ["ETag": "\"e\(request.queryItems["partNumber"] ?? "")\""])
        }
        await mock.route("DELETE", "/api/v4/file/upload") { _ in .envelope() }
        await Fixture.routeFileInfo(mock)
    }

    @Test func callbackFailureAfterMergeRetriesOnlyCallback() async throws {
        let mock = MockTransport()
        await routeS3(mock)
        await mock.route("POST", Self.completeURL) { _ in HTTPResponse(status: 200, body: Data("<CompleteMultipartUploadResult/>".utf8)) }
        let callbacks = Counter()
        await mock.route("GET", "/api/v4/callback/s3/s1/secret") { _ in
            if await callbacks.increment() == 1 { throw CloudreveAPIError.transport("lost") }
            return .envelope()
        }
        let store = InMemoryUploadProgressStore()
        let uploader = Uploader(client: Fixture.client(mock), store: store, sleep: { _ in })
        let data = Fixture.bytes(10)
        await #expect(throws: CloudreveAPIError.transport("lost")) {
            _ = try await Fixture.upload(uploader, data: data)
        }
        #expect(try store.loadSession(uri: Fixture.uri.description) != nil)

        let file = try await Fixture.upload(uploader, data: data)
        #expect(file == Fixture.file)
        #expect(await mock.requests("PUT", pathPrefix: "https://s3.example.com/").count == 3)
        #expect(await mock.requests("POST", pathPrefix: Self.completeURL).count == 1)
        #expect(await callbacks.current == 2)
        #expect(await mock.requests("PUT", pathPrefix: "/api/v4/file/upload").count == 1)
        #expect(try store.loadSession(uri: Fixture.uri.description) == nil)
    }

    @Test func lostMergeResponseIsConfirmedByCallback() async throws {
        let mock = MockTransport()
        await routeS3(mock)
        let merges = Counter()
        await mock.route("POST", Self.completeURL) { _ in
            // 第一次合并已在存储侧生效但响应丢失；重发时上传 ID 已被消耗
            if await merges.increment() == 1 { throw CloudreveAPIError.transport("reset") }
            let xml = "<Error><Code>NoSuchUpload</Code><Message>The specified upload does not exist.</Message></Error>"
            return HTTPResponse(status: 404, body: Data(xml.utf8))
        }
        await mock.route("GET", "/api/v4/callback/s3/s1/secret") { _ in .envelope() }
        let store = InMemoryUploadProgressStore()
        let uploader = Uploader(client: Fixture.client(mock), store: store, sleep: { _ in })
        let data = Fixture.bytes(10)
        await #expect(throws: CloudreveAPIError.transport("reset")) {
            _ = try await Fixture.upload(uploader, data: data)
        }
        let file = try await Fixture.upload(uploader, data: data)
        #expect(file == Fixture.file)
        #expect(await merges.current == 2)
        #expect(await mock.requests("GET", pathPrefix: "/api/v4/callback/s3/s1/secret").count == 1)
        #expect(try store.loadSession(uri: Fixture.uri.description) == nil)
    }

    @Test func noSuchUploadWithoutPriorMergeAttemptFails() async throws {
        let mock = MockTransport()
        await routeS3(mock)
        let xml = "<Error><Code>NoSuchUpload</Code></Error>"
        await mock.route("POST", Self.completeURL) { _ in HTTPResponse(status: 404, body: Data(xml.utf8)) }
        await mock.route("GET", "/api/v4/callback/s3/s1/secret") { _ in .envelope() }
        let uploader = Uploader(client: Fixture.client(mock), store: InMemoryUploadProgressStore(), sleep: { _ in })
        await #expect(throws: CloudreveAPIError.http(status: 404, body: xml)) {
            _ = try await Fixture.upload(uploader, data: Fixture.bytes(10))
        }
        #expect(await mock.requests("GET", pathPrefix: "/api/v4/callback/").isEmpty)
    }

    @Test func s3MergeErrorInsideHTTP200IsNotSuccess() async throws {
        let mock = MockTransport()
        await routeS3(mock)
        let xml = #"<?xml version="1.0" encoding="UTF-8"?>"#
            + "\n<Error><Code>InternalError</Code><Message>We encountered an internal error. Please try again.</Message></Error>"
        await mock.route("POST", Self.completeURL) { _ in HTTPResponse(status: 200, body: Data(xml.utf8)) }
        await mock.route("GET", "/api/v4/callback/s3/s1/secret") { _ in .envelope() }
        let store = InMemoryUploadProgressStore()
        let uploader = Uploader(client: Fixture.client(mock), store: store, sleep: { _ in })
        await #expect(throws: CloudreveAPIError.http(status: 500, body: xml)) {
            _ = try await Fixture.upload(uploader, data: Fixture.bytes(10))
        }
        #expect(await mock.requests("GET", pathPrefix: "/api/v4/callback/").isEmpty)
        // 内嵌 InternalError 可重试：保留会话以便续传
        #expect(try store.loadSession(uri: Fixture.uri.description) != nil)
    }

    @Test func s3MergePermanentErrorInsideHTTP200DropsSession() async throws {
        let mock = MockTransport()
        await routeS3(mock)
        let xml = "<Error><Code>InvalidPart</Code><Message>One or more of the specified parts could not be found.</Message></Error>"
        await mock.route("POST", Self.completeURL) { _ in HTTPResponse(status: 200, body: Data(xml.utf8)) }
        let store = InMemoryUploadProgressStore()
        let uploader = Uploader(client: Fixture.client(mock), store: store, sleep: { _ in })
        await #expect(throws: CloudreveAPIError.http(status: 400, body: xml)) {
            _ = try await Fixture.upload(uploader, data: Fixture.bytes(10))
        }
        #expect(try store.loadSession(uri: Fixture.uri.description) == nil)
    }
}
