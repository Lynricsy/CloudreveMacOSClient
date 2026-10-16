import CloudreveAPI
import Foundation

/// 内存服务端中的一个文件或目录。
struct ServerNode: Sendable, Equatable {
    var id: String
    var segments: [String]
    var isFolder: Bool
    var entityID: String
    var content: Data
    var createdAt: Date
    var updatedAt: Date

    var name: String { segments.last ?? "" }
    var uri: CloudreveURI { CloudreveURI(segments: segments) }

    var response: FileResponse {
        FileResponse(
            type: isFolder ? 1 : 0, id: id, name: name, createdAt: createdAt, updatedAt: updatedAt,
            size: isFolder ? 0 : Int64(content.count), path: uri.description, primaryEntity: isFolder ? nil : entityID
        )
    }
}

/// 处理器抛出的业务错误，转换为 `{code}` 信封。
struct ServerFailure: Error {
    let code: Int
}

/// 进行中的上传会话（本机存储策略）。
struct PendingUpload: Sendable {
    var segments: [String]
    var size: Int64
    var chunkSize: Int64
    var chunks: [Int: Data] = [:]

    var chunkCount: Int {
        chunkSize <= 0 ? 1 : Int((size + chunkSize - 1) / chunkSize)
    }

    func expectedLength(of index: Int) -> Int64 {
        chunkSize <= 0 ? size : min(chunkSize, size - Int64(index) * chunkSize)
    }

    /// 按序拼接全部分片。
    var assembled: Data {
        (0..<chunkCount).reduce(into: Data()) { $0.append(chunks[$1] ?? Data()) }
    }
}

/// 一次性覆盖响应：下一个匹配的请求直接返回该响应。
struct ResponseOverride: Sendable {
    let method: String
    let path: String
    let response: HTTPResponse

    /// `http` 开头按完整 URL 前缀匹配；以 `/` 结尾按路径前缀匹配；否则路径须完全相同。
    func matches(_ request: HTTPRequest) -> Bool {
        guard request.method == method else { return false }
        if path.hasPrefix("http") { return request.url.absoluteString.hasPrefix(path) }
        let requestPath = request.url.path
        return requestPath == path || (path.hasSuffix("/") && requestPath.hasPrefix(path))
    }
}

/// 内存目录树与上传会话；所有修改经 `TestServer` 的锁串行化。
struct ServerState: Sendable {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private(set) var nodes: [String: ServerNode] = [:]
    /// 全部历史版本内容（entity id → 字节），供下载指定版本。
    private(set) var entities: [String: Data] = [:]
    var uploads: [String: PendingUpload] = [:]
    var overrides: [ResponseOverride] = []
    /// 服务端单页上限（模拟 `max_page_size`）；nil 表示只受请求的 `page_size` 限制。
    var pageSizeLimit: Int?
    /// 新建上传会话的分片大小。
    var chunkSize: Int64 = 4
    private var counter = 0
    private var ticks = 0

    init(rootID: String) {
        nodes[rootID] = ServerNode(
            id: rootID, segments: [], isFolder: true, entityID: "", content: Data(), createdAt: Self.epoch, updatedAt: Self.epoch
        )
    }

    // MARK: - 查询

    func node(at segments: [String]) -> ServerNode? {
        nodes.values.first { $0.segments == segments }
    }

    func node(id: String) -> ServerNode? {
        nodes[id]
    }

    /// 直接子项，按名称排序。
    func children(of folder: ServerNode) -> [ServerNode] {
        nodes.values
            .filter { $0.segments.count == folder.segments.count + 1 && $0.segments.starts(with: folder.segments) }
            .sorted { $0.name < $1.name }
    }

    func entityData(_ entityID: String) -> Data? {
        entities[entityID]
    }

    // MARK: - 修改

    /// 类似 hashid 的稳定 id。
    mutating func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)\(String(counter * 7919, radix: 36))"
    }

    /// 单调递增的服务端时间（每次修改前进 1 秒）。
    mutating func tick() -> Date {
        ticks += 1
        return Self.epoch.addingTimeInterval(TimeInterval(ticks))
    }

    /// 在已存在的父目录下插入新节点；调用方负责检查父目录与重名。
    @discardableResult
    mutating func insert(segments: [String], isFolder: Bool, content: Data = Data(), id: String? = nil) -> ServerNode {
        let date = tick()
        var node = ServerNode(
            id: id ?? nextID(isFolder ? "D" : "F"), segments: segments, isFolder: isFolder, entityID: "", content: Data(),
            createdAt: date, updatedAt: date
        )
        if !isFolder {
            node.entityID = storeEntity(content)
            node.content = content
        }
        nodes[node.id] = node
        return node
    }

    /// 写入新版本内容，返回新 entity id。
    @discardableResult
    mutating func setContent(id: String, _ content: Data) -> String {
        let entity = storeEntity(content)
        nodes[id]?.content = content
        nodes[id]?.entityID = entity
        let date = tick()
        nodes[id]?.updatedAt = date
        return entity
    }

    /// 移动/重命名节点，后代路径一并改写。
    mutating func relocate(id: String, to newSegments: [String]) {
        guard let old = nodes[id]?.segments else { return }
        for (key, node) in nodes where node.segments.count > old.count && node.segments.starts(with: old) {
            nodes[key]?.segments = newSegments + node.segments.dropFirst(old.count)
        }
        nodes[id]?.segments = newSegments
        let date = tick()
        nodes[id]?.updatedAt = date
    }

    /// 删除节点及其全部后代。
    mutating func removeTree(id: String) {
        guard let root = nodes[id]?.segments else { return }
        nodes = nodes.filter { !$0.value.segments.starts(with: root) }
    }

    /// 取出第一个匹配请求的一次性覆盖。
    mutating func takeOverride(for request: HTTPRequest) -> HTTPResponse? {
        guard let index = overrides.firstIndex(where: { $0.matches(request) }) else { return nil }
        return overrides.remove(at: index).response
    }

    private mutating func storeEntity(_ content: Data) -> String {
        let entity = nextID("E")
        entities[entity] = content
        return entity
    }
}
