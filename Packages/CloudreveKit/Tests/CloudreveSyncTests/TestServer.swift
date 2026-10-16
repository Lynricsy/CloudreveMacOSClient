import CloudreveAPI
import Foundation
import Synchronization

/// 基于 `MockTransport` 的内存 Cloudreve 服务端：维护目录树，自动应答引擎用到的文件端点。
/// 测试可直接修改服务端状态（模拟网页端操作），或注入一次性响应覆盖。
final class TestServer: Sendable {
    typealias Handler = @Sendable (inout ServerState, HTTPRequest) throws -> HTTPResponse

    let mock = MockTransport()
    private let state: Mutex<ServerState>

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
            await mock.route(parts[0], parts[1]) { [self] request in respond(request, handler) }
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

    /// 下一个匹配请求返回业务错误码。
    func failNext(_ method: String, _ path: String, code: Int) {
        overrideNext(method, path, with: .envelope(code: code, msg: "注入错误 \(code)"))
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
}
