import CloudreveAPI
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Synchronization

/// 基于 `MockTransport` 的内存 Cloudreve 服务端：维护目录树，自动应答引擎用到的文件端点。
/// 测试可直接修改服务端状态（模拟网页端操作），或注入一次性响应覆盖。
final class TestServer: Sendable {
    typealias Handler = @Sendable (inout ServerState, HTTPRequest) throws -> HTTPResponse

    let mock = MockTransport()
    private let state: Mutex<ServerState>
    /// 「方法 路径」→ 响应前的延迟（模拟慢请求，用于并发测试）。
    private let latencies = Mutex<[String: Duration]>([:])
    /// 「方法 路径」→ 挂起该端点请求的闸门（确定性地制造慢请求）。
    private let gates = Mutex<[String: RequestGate]>([:])
    /// 已应答请求的「方法 路径」（路由注册时的写法），按应答完成的先后排列。
    private let completions = Mutex<[String]>([])

    private init(rootID: String) {
        state = Mutex(ServerState(rootID: rootID))
    }

    /// 创建服务端并注册全部路由。
    static func start(rootID: String) async -> TestServer {
        let server = TestServer(rootID: rootID)
        await server.install()
        return server
    }

    private func install() async {
        // 「方法 路径」→ 处理器
        let routes: [(endpoint: String, handler: Handler)] = [
            ("GET /api/v4/file", { try $0.list($1) }),
            ("GET /api/v4/file/info", { try $0.info($1) }),
            ("POST /api/v4/file/create", { try $0.create($1) }),
            ("POST /api/v4/file/rename", { try $0.rename($1) }),
            ("POST /api/v4/file/move", { try $0.move($1) }),
            ("DELETE /api/v4/file", { try $0.delete($1) }),
            ("PUT /api/v4/file/upload", { try $0.createUpload($1) }),
            ("DELETE /api/v4/file/upload", { _, _ in .envelope() }),
            ("POST /api/v4/file/upload/", { try $0.uploadChunk($1) }),
            ("PUT /api/v4/file/content", { try $0.putContent($1) }),
            ("POST /api/v4/file/url", { try $0.fileURL($1) }),
            ("GET \(ServerState.downloadPrefix)", { $0.download($1) }),
            ("POST /api/v4/session/token/refresh", { _, _ in Self.refreshResponse() })
        ]
        for (endpoint, handler) in routes {
            let parts = endpoint.split(separator: " ", maxSplits: 1).map(String.init)
            await mock.route(parts[0], parts[1]) { [self] request in
                if let delay = latencies.withLock({ $0[endpoint] }) { try await Task.sleep(for: delay) }
                if let gate = gates.withLock({ $0[endpoint] }) { await gate.wait() }
                let response = respond(request, handler)
                completions.withLock { $0.append(endpoint) }
                return response
            }
        }
    }

    private func respond(_ request: HTTPRequest, _ handler: Handler) -> HTTPResponse {
        state.withLock { state in
            if let override = state.takeOverride(for: request) { return override }
            do {
                return try handler(&state, request)
            } catch let failure as ServerFailure {
                return .envelope(code: failure.code, msg: "模拟错误 \(failure.code)")
            } catch {
                return HTTPResponse(status: 500, body: Data(String(describing: error).utf8))
            }
        }
    }

    private static func refreshResponse() -> HTTPResponse {
        let access = CloudreveDate.format(Date().addingTimeInterval(3600))
        let refresh = CloudreveDate.format(Date().addingTimeInterval(86400))
        let json = #"{"access_token":"renewed","refresh_token":"r2","access_expires":"\#(access)","refresh_expires":"\#(refresh)"}"#
        return .envelope(dataJSON: json)
    }

    /// 等待该端点（路由注册时的写法）至少应答过一次；超时视为测试失败。
    func waitUntilCompleted(_ endpoint: String, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !completions.withLock({ $0.contains(endpoint) }) {
            guard ContinuousClock.now < deadline else { throw ServerFailure(code: -1) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - 测试操作（模拟网页端改动）

    @discardableResult
    func addFolder(_ path: String, id: String? = nil) -> String {
        state.withLock { $0.insert(segments: CloudreveURI.my(path).segments, isFolder: true, id: id).id }
    }

    @discardableResult
    func addFile(_ path: String, content: Data = Data("hello".utf8), id: String? = nil) -> String {
        state.withLock { $0.insert(segments: CloudreveURI.my(path).segments, isFolder: false, content: content, id: id).id }
    }

    /// 覆盖内容，返回新 entity id。
    @discardableResult
    func replaceContent(_ path: String, with content: Data) -> String {
        state.withLock { state in
            guard let node = state.node(at: CloudreveURI.my(path).segments) else { preconditionFailure("不存在：\(path)") }
            return state.setContent(id: node.id, content)
        }
    }

    /// 服务端公布 `entity` 的 SHA-256：默认为其真实内容的摘要，传 `sha256` 可模拟与存储内容不符的记录。
    func publishHash(entity: String, sha256: String? = nil) {
        state.withLock { state in
            let actual = state.entityData(entity).map { ContentDigest.hex(SHA256.hash(data: $0)) }
            state.publishedHashes[entity] = sha256 ?? actual
        }
    }

    func relocate(_ path: String, to newPath: String) {
        state.withLock { state in
            guard let node = state.node(at: CloudreveURI.my(path).segments) else { preconditionFailure("不存在：\(path)") }
            state.relocate(id: node.id, to: CloudreveURI.my(newPath).segments)
        }
    }

    func remove(_ path: String) {
        state.withLock { state in
            guard let node = state.node(at: CloudreveURI.my(path).segments) else { return }
            state.removeTree(id: node.id)
        }
    }

    /// 把文件移入回收站：按 id 查询返回回收站路径，原路径不再存在。
    func trash(_ path: String) {
        state.withLock { state in
            guard let node = state.node(at: CloudreveURI.my(path).segments) else { preconditionFailure("不存在：\(path)") }
            state.trash(id: node.id)
        }
    }

    func node(_ path: String) -> ServerNode? {
        state.withLock { $0.node(at: CloudreveURI.my(path).segments) }
    }

    func node(id: String) -> ServerNode? {
        state.withLock { $0.node(id: id) }
    }

    /// 某目录下的子项名称（按名称排序）。
    func childNames(_ path: String) -> [String] {
        state.withLock { state in
            state.node(at: CloudreveURI.my(path).segments).map { state.children(of: $0).map(\.name) } ?? []
        }
    }

    // MARK: - 行为注入

    /// 下一个匹配请求返回业务错误码；`uri` 非 nil 时只匹配查询参数 `uri` 为该路径（`/a/b` 形式）的请求。
    func failNext(_ method: String, _ path: String, code: Int, uri: String? = nil) {
        let response = HTTPResponse.envelope(code: code, msg: "注入错误 \(code)")
        let target = uri.map { CloudreveURI.my($0).description }
        state.withLock { $0.overrides.append(ResponseOverride(method: method, path: path, uri: target, response: response)) }
    }

    /// 下一个匹配请求返回给定响应（路径规则见 `ResponseOverride`）。
    func overrideNext(_ method: String, _ path: String, with response: HTTPResponse) {
        state.withLock { $0.overrides.append(ResponseOverride(method: method, path: path, response: response)) }
    }

    func setPageSizeLimit(_ limit: Int?) {
        state.withLock { $0.pageSizeLimit = limit }
    }

    func setChunkSize(_ size: Int64) {
        state.withLock { $0.chunkSize = size }
    }

    /// 之后对该端点（如 `"GET /api/v4/file/info"`）的每个请求都先等待 `delay` 再应答。
    func setLatency(_ endpoint: String, _ delay: Duration) {
        latencies.withLock { $0[endpoint] = delay }
    }

    /// 之后对该端点的请求都挂起，直到调用返回闸门的 `open()`。
    func hold(_ endpoint: String) -> RequestGate {
        let gate = RequestGate()
        gates.withLock { $0[endpoint] = gate }
        return gate
    }
}

/// 挂起请求直到放行；放行后到达的请求不再等待。
final class RequestGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let proceed = state.withLock { state in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if proceed { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}
