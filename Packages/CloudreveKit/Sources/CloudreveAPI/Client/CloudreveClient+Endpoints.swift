import Foundation

// MARK: - 站点与认证

extension CloudreveClient {
    /// `GET /site/ping`：返回服务端版本字符串。
    public func ping() async throws -> String {
        try await request("GET", "/site/ping", authenticated: false)
    }

    public func siteBasicConfig() async throws -> SiteBasicConfig {
        try await request("GET", "/site/config/basic", authenticated: false)
    }

    /// 用授权码换 token（OAuth2 + PKCE）。
    ///
    /// 服务端 ExchangeToken 返回标准 OAuth JSON（失败为 4xx + `{"error": ...}`），不带 `{code,data,msg}` 信封，
    /// 因此不走 `request`，直接解码响应体。
    public static func exchangeOAuthCode(
        site: URL, transport: any HTTPTransport, code: String, codeVerifier: String,
        redirectURI: String = OAuthConstants.callbackPath
    ) async throws -> OAuthTokenResponse {
        let client = CloudreveClient(site: site, transport: transport, tokens: nil, clientID: nil)
        let form: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("client_id", OAuthConstants.clientID),
            ("client_secret", OAuthConstants.clientSecret),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("code_verifier", codeVerifier)
        ]
        let path = "/session/oauth/token"
        let request = client.makeRequest(
            "POST", client.apiURL(path), body: .form(form), headers: ["Accept": "application/json"]
        )
        let response = try await client.sendMapped(request)
        guard (200..<300).contains(response.status) else {
            throw CloudreveAPIError.http(status: response.status, body: String(decoding: response.body, as: UTF8.self))
        }
        do {
            return try CloudreveDate.makeDecoder().decode(OAuthTokenResponse.self, from: response.body)
        } catch {
            throw CloudreveAPIError.decoding("\(path)：\(error)")
        }
    }

    /// 刷新 token。
    public static func refresh(site: URL, transport: any HTTPTransport, refreshToken: String) async throws -> Credentials {
        let client = CloudreveClient(site: site, transport: transport, tokens: nil, clientID: nil)
        let response: RefreshResponse = try await client.request(
            "POST", "/session/token/refresh",
            body: .encoding(RefreshBody(refreshToken: refreshToken)), authenticated: false
        )
        return Credentials(refresh: response)
    }

    public func me() async throws -> User {
        try await request("GET", "/user/me")
    }

    public func capacity() async throws -> Capacity {
        try await request("GET", "/user/capacity")
    }
}

// MARK: - 文件

extension CloudreveClient {
    public func listFiles(uri: CloudreveURI, pageSize: Int = 1000, nextPageToken: String? = nil) async throws -> ListResponse {
        var query: [(String, String)] = [("uri", uri.description), ("page_size", String(pageSize))]
        if let nextPageToken, !nextPageToken.isEmpty { query.append(("next_page_token", nextPageToken)) }
        return try await request("GET", "/file", query: query)
    }

    public func fileInfo(uri: CloudreveURI) async throws -> FileResponse {
        try await request("GET", "/file/info", query: [("uri", uri.description)])
    }

    /// `extended` 为 true 时附带扩展信息（含全部实体），服务端需多查实体、存储策略与分享，只在需要时请求。
    public func fileInfo(id: String, extended: Bool = false) async throws -> FileResponse {
        try await request("GET", "/file/info", query: extended ? [("id", id), ("extended", "true")] : [("id", id)])
    }

    /// 目录自身信息。服务端拒绝对文件系统根（如 `cloudreve://my`）调用 `/file/info`（业务码 403），
    /// 而列目录响应的 `parent` 对根与子目录都可用，因此以单条分页列目录取得。
    public func folderInfo(uri: CloudreveURI) async throws -> FileResponse {
        guard let parent = try await listFiles(uri: uri, pageSize: 1).parent else {
            throw CloudreveAPIError.decoding("/file：缺少 parent")
        }
        return parent
    }

    public func createItem(uri: CloudreveURI, isFolder: Bool) async throws -> FileResponse {
        let body = CreateBody(uri: uri.description, type: isFolder ? "folder" : "file", errOnConflict: true)
        return try await request("POST", "/file/create", body: .encoding(body))
    }

    public func rename(uri: CloudreveURI, newName: String) async throws -> FileResponse {
        try await request("POST", "/file/rename", body: .encoding(RenameBody(uri: uri.description, newName: newName)))
    }

    public func move(uris: [CloudreveURI], to dst: CloudreveURI) async throws {
        let body = MoveBody(uris: uris.map(\.description), dst: dst.description, copy: false)
        let _: EmptyData = try await request("POST", "/file/move", body: .encoding(body))
    }

    public func delete(uris: [CloudreveURI]) async throws {
        let body = DeleteBody(uris: uris.map(\.description), unlink: false, skipSoftDelete: false)
        let _: EmptyData = try await request("DELETE", "/file", body: .encoding(body))
    }

    /// 直接覆盖小文件内容；`previous` 为乐观锁 entity id。
    public func putContent(uri: CloudreveURI, previous: String?, data: Data) async throws -> FileResponse {
        var query: [(String, String)] = [("uri", uri.description)]
        if let previous { query.append(("previous", previous)) }
        return try await request("PUT", "/file/content", query: query,
                                 body: .raw(.data(data), contentType: "application/octet-stream"))
    }

    public func downloadURL(uri: CloudreveURI, entity: String?) async throws -> URL {
        let body = FileURLBody(uris: [uri.description], download: true, entity: entity, noCache: false)
        let response: DownloadURLsResponse = try await request("POST", "/file/url", body: .encoding(body))
        guard let first = response.urls.first, let url = URL(string: first.url, relativeTo: site)?.absoluteURL else {
            throw CloudreveAPIError.decoding("/file/url：缺少下载地址")
        }
        return url
    }

    public func thumbnail(uri: CloudreveURI) async throws -> ThumbResponse {
        try await request("GET", "/file/thumb", query: [("uri", uri.description)])
    }
}

// MARK: - 上传会话

extension CloudreveClient {
    public func createUploadSession(_ body: UploadSessionRequest) async throws -> UploadSession {
        try await request("PUT", "/file/upload", body: .encoding(body))
    }

    /// 上传本机/中转策略的分片；`body` 通常为磁盘暂存文件（`.file`），不整体读入内存。
    public func uploadChunk(sessionID: String, index: Int, body: HTTPBody) async throws {
        let _: EmptyData = try await request(
            "POST", "/file/upload/\(Self.escapePath(sessionID))/\(index)",
            body: .raw(body, contentType: "application/octet-stream")
        )
    }

    public func deleteUploadSession(id: String, uri: String) async throws {
        let _: EmptyData = try await request("DELETE", "/file/upload", body: .encoding(DeleteUploadBody(id: id, uri: uri)))
    }

    /// S3 系（s3/ks3/cos）完成回调。
    public func completeS3Callback(policyType: String, sessionID: String, secret: String) async throws {
        let path = "/callback/\(policyType)/\(Self.escapePath(sessionID))/\(Self.escapePath(secret))"
        let _: EmptyData = try await request("GET", path, authenticated: false)
    }

    public func completeOneDriveCallback(sessionID: String, secret: String) async throws {
        let path = "/callback/onedrive/\(Self.escapePath(sessionID))/\(Self.escapePath(secret))"
        let _: EmptyData = try await request("POST", path, authenticated: false)
    }

    /// 华为 OBS 完成回调：`POST /callback/obs/{session_id}/{key}`（与 s3/ks3/cos 的 GET 不同）。
    public func completeOBSCallback(sessionID: String, secret: String) async throws {
        let path = "/callback/obs/\(Self.escapePath(sessionID))/\(Self.escapePath(secret))"
        let _: EmptyData = try await request("POST", path, authenticated: false)
    }

    static func escapePath(_ segment: String) -> String {
        FormEncoding.escape(segment)
    }
}

// MARK: - 分享

extension CloudreveClient {
    /// `GET /share`：当前用户创建的分享。服务端要求 `page_size` 在 10…100 之间。
    public func listShares(pageSize: Int = 100, nextPageToken: String? = nil) async throws -> ShareListResponse {
        var query: [(String, String)] = [("page_size", String(pageSize))]
        if let nextPageToken, !nextPageToken.isEmpty { query.append(("next_page_token", nextPageToken)) }
        return try await request("GET", "/share", query: query)
    }
}

// MARK: - 流式与透传

extension CloudreveClient {
    /// 订阅目录事件（SSE）。
    public func events(uri: CloudreveURI) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, any Error>) {
        guard clientID != nil else { throw CloudreveAPIError.transport("clientID required") }
        guard let tokens else { throw CloudreveAPIError.credentialInvalid }
        let token = try await tokens.accessToken()
        let headers = ["Accept": "text/event-stream", "Authorization": "Bearer \(token)"]
        let request = makeRequest("GET", apiURL("/file/events", query: [("uri", uri.description)]), body: .none, headers: headers)
        do {
            return try await transport.stream(request)
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    /// 外部地址的流式 GET（下载、缩略图），不附加 Authorization。
    public func fetch(url: URL, headers: [String: String] = [:]) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, any Error>) {
        do {
            return try await transport.stream(HTTPRequest(method: "GET", url: url, headers: headers))
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    /// 透传外部请求（存储直传），不附加 Authorization。
    public func send(external request: HTTPRequest) async throws -> HTTPResponse {
        try await sendMapped(request)
    }
}
