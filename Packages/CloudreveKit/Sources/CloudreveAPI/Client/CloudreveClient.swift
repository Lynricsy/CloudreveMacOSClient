import Foundation

/// Cloudreve v4 API 客户端。负责信封解析与凭证失效后的自动刷新重试。
public struct CloudreveClient: Sendable {
    public let site: URL
    public let transport: any HTTPTransport
    public let tokens: TokenManager?
    /// `X-Cr-Client-Id`：SSE 订阅必填；服务端据此不把本客户端自己的改动回推。
    public let clientID: UUID?

    public static let apiPrefix = "/api/v4"

    public init(site: URL, transport: any HTTPTransport, tokens: TokenManager?, clientID: UUID?) {
        self.site = Self.normalize(site: site)
        self.transport = transport
        self.tokens = tokens
        self.clientID = clientID
    }

    /// 去掉站点地址末尾的 `/`。
    public static func normalize(site: URL) -> URL {
        var text = site.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text) ?? site
    }

    /// 请求体。
    public enum RequestBody: Sendable {
        case none
        case json(Data)
        case form([(String, String)])
        case raw(HTTPBody, contentType: String)

        public static func encoding<E: Encodable>(_ value: E) throws -> RequestBody {
            .json(try JSONEncoder().encode(value))
        }
    }

    /// 构造 `/api/v4` 下的 URL；查询参数严格编码。
    public func apiURL(_ path: String, query: [(String, String)] = []) -> URL {
        var text = site.absoluteString + Self.apiPrefix + path
        if !query.isEmpty { text += "?" + FormEncoding.encode(query) }
        guard let url = URL(string: text) else { preconditionFailure("无效 URL：\(text)") }
        return url
    }

    /// 发送 API 请求并解出 `data`。凭证失效码会触发一次 `TokenManager.recover` 后重试。
    public func request<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [(String, String)] = [],
        body: RequestBody = .none,
        headers extraHeaders: [String: String] = [:],
        authenticated: Bool = true,
        as type: T.Type = T.self
    ) async throws -> T {
        try await perform(method, path, query: query, body: body, extraHeaders: extraHeaders,
                          authenticated: authenticated, retried: false)
    }

    private func perform<T: Decodable>(
        _ method: String, _ path: String, query: [(String, String)], body: RequestBody,
        extraHeaders: [String: String], authenticated: Bool, retried: Bool
    ) async throws -> T {
        var headers = extraHeaders
        headers["Accept"] = "application/json"
        var token: String?
        if authenticated {
            guard let tokens else { throw CloudreveAPIError.credentialInvalid }
            let current = try await tokens.accessToken()
            headers["Authorization"] = "Bearer \(current)"
            token = current
        }
        let request = makeRequest(method, apiURL(path, query: query), body: body, headers: headers)
        let response = try await sendMapped(request)
        guard (200..<300).contains(response.status) else {
            throw CloudreveAPIError.http(status: response.status, body: String(decoding: response.body, as: UTF8.self))
        }
        let envelope: APIEnvelope<T>
        do {
            envelope = try CloudreveDate.makeDecoder().decode(APIEnvelope<T>.self, from: response.body)
        } catch {
            throw CloudreveAPIError.decoding("\(path)：\(error)")
        }
        if envelope.code == 0 {
            if let data = envelope.data { return data }
            if let empty = EmptyData() as? T { return empty }
            throw CloudreveAPIError.decoding("\(path)：缺少 data")
        }
        if CloudreveAPIError.credentialCodes.contains(envelope.code), authenticated, let tokens, let token {
            guard !retried else { throw CloudreveAPIError.credentialInvalid }
            _ = try await tokens.recover(afterUnauthorizedWith: token)
            return try await perform(method, path, query: query, body: body, extraHeaders: extraHeaders,
                                     authenticated: authenticated, retried: true)
        }
        throw CloudreveAPIError.server(
            code: envelope.code, message: envelope.msg ?? envelope.error ?? "", correlationID: envelope.correlationID
        )
    }

    func makeRequest(_ method: String, _ url: URL, body: RequestBody, headers: [String: String]) -> HTTPRequest {
        var headers = headers
        if let clientID { headers["X-Cr-Client-Id"] = clientID.uuidString.lowercased() }
        let httpBody: HTTPBody
        switch body {
        case .none:
            httpBody = .none
        case .json(let data):
            headers["Content-Type"] = "application/json"
            httpBody = .data(data)
        case .form(let pairs):
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            httpBody = .data(Data(FormEncoding.encode(pairs).utf8))
        case let .raw(raw, contentType):
            headers["Content-Type"] = contentType
            httpBody = raw
        }
        return HTTPRequest(method: method, url: url, headers: headers, body: httpBody)
    }

    /// 统一把非协议错误映射为 `.transport`，保留取消。
    func sendMapped(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    static func mapTransportError(_ error: any Error) -> any Error {
        if error is CancellationError || error is CloudreveAPIError { return error }
        return CloudreveAPIError.transport(String(describing: error))
    }
}
