import Foundation

/// 测试用传输层：按「方法 + 路径前缀」路由，记录所有请求。
/// 路径前缀以 `http` 开头时匹配完整 URL（用于外部存储直传地址），否则匹配 URL path。
/// 多条路由同时匹配时取前缀最长的一条。
public actor MockTransport: HTTPTransport {
    public typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse
    public typealias StreamHandler = @Sendable (HTTPRequest) async throws -> (HTTPResponseHead, [Data])

    private struct Route<H> {
        let method: String
        let prefix: String
        let handler: H
    }

    public private(set) var requests: [HTTPRequest] = []
    private var routes: [Route<Handler>] = []
    private var streamRoutes: [Route<StreamHandler>] = []

    public init() {}

    public func route(_ method: String, _ pathPrefix: String, handler: @escaping Handler) {
        routes.append(Route(method: method, prefix: pathPrefix, handler: handler))
    }

    public func streamRoute(_ method: String, _ pathPrefix: String, handler: @escaping StreamHandler) {
        streamRoutes.append(Route(method: method, prefix: pathPrefix, handler: handler))
    }

    /// 清空请求记录。
    public func resetRequests() {
        requests.removeAll()
    }

    /// 满足条件的请求。
    public func requests(_ method: String, pathPrefix: String) -> [HTTPRequest] {
        requests.filter { $0.method == method && Self.matches(prefix: pathPrefix, request: $0) }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard let route = Self.bestMatch(routes, for: request) else {
            return HTTPResponse(status: 404, body: Data("no route".utf8))
        }
        return try await route.handler(request)
    }

    public func stream(_ request: HTTPRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, any Error>) {
        requests.append(request)
        let head: HTTPResponseHead
        let chunks: [Data]
        if let route = Self.bestMatch(streamRoutes, for: request) {
            (head, chunks) = try await route.handler(request)
        } else if let route = Self.bestMatch(routes, for: request) {
            let response = try await route.handler(request)
            (head, chunks) = (response.head, [response.body])
        } else {
            (head, chunks) = (HTTPResponseHead(status: 404), [Data("no route".utf8)])
        }
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        return (head, stream)
    }

    private static func bestMatch<H>(_ routes: [Route<H>], for request: HTTPRequest) -> Route<H>? {
        routes
            .filter { $0.method == request.method && matches(prefix: $0.prefix, request: request) }
            .max { $0.prefix.count < $1.prefix.count }
    }

    private static func matches(prefix: String, request: HTTPRequest) -> Bool {
        if prefix.hasPrefix("http") {
            return request.url.absoluteString.hasPrefix(prefix)
        }
        return request.url.path.hasPrefix(prefix)
    }
}

extension HTTPResponse {
    /// 构造 Cloudreve 信封响应；`dataJSON` 为 `data` 字段的原始 JSON 文本。
    public static func envelope(code: Int = 0, dataJSON: String = "null", msg: String = "") -> HTTPResponse {
        let msgJSON = (try? JSONEncoder().encode(msg)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        let json = #"{"code":\#(code),"data":\#(dataJSON),"msg":\#(msgJSON)}"#
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
    }

    /// 以 Encodable 值构造成功信封。
    public static func envelope<T: Encodable>(encoding value: T) throws -> HTTPResponse {
        let data = try JSONEncoder().encode(value)
        return envelope(dataJSON: String(decoding: data, as: UTF8.self))
    }
}
