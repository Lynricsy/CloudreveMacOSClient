import Foundation
import Testing
@testable import CloudreveAPI

@Suite struct StrategyTests {
    private typealias Fixture = UploaderFixtures
    private static let completeURL = "https://s3.example.com/bucket/obj?uploadId=u1"
    private static let partURLs = (1...3).map { "https://s3.example.com/bucket/obj?partNumber=\($0)&uploadId=u1" }
    private static let threePartXML = "<CompleteMultipartUpload>"
        + "<Part><PartNumber>1</PartNumber><ETag>e1</ETag></Part>"
        + "<Part><PartNumber>2</PartNumber><ETag>e2</ETag></Part>"
        + "<Part><PartNumber>3</PartNumber><ETag>e3</ETag></Part>"
        + "</CompleteMultipartUpload>"

    private func uploadTenBytes(_ mock: MockTransport) async throws -> FileResponse {
        let uploader = Uploader(client: Fixture.client(mock), store: InMemoryUploadProgressStore(), sleep: { _ in })
        return try await Fixture.upload(uploader, data: Fixture.bytes(10))
    }

    private func body(_ request: HTTPRequest?) -> String {
        String(decoding: request?.bodyData ?? Data(), as: UTF8.self)
    }

    @Test func s3UploadsPartsCompletesAndCallsBack() async throws {
        let mock = MockTransport()
        await Fixture.routeSession(mock, Fixture.session(
            type: "s3", chunkSize: 4, concurrency: 2, uploadURLs: Self.partURLs, completeURL: Self.completeURL
        ))
        await mock.route("PUT", "https://s3.example.com/bucket/obj?partNumber=") { request in
            HTTPResponse(status: 200, headers: ["ETag": "\"e\(request.queryItems["partNumber"] ?? "")\""])
        }
        await mock.route("POST", Self.completeURL) { _ in HTTPResponse(status: 200) }
        await mock.route("GET", "/api/v4/callback/s3/s1/secret") { _ in .envelope() }
        await Fixture.routeFileInfo(mock)
        let store = InMemoryUploadProgressStore()
        let file = try await Fixture.upload(Uploader(client: Fixture.client(mock), store: store, sleep: { _ in }), data: Fixture.bytes(10))
        #expect(file == Fixture.file)

        let parts = await mock.requests("PUT", pathPrefix: "https://s3.example.com/")
        #expect(Set(parts.map(\.url.absoluteString)) == Set(Self.partURLs))
        #expect(parts.allSatisfy { $0.headers["Authorization"] == nil && $0.headers["Content-Type"] == "application/octet-stream" })
        let complete = await mock.requests("POST", pathPrefix: Self.completeURL)
        #expect(complete.count == 1)
        #expect(body(complete.first) == Self.threePartXML)
        #expect(complete.first?.headers["x-cos-forbid-overwrite"] == nil)
        let callbacks = await mock.requests("GET", pathPrefix: "/api/v4/callback/s3/s1/secret")
        #expect(callbacks.count == 1)
        #expect(callbacks.first?.headers["Authorization"] == nil)
    }

    @Test func s3StorageErrorIsHTTP() async throws {
        let mock = MockTransport()
        await mock.route("PUT", "https://s3.example.com/") { _ in HTTPResponse(status: 403, body: Data("<Error/>".utf8)) }
        let session = Fixture.session(type: "s3", chunkSize: 4, uploadURLs: Self.partURLs)
        await #expect(throws: CloudreveAPIError.http(status: 403, body: "<Error/>")) {
            _ = try await S3FamilyStrategy(variant: .s3).upload(
                chunk: UploadChunk(index: 0, offset: 0, length: 1), data: Data([1]), session: session, client: Fixture.client(mock)
            )
        }
    }

    @Test func cosCompleteAddsForbidOverwriteAndCallback() async throws {
        let mock = MockTransport()
        await mock.route("POST", Self.completeURL) { _ in HTTPResponse(status: 200) }
        await mock.route("GET", "/api/v4/callback/cos/s1/secret") { _ in .envelope() }
        let session = Fixture.session(type: "cos", chunkSize: 4, completeURL: Self.completeURL)
        try await S3FamilyStrategy(variant: .cos).complete(
            session: session, etags: [2: "e3", 0: "e1", 1: "e2"], client: Fixture.client(mock)
        )
        let complete = try #require(await mock.requests("POST", pathPrefix: Self.completeURL).first)
        #expect(complete.headers["x-cos-forbid-overwrite"] == "true")
        #expect(body(complete) == Self.threePartXML)
        #expect(await mock.requests("GET", pathPrefix: "/api/v4/callback/cos/s1/secret").count == 1)
    }

    @Test func ossCompleteUsesHeadersWithoutBodyOrCallback() async throws {
        let mock = MockTransport()
        await mock.route("POST", Self.completeURL) { _ in HTTPResponse(status: 200) }
        let session = Fixture.session(type: "oss", chunkSize: 4, completeURL: Self.completeURL)
        try await S3FamilyStrategy(variant: .oss).complete(session: session, etags: [0: "e1"], client: Fixture.client(mock))
        let requests = await mock.requests
        #expect(requests.count == 1)
        let complete = try #require(requests.first)
        #expect(complete.method == "POST")
        #expect(complete.headers["x-oss-forbid-overwrite"] == "true")
        #expect(complete.headers["x-oss-complete-all"] == "yes")
        #expect(complete.headers["Content-Length"] == "0")
        #expect(complete.body == HTTPBody.none)
    }

    @Test func obsCompleteSendsXMLWithoutCallback() async throws {
        let mock = MockTransport()
        await mock.route("POST", Self.completeURL) { _ in HTTPResponse(status: 200) }
        let session = Fixture.session(type: "obs", chunkSize: 4, completeURL: Self.completeURL)
        try await S3FamilyStrategy(variant: .obs).complete(
            session: session, etags: [0: "e1", 1: "e2", 2: "e3"], client: Fixture.client(mock)
        )
        let requests = await mock.requests
        #expect(requests.count == 1)
        #expect(body(requests.first) == Self.threePartXML)
    }

    @Test func oneDriveSendsContentRangeAndCallback() async throws {
        let mock = MockTransport()
        let uploadURL = "https://graph.example.com/upload/abc"
        await Fixture.routeSession(mock, Fixture.session(type: "onedrive", chunkSize: 4, uploadURLs: [uploadURL]))
        await mock.route("PUT", uploadURL) { _ in HTTPResponse(status: 202) }
        await mock.route("POST", "/api/v4/callback/onedrive/s1/secret") { _ in .envelope() }
        await Fixture.routeFileInfo(mock)
        _ = try await uploadTenBytes(mock)
        let puts = await mock.requests("PUT", pathPrefix: uploadURL)
        #expect(puts.map { $0.headers["Content-Range"] } == ["bytes 0-3/10", "bytes 4-7/10", "bytes 8-9/10"])
        #expect(puts.map { $0.bodyData?.count } == [4, 4, 2])
        #expect(puts.allSatisfy { $0.headers["Authorization"] == nil })
        #expect(await mock.requests("POST", pathPrefix: "/api/v4/callback/onedrive/s1/secret").count == 1)
    }

    @Test func remoteSendsCredentialAndChunkQuery() async throws {
        let mock = MockTransport()
        let nodeURL = "https://slave.example.com/api/v4/slave/upload/s1"
        await Fixture.routeSession(mock, Fixture.session(
            type: "remote", chunkSize: 4, uploadURLs: [nodeURL], credential: "Bearer Cr abc:123"
        ))
        await mock.route("POST", nodeURL) { _ in HTTPResponse(status: 200, body: Data(#"{"code":0,"msg":""}"#.utf8)) }
        await Fixture.routeFileInfo(mock)
        _ = try await uploadTenBytes(mock)
        let posts = await mock.requests("POST", pathPrefix: nodeURL)
        #expect(posts.map(\.url.absoluteString) == (0...2).map { "\(nodeURL)?chunk=\($0)" })
        #expect(posts.allSatisfy { $0.headers["Authorization"] == "Bearer Cr abc:123" })
        #expect(await mock.requests("POST", pathPrefix: "/api/v4/file/upload/").isEmpty)
    }

    @Test func remoteBusinessErrorThrowsServer() async throws {
        let mock = MockTransport()
        let nodeURL = "https://slave.example.com/upload"
        await mock.route("POST", nodeURL) { _ in HTTPResponse(status: 200, body: Data(#"{"code":40001,"msg":"bad"}"#.utf8)) }
        let session = Fixture.session(type: "remote", chunkSize: 4, uploadURLs: [nodeURL], credential: "c")
        await #expect(throws: CloudreveAPIError.server(code: 40001, message: "bad", correlationID: nil)) {
            _ = try await RemoteStrategy().upload(
                chunk: UploadChunk(index: 0, offset: 0, length: 1), data: Data([1]), session: session, client: Fixture.client(mock)
            )
        }
    }

    @Test func qiniuUploadsPartsAndCompletesWithJSON() async throws {
        let mock = MockTransport()
        let base = "https://up.qiniup.com/buckets/b/objects/o/uploads/u1"
        await mock.route("PUT", base) { _ in HTTPResponse(status: 200, body: Data(#"{"etag":"q2","md5":"x"}"#.utf8)) }
        await mock.route("POST", base) { _ in HTTPResponse(status: 200) }
        let session = Fixture.session(type: "qiniu", chunkSize: 4, uploadURLs: [base], credential: "tok")
        let client = Fixture.client(mock)
        let strategy = QiniuStrategy()
        let etag = try await strategy.upload(
            chunk: UploadChunk(index: 1, offset: 4, length: 1), data: Data([1]), session: session, client: client
        )
        #expect(etag == "q2")
        try await strategy.complete(session: session, etags: [1: "q2", 0: "q1"], client: client)
        let put = try #require(await mock.requests("PUT", pathPrefix: base).first)
        #expect(put.url.absoluteString == base + "/2")
        #expect(put.headers["Authorization"] == "UpToken tok")
        let post = try #require(await mock.requests("POST", pathPrefix: base).first)
        #expect(post.headers["Authorization"] == "UpToken tok")
        #expect(post.headers["Content-Type"] == "application/json")
        let json = try Fixture.json(post.bodyData)
        #expect(json["mimeType"] as? String == "text/plain")
        let parts = try #require(json["parts"] as? [[String: Any]])
        #expect(parts.map { $0["etag"] as? String } == ["q1", "q2"])
        #expect(parts.map { $0["partNumber"] as? Int } == [1, 2])
    }

    @Test func upyunPostsMultipartAndWaitsForCallback() async throws {
        let mock = MockTransport()
        let uploadURL = "https://v0.api.upyun.com/bucket"
        var session = Fixture.session(type: "upyun", chunkSize: 0, uploadURLs: [uploadURL], credential: "UPYUN op:sig")
        session.uploadPolicy = "policy-b64"
        await Fixture.routeSession(mock, session)
        await mock.route("POST", uploadURL) { _ in HTTPResponse(status: 200) }
        await Fixture.routeFileInfo(mock)
        let sleeps = SleepLog()
        let uploader = Uploader(client: Fixture.client(mock), store: InMemoryUploadProgressStore(), sleep: { await sleeps.append($0) })
        _ = try await Fixture.upload(uploader, data: Data("hello".utf8))
        #expect(await sleeps.durations == [.seconds(10)])
        let post = try #require(await mock.requests("POST", pathPrefix: uploadURL).first)
        let contentType = try #require(post.headers["Content-Type"])
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let expected = "--\(boundary)\r\nContent-Disposition: form-data; name=\"policy\"\r\n\r\npolicy-b64\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"authorization\"\r\n\r\nUPYUN op:sig\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"content-type\"\r\n\r\ntext/plain\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"file\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\nhello\r\n--\(boundary)--\r\n"
        #expect(body(post) == expected)
    }
}
