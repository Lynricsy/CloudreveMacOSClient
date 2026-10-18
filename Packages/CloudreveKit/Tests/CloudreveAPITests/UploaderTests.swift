import Foundation
import Testing
@testable import CloudreveAPI

@Suite struct UploaderTests {
    private typealias Fixture = UploaderFixtures

    @Test func localUploadsChunksInOrder() async throws {
        let mock = MockTransport()
        await Fixture.routeSession(mock, Fixture.session(type: "local", chunkSize: 4))
        await mock.route("POST", "/api/v4/file/upload/s1/") { _ in .envelope() }
        await Fixture.routeFileInfo(mock)
        let store = InMemoryUploadProgressStore()
        let progress = ProgressLog()
        let uploader = Uploader(client: Fixture.client(mock), store: store, sleep: { _ in })
        let file = try await Fixture.upload(uploader, data: Fixture.bytes(10), progress: progress)
        #expect(file == Fixture.file)
        let chunks = await mock.requests("POST", pathPrefix: "/api/v4/file/upload/s1/")
        #expect(chunks.map(\.url.path) == ["/api/v4/file/upload/s1/0", "/api/v4/file/upload/s1/1", "/api/v4/file/upload/s1/2"])
        #expect(chunks.map { $0.bodyData?.count } == [4, 4, 2])
        #expect(chunks.allSatisfy { $0.headers["Content-Type"] == "application/octet-stream" })
        // 分片内按已发送字节推进（mock 每个请求先回报一半），而不是只在分片完成时跳变
        #expect(progress.values == [0, 2, 4, 6, 8, 9, 10])
        #expect(try store.loadSession(uri: Fixture.uri.description) == nil)
    }

    @Test func localThreeChunksAndResume() async throws {
        let mock = MockTransport()
        await Fixture.routeSession(mock, Fixture.session(type: "local", chunkSize: 4))
        let chunkOneCalls = Counter()
        await mock.route("POST", "/api/v4/file/upload/s1/") { request in
            if request.url.lastPathComponent == "1", await chunkOneCalls.increment() <= 4 {
                return HTTPResponse(status: 500, body: Data("boom".utf8))
            }
            return .envelope()
        }
        await Fixture.routeFileInfo(mock)
        let store = InMemoryUploadProgressStore()
        let sleeps = SleepLog()
        let uploader = Uploader(client: Fixture.client(mock), store: store, sleep: { await sleeps.append($0) })
        let data = Fixture.bytes(10)

        await #expect(throws: CloudreveAPIError.http(status: 500, body: "boom")) {
            _ = try await Fixture.upload(uploader, data: data)
        }
        #expect(await sleeps.durations == [.seconds(1), .seconds(2), .seconds(4)])
        let kept = try #require(try store.loadSession(uri: Fixture.uri.description))
        #expect(kept.chunksDone.keys.sorted() == [0])
        #expect(await mock.requests("GET", pathPrefix: "/api/v4/file/info").isEmpty)

        await mock.resetRequests()
        let progress = ProgressLog()
        let file = try await Fixture.upload(uploader, data: data, progress: progress)
        #expect(file == Fixture.file)
        #expect(await mock.requests("PUT", pathPrefix: "/api/v4/file/upload").isEmpty)
        let chunks = await mock.requests("POST", pathPrefix: "/api/v4/file/upload/s1/")
        #expect(chunks.map(\.url.path) == ["/api/v4/file/upload/s1/1", "/api/v4/file/upload/s1/2"])
        #expect(chunks.map(\.bodyData) == [data.subdata(in: 4..<8), data.subdata(in: 8..<10)])
        #expect(await mock.requests("GET", pathPrefix: "/api/v4/file/info").count == 1)
        #expect(progress.values == [4, 6, 8, 9, 10])
        #expect(try store.loadSession(uri: Fixture.uri.description) == nil)
    }

    @Test func createOmitsEntityType() async throws {
        let mock = MockTransport()
        await Fixture.routeSession(mock, Fixture.session(type: "local", chunkSize: 0))
        await mock.route("POST", "/api/v4/file/upload/s1/") { _ in .envelope() }
        await Fixture.routeFileInfo(mock)
        let uploader = Uploader(client: Fixture.client(mock), store: InMemoryUploadProgressStore(), sleep: { _ in })

        _ = try await Fixture.upload(uploader, data: Fixture.bytes(3), overwrite: .create)
        _ = try await Fixture.upload(uploader, data: Fixture.bytes(3), overwrite: .version(previous: "e1"))
        let bodies = try await mock.requests("PUT", pathPrefix: "/api/v4/file/upload").map { request in
            try Fixture.json(request.bodyData)
        }
        try #require(bodies.count == 2)
        #expect(bodies[0]["entity_type"] == nil)
        #expect(bodies[0]["previous"] == nil)
        #expect(bodies[0]["size"] as? Int == 3)
        #expect(bodies[0]["last_modified"] as? Int == 1_700_000_000_000)
        #expect(bodies[1]["entity_type"] as? String == "version")
        #expect(bodies[1]["previous"] as? String == "e1")
    }

    @Test func zeroByteCreateUsesCreateItem() async throws {
        let mock = MockTransport()
        await mock.route("POST", "/api/v4/file/create") { _ in try .envelope(encoding: Fixture.file) }
        let uploader = Uploader(client: Fixture.client(mock), store: InMemoryUploadProgressStore(), sleep: { _ in })
        let file = try await Fixture.upload(uploader, data: Data(), overwrite: .create)
        #expect(file == Fixture.file)
        let request = try #require(await mock.requests.first)
        #expect(await mock.requests.count == 1)
        let body = try Fixture.json(request.bodyData)
        #expect(body["type"] as? String == "file")
        #expect(body["uri"] as? String == Fixture.uri.description)
    }

    @Test func zeroByteVersionUsesPutContent() async throws {
        let mock = MockTransport()
        await mock.route("PUT", "/api/v4/file/content") { _ in try .envelope(encoding: Fixture.file) }
        let uploader = Uploader(client: Fixture.client(mock), store: InMemoryUploadProgressStore(), sleep: { _ in })
        let file = try await Fixture.upload(uploader, data: Data(), overwrite: .version(previous: "e1"))
        #expect(file == Fixture.file)
        let request = try #require(await mock.requests.first)
        #expect(await mock.requests.count == 1)
        #expect(request.queryItems["previous"] == "e1")
        #expect(request.queryItems["uri"] == Fixture.uri.description)
        #expect(request.bodyData == Data())
    }

    @Test func encryptMetadataCancelsSession() async throws {
        let mock = MockTransport()
        var session = Fixture.session(type: "local", chunkSize: 4)
        session.encryptMetadata = EncryptMetadataMarker()
        await Fixture.routeSession(mock, session)
        await mock.route("DELETE", "/api/v4/file/upload") { _ in .envelope() }
        let store = InMemoryUploadProgressStore()
        let uploader = Uploader(client: Fixture.client(mock), store: store, sleep: { _ in })
        await #expect(throws: CloudreveAPIError.unsupportedEncryption) {
            _ = try await Fixture.upload(uploader, data: Fixture.bytes(10))
        }
        let deletes = await mock.requests("DELETE", pathPrefix: "/api/v4/file/upload")
        #expect(deletes.count == 1)
        let body = try Fixture.json(deletes.first?.bodyData)
        #expect(body["id"] as? String == Fixture.sessionID)
        #expect(await mock.requests("POST", pathPrefix: "/api/v4/file/upload/").isEmpty)
        #expect(try store.loadSession(uri: Fixture.uri.description) == nil)
    }

    @Test func expiredSessionIsReplaced() async throws {
        let mock = MockTransport()
        await Fixture.routeSession(mock, Fixture.session(type: "local", chunkSize: 4))
        await mock.route("DELETE", "/api/v4/file/upload") { _ in .envelope() }
        await mock.route("POST", "/api/v4/file/upload/") { _ in .envelope() }
        await Fixture.routeFileInfo(mock)
        let store = InMemoryUploadProgressStore()
        var stale = Fixture.session(type: "local", chunkSize: 4, expiresIn: 30)
        stale.sessionID = "old"
        // 除过期外其余条件均满足（覆盖方式一致、分片 0 摘要与本地内容一致）
        try store.saveSession(StoredUploadSession(
            uri: Fixture.uri.description, size: 10, policyType: "local", session: stale, overwrite: .create,
            chunksDone: [0: nil], chunkDigests: [0: Fixture.sha256(Fixture.bytes(4))], createdAt: Date()
        ))
        let uploader = Uploader(client: Fixture.client(mock), store: store, sleep: { _ in })
        _ = try await Fixture.upload(uploader, data: Fixture.bytes(10))
        let deletes = await mock.requests("DELETE", pathPrefix: "/api/v4/file/upload")
        let body = try Fixture.json(deletes.first?.bodyData)
        #expect(body["id"] as? String == "old")
        #expect(await mock.requests("PUT", pathPrefix: "/api/v4/file/upload").count == 1)
        #expect(await mock.requests("POST", pathPrefix: "/api/v4/file/upload/s1/").count == 3)
        #expect(await mock.requests("POST", pathPrefix: "/api/v4/file/upload/old/").isEmpty)
    }

    @Test func legacySessionWithoutDigestsIsReplaced() async throws {
        let mock = MockTransport()
        await Fixture.routeSession(mock, Fixture.session(type: "local", chunkSize: 4))
        await mock.route("DELETE", "/api/v4/file/upload") { _ in .envelope() }
        await mock.route("POST", "/api/v4/file/upload/") { _ in .envelope() }
        await Fixture.routeFileInfo(mock)
        let store = InMemoryUploadProgressStore()
        var old = Fixture.session(type: "local", chunkSize: 4)
        old.sessionID = "old"
        // 旧版本记录没有分片摘要与覆盖方式：无法证明已传分片与当前内容一致，不得复用
        try store.saveSession(StoredUploadSession(
            uri: Fixture.uri.description, size: 10, policyType: "local", session: old, chunksDone: [0: nil], createdAt: Date()
        ))
        let uploader = Uploader(client: Fixture.client(mock), store: store, sleep: { _ in })
        _ = try await Fixture.upload(uploader, data: Fixture.bytes(10))
        #expect(await mock.requests("PUT", pathPrefix: "/api/v4/file/upload").count == 1)
        #expect(await mock.requests("POST", pathPrefix: "/api/v4/file/upload/s1/").count == 3)
        #expect(await mock.requests("POST", pathPrefix: "/api/v4/file/upload/old/").isEmpty)
    }

    @Test func nonRetryableErrorDropsSession() async throws {
        let mock = MockTransport()
        await Fixture.routeSession(mock, Fixture.session(type: "local", chunkSize: 4))
        await mock.route("POST", "/api/v4/file/upload/s1/") { _ in .envelope(code: 40011, msg: "expired") }
        let store = InMemoryUploadProgressStore()
        let sleeps = SleepLog()
        let uploader = Uploader(client: Fixture.client(mock), store: store, sleep: { await sleeps.append($0) })
        await #expect(throws: CloudreveAPIError.server(code: 40011, message: "expired", correlationID: nil)) {
            _ = try await Fixture.upload(uploader, data: Fixture.bytes(10))
        }
        #expect(await sleeps.durations.isEmpty)
        #expect(await mock.requests("POST", pathPrefix: "/api/v4/file/upload/s1/").count == 1)
        #expect(try store.loadSession(uri: Fixture.uri.description) == nil)
    }

    @Test func concurrentChunksAllUploaded() async throws {
        let mock = MockTransport()
        await Fixture.routeSession(mock, Fixture.session(type: "local", chunkSize: 3, concurrency: 3))
        await mock.route("POST", "/api/v4/file/upload/s1/") { _ in .envelope() }
        await Fixture.routeFileInfo(mock)
        let store = InMemoryUploadProgressStore()
        let progress = ProgressLog()
        let uploader = Uploader(client: Fixture.client(mock), store: store, sleep: { _ in })
        let data = Fixture.bytes(10)
        _ = try await Fixture.upload(uploader, data: data, progress: progress)
        let chunks = await mock.requests("POST", pathPrefix: "/api/v4/file/upload/s1/")
        let byIndex = Dictionary(uniqueKeysWithValues: chunks.map { ($0.url.lastPathComponent, $0.bodyData) })
        #expect(byIndex == ["0": data.subdata(in: 0..<3), "1": data.subdata(in: 3..<6),
                            "2": data.subdata(in: 6..<9), "3": data.subdata(in: 9..<10)])
        #expect(progress.values.last == 10)
    }
}
