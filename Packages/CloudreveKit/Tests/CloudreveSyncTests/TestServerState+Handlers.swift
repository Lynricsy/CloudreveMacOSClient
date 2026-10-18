import CloudreveAPI
import Foundation

// 请求体 DTO（键名经 convertFromSnakeCase 转换）。

private struct CreateRequest: Decodable {
    let uri: String
    let type: String
    let errOnConflict: Bool?
}

private struct RenameRequest: Decodable {
    let uri: String
    let newName: String
}

private struct MoveRequest: Decodable {
    let uris: [String]
    let dst: String
}

private struct DeleteRequest: Decodable {
    let uris: [String]
}

private struct UploadRequest: Decodable {
    let uri: String
    let size: Int64
    let entityType: String?
    let previous: String?
}

private struct FileURLRequest: Decodable {
    let uris: [String]
    let entity: String?
}

/// 模拟 Cloudreve v4 文件端点的行为（错误码与服务端一致）。
extension ServerState {
    static let downloadPrefix = "https://storage.test/dl/"

    // MARK: - 查询

    func list(_ request: HTTPRequest) throws -> HTTPResponse {
        let query = request.queryItems
        let folder = try existing(query["uri"])
        guard folder.isFolder else { throw ServerFailure(code: 40001) }
        let all = children(of: folder)
        let requested = Int(query["page_size"] ?? "") ?? 1000
        let limit = max(1, min(requested, pageSizeLimit ?? Int.max))
        let offset = (query["next_page_token"]).flatMap { Int($0.dropFirst("cursor-".count)) } ?? 0
        let end = min(offset + limit, all.count)
        let next = end < all.count ? "cursor-\(end)" : ""
        let response = ListResponse(
            files: all[min(offset, end)..<end].map(\.response), parent: folder.response,
            pagination: Pagination(pageSize: limit, nextToken: next, isCursor: true)
        )
        return try .envelope(encoding: response)
    }

    func info(_ request: HTTPRequest) throws -> HTTPResponse {
        let query = request.queryItems
        var response: FileResponse
        if let id = query["id"] {
            if let node = trashed[id] {
                // 与真实服务端一致：回收站中的条目按 id 仍可查到，path 是回收站路径
                response = node.response
                response.path = "cloudreve://trash/\(UUID().uuidString.lowercased())"
            } else {
                guard let node = node(id: id) else { throw ServerFailure(code: 40044) }
                response = node.response
            }
        } else {
            response = try existing(query["uri"]).response
        }
        if query["extended"] == "true" {
            let owned = entityOwners.filter { $0.value == response.id }.keys.sorted()
            response.extendedInfo = FileExtendedInfo(entities: owned.map {
                FileEntity(id: $0, size: Int64(entities[$0]?.count ?? 0), sha256: publishedHashes[$0])
            })
        }
        return try .envelope(encoding: response)
    }

    func fileURL(_ request: HTTPRequest) throws -> HTTPResponse {
        let body: FileURLRequest = try Self.decode(request)
        let node = try existing(body.uris.first)
        let entity = body.entity ?? node.entityID
        guard entityData(entity) != nil else { throw ServerFailure(code: 40044) }
        return .envelope(dataJSON: #"{"urls":[{"url":"\#(Self.downloadPrefix)\#(entity)"}]}"#)
    }

    func download(_ request: HTTPRequest) -> HTTPResponse {
        guard let data = entityData(request.url.lastPathComponent) else { return HTTPResponse(status: 404) }
        return HTTPResponse(status: 200, body: data)
    }

    // MARK: - 元数据修改

    mutating func create(_ request: HTTPRequest) throws -> HTTPResponse {
        let body: CreateRequest = try Self.decode(request)
        let segments = try Self.segments(body.uri)
        if let node = node(at: segments) {
            guard body.errOnConflict == false else { throw ServerFailure(code: 40004) }
            return try .envelope(encoding: node.response)
        }
        try requireParent(of: segments)
        return try .envelope(encoding: insert(segments: segments, isFolder: body.type == "folder").response)
    }

    mutating func rename(_ request: HTTPRequest) throws -> HTTPResponse {
        let body: RenameRequest = try Self.decode(request)
        let node = try existing(body.uri)
        let target = node.segments.dropLast() + [body.newName]
        guard self.node(at: Array(target)) == nil else { throw ServerFailure(code: 40004) }
        relocate(id: node.id, to: Array(target))
        return try .envelope(encoding: self.node(id: node.id)?.response)
    }

    mutating func move(_ request: HTTPRequest) throws -> HTTPResponse {
        let body: MoveRequest = try Self.decode(request)
        let destination = try existing(body.dst)
        guard destination.isFolder else { throw ServerFailure(code: 40001) }
        for uri in body.uris {
            let node = try existing(uri)
            let target = destination.segments + [node.name]
            guard self.node(at: target) == nil else { throw ServerFailure(code: 40004) }
            relocate(id: node.id, to: target)
        }
        return .envelope()
    }

    mutating func delete(_ request: HTTPRequest) throws -> HTTPResponse {
        let body: DeleteRequest = try Self.decode(request)
        let targets = try body.uris.map { try existing($0) }
        for node in targets { removeTree(id: node.id) }
        return .envelope()
    }

    // MARK: - 内容

    /// 创建上传会话：已存在目标必须带 `entity_type: version`，`previous` 不符 → 40076；
    /// 不存在的目标不能带 `entity_type`。
    mutating func createUpload(_ request: HTTPRequest) throws -> HTTPResponse {
        let body: UploadRequest = try Self.decode(request)
        let segments = try Self.segments(body.uri)
        if let node = node(at: segments) {
            guard body.entityType == "version" else { throw ServerFailure(code: 40004) }
            if let previous = body.previous, previous != node.entityID { throw ServerFailure(code: 40076) }
        } else {
            guard body.entityType == nil else { throw ServerFailure(code: 40044) }
            try requireParent(of: segments)
        }
        let sessionID = nextID("S")
        uploads[sessionID] = PendingUpload(segments: segments, size: body.size, chunkSize: chunkSize)
        let session = UploadSession(
            sessionID: sessionID, chunkSize: chunkSize, expires: Int64(Date().timeIntervalSince1970) + 3600,
            storagePolicy: StoragePolicy(id: "p1", name: "本机", type: "local"), uri: body.uri
        )
        return try .envelope(encoding: session)
    }

    /// 分片：长度必须等于期望值（40013）；最后一块到达后落盘为新版本。
    mutating func uploadChunk(_ request: HTTPRequest) throws -> HTTPResponse {
        let parts = request.url.pathComponents
        guard parts.count >= 2, let index = Int(parts[parts.count - 1]) else { throw ServerFailure(code: 40001) }
        let sessionID = parts[parts.count - 2]
        guard var upload = uploads[sessionID], index < upload.chunkCount else { throw ServerFailure(code: 40011) }
        let data = request.bodyData ?? Data()
        guard Int64(data.count) == upload.expectedLength(of: index) else { throw ServerFailure(code: 40013) }
        upload.chunks[index] = data
        uploads[sessionID] = upload
        guard upload.chunks.count == upload.chunkCount else { return .envelope() }
        uploads[sessionID] = nil
        if let node = node(at: upload.segments) {
            setContent(id: node.id, upload.assembled)
        } else {
            insert(segments: upload.segments, isFolder: false, content: upload.assembled)
        }
        return .envelope()
    }

    mutating func putContent(_ request: HTTPRequest) throws -> HTTPResponse {
        let query = request.queryItems
        let node = try existing(query["uri"])
        if let previous = query["previous"], previous != node.entityID { throw ServerFailure(code: 40076) }
        setContent(id: node.id, request.bodyData ?? Data())
        return try .envelope(encoding: self.node(id: node.id)?.response)
    }

    // MARK: - 工具

    private func existing(_ uri: String?) throws -> ServerNode {
        guard let node = try uri.flatMap({ node(at: try Self.segments($0)) }) else { throw ServerFailure(code: 40044) }
        return node
    }

    private func requireParent(of segments: [String]) throws {
        guard !segments.isEmpty, let parent = node(at: Array(segments.dropLast())), parent.isFolder else {
            throw ServerFailure(code: 40044)
        }
    }

    private static func segments(_ uri: String) throws -> [String] {
        guard let parsed = CloudreveURI(string: uri) else { throw ServerFailure(code: 40001) }
        return parsed.segments
    }

    private static func decode<T: Decodable>(_ request: HTTPRequest) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = request.bodyData, let value = try? decoder.decode(T.self, from: data) else {
            throw ServerFailure(code: 40001)
        }
        return value
    }
}
