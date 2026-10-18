import Foundation
import Testing
@testable import CloudreveAPI

@Suite struct CloudreveClientTests {
    @Test func envelopeSuccessDecodesData() async throws {
        let mock = MockTransport()
        await mock.route("GET", "/api/v4/user/me") { _ in .envelope(dataJSON: #"{"id":"u1","email":"a@b.c"}"#) }
        let client = Fixtures.client(mock: mock, store: InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials()]))
        let user = try await client.me()
        #expect(user == User(id: "u1", email: "a@b.c"))
        let request = try #require(await mock.requests.first)
        #expect(request.headers["Authorization"] == "Bearer old-access")
        #expect(request.headers["X-Cr-Client-Id"] != nil)
    }

    @Test func businessErrorThrowsServer() async throws {
        let mock = MockTransport()
        await mock.route("GET", "/api/v4/file/info") { _ in .envelope(code: 40044, msg: "not found") }
        let client = Fixtures.client(mock: mock, store: InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials()]))
        await #expect(throws: CloudreveAPIError.server(code: 40044, message: "not found", correlationID: nil)) {
            _ = try await client.fileInfo(id: "x")
        }
    }

    @Test func httpErrorThrowsHTTP() async throws {
        let mock = MockTransport()
        await mock.route("GET", "/api/v4/site/ping") { _ in HTTPResponse(status: 502, body: Data("bad gateway".utf8)) }
        let client = CloudreveClient(site: Fixtures.site, transport: mock, tokens: nil, clientID: nil)
        await #expect(throws: CloudreveAPIError.http(status: 502, body: "bad gateway")) {
            _ = try await client.ping()
        }
    }

    @Test func recoversAfterUnauthorized() async throws {
        let mock = MockTransport()
        let calls = Counter()
        await mock.route("GET", "/api/v4/user/me") { request in
            if await calls.increment() == 1 { return .envelope(code: 401, msg: "login required") }
            #expect(request.headers["Authorization"] == "Bearer new-access")
            return .envelope(dataJSON: #"{"id":"u1"}"#)
        }
        await mock.route("POST", "/api/v4/session/token/refresh") { _ in .envelope(dataJSON: Fixtures.refreshJSON(access: "new-access")) }
        let store = InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials()])
        let user = try await Fixtures.client(mock: mock, store: store).me()
        #expect(user.id == "u1")
        #expect(await mock.requests("POST", pathPrefix: "/api/v4/session/token/refresh").count == 1)
        let meRequests = await mock.requests("GET", pathPrefix: "/api/v4/user/me")
        #expect(meRequests.map { $0.headers["Authorization"] } == ["Bearer old-access", "Bearer new-access"])
        #expect(try store.load(driveID: Fixtures.driveID)?.accessToken == "new-access")
    }

    @Test func refreshRejectedMeansCredentialInvalid() async throws {
        let mock = MockTransport()
        await mock.route("GET", "/api/v4/user/me") { _ in .envelope(code: 401) }
        await mock.route("POST", "/api/v4/session/token/refresh") { _ in .envelope(code: 40020, msg: "invalid") }
        let client = Fixtures.client(mock: mock, store: InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials()]))
        await #expect(throws: CloudreveAPIError.credentialInvalid) {
            _ = try await client.me()
        }
    }

    @Test func formEncodingUsesPercent20() async throws {
        #expect(FormEncoding.encode([("scope", "a b+c/d")]) == "scope=a%20b%2Bc%2Fd")
        let mock = MockTransport()
        // 服务端 ExchangeToken 返回标准 OAuth JSON，不带 {code,data,msg} 信封。
        await mock.route("POST", "/api/v4/session/oauth/token") { _ in
            let json = #"{"access_token":"a","token_type":"Bearer","expires_in":3600,"refresh_token":"r"}"#
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
        }
        let response = try await CloudreveClient.exchangeOAuthCode(
            site: Fixtures.site, transport: mock, code: "c 1", codeVerifier: "v"
        )
        #expect(response.refreshToken == "r")
        let request = try #require(await mock.requests.first)
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        let body = String(decoding: try #require(request.bodyData), as: UTF8.self)
        #expect(body.contains("code=c%201"))
        #expect(body.contains("redirect_uri=%2Fcallback%2Fdesktop"))
        #expect(body.contains("client_secret=\(OAuthConstants.clientSecret)"))
    }

    @Test func authorizeURLEncodesScopes() throws {
        let url = try #require(OAuthConstants.authorizeURL(site: Fixtures.site, codeChallenge: "ch", state: "st"))
        #expect(url.absoluteString.hasPrefix("https://drive.example.com/session/authorize?response_type=code"))
        #expect(url.absoluteString.contains("scope=profile%20email%20openid%20offline_access"))
        #expect(url.absoluteString.contains("code_challenge_method=S256"))
    }

    @Test func queryEscapesPlusAndSpace() async throws {
        let mock = MockTransport()
        let json = #"{"type":0,"id":"f","name":"a+b c","created_at":"2024-01-01T00:00:00Z","#
            + #""updated_at":"2024-01-01T00:00:00.123456789+08:00","size":3}"#
        await mock.route("GET", "/api/v4/file/info") { _ in .envelope(dataJSON: json) }
        let client = Fixtures.client(mock: mock, store: InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials()]))
        let info = try await client.fileInfo(uri: .my("/dir/a+b c"))
        #expect(info.name == "a+b c")
        let request = try #require(await mock.requests.first)
        #expect(request.url.query?.contains("%2B") == true)
        #expect(request.queryItems["uri"] == CloudreveURI.my("/dir/a+b c").description)
    }

    /// 按服务端实际输出解析扩展信息：实体带对象字段时照常解析，`sha256` 只有 OpenCloudreve 已算出时才有，
    /// 没有实体时服务端省略 `entities`。
    @Test func fileInfoExtendedDecodesEntityHashes() async throws {
        let mock = MockTransport()
        let base = #"{"type":0,"id":"f","name":"a","created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z","size":3"#
        let entities = #","extended_info":{"storage_used":3,"storage_policy":{"id":"p","name":"本机","type":"local"},"entities":["#
            + #"{"id":"e1","size":3,"type":0,"created_at":"2024-01-01T00:00:00Z","created_by":{"id":"u","nickname":"n"},"#
            + #""storage_policy":{"id":"p","type":"local"},"sha256":"BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"},"#
            + #"{"id":"e0","size":2,"type":0,"created_at":"2024-01-01T00:00:00Z","encrypted_with":"aes-256-ctr"}]}}"#
        await mock.route("GET", "/api/v4/file/info") { request in
            .envelope(dataJSON: request.queryItems["id"] == "bare" ? base + #","extended_info":{"storage_used":0}}"# : base + entities)
        }
        let client = Fixtures.client(mock: mock, store: InMemoryCredentialStore([Fixtures.driveID: Fixtures.credentials()]))

        let info = try await client.fileInfo(id: "f", extended: true)
        #expect(await mock.requests.first?.queryItems["extended"] == "true")
        let decoded = try #require(info.extendedInfo).entities
        #expect(decoded == [
            FileEntity(id: "e1", size: 3, sha256: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"),
            FileEntity(id: "e0", size: 2)
        ])
        let normalized = ContentDigest.normalizedSHA256(decoded[0].sha256 ?? "")
        #expect(normalized == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ContentDigest.normalizedSHA256("xyz") == nil)
        #expect(try await client.fileInfo(id: "bare", extended: true).extendedInfo?.entities == [])
    }

    @Test func serverVersionComparison() throws {
        #expect(try #require(ServerVersion.parse("4.14.0-pro")).isSupported)
        #expect(try #require(ServerVersion.parse("4.12")).isSupported)
        #expect(try !#require(ServerVersion.parse("4.11.9")).isSupported)
        #expect(ServerVersion.parse("abc") == nil)
    }

    @Test func callbackErrorsDoNotLeakSecret() async throws {
        let mock = MockTransport()
        await mock.route("GET", "/api/v4/callback/s3/s1/") { _ in HTTPResponse(status: 200, body: Data("<html>".utf8)) }
        await mock.route("POST", "/api/v4/callback/onedrive/s1/") { _ in HTTPResponse(status: 200, body: Data("<html>".utf8)) }
        let client = CloudreveClient(site: Fixtures.site, transport: mock, tokens: nil, clientID: nil)
        var errors: [any Error] = []
        do { try await client.completeS3Callback(policyType: "s3", sessionID: "s1", secret: "top-secret") } catch { errors.append(error) }
        do { try await client.completeOneDriveCallback(sessionID: "s1", secret: "top-secret") } catch { errors.append(error) }
        try #require(errors.count == 2)
        for error in errors {
            #expect(!String(describing: error).contains("top-secret"))
            #expect(!error.localizedDescription.contains("top-secret"))
            #expect(String(describing: error).contains("/callback/"))
        }
    }
}

actor Counter {
    private var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
    var current: Int { value }
}
