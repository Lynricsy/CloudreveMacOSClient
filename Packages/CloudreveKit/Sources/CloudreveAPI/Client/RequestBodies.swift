import Foundation

// 各端点的 JSON 请求体（键名与服务端一致）。均为内部 DTO，集中放在本文件。

struct RefreshBody: Encodable {
    let refreshToken: String
    enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token" }
}

struct CreateBody: Encodable {
    let uri: String
    let type: String
    let errOnConflict: Bool
    enum CodingKeys: String, CodingKey {
        case uri, type
        case errOnConflict = "err_on_conflict"
    }
}

struct RenameBody: Encodable {
    let uri: String
    let newName: String
    enum CodingKeys: String, CodingKey {
        case uri
        case newName = "new_name"
    }
}

struct MoveBody: Encodable {
    let uris: [String]
    let dst: String
    let copy: Bool
}

struct DeleteBody: Encodable {
    let uris: [String]
    let unlink: Bool
    let skipSoftDelete: Bool
    enum CodingKeys: String, CodingKey {
        case uris, unlink
        case skipSoftDelete = "skip_soft_delete"
    }
}

struct FileURLBody: Encodable {
    let uris: [String]
    let download: Bool
    let entity: String?
    let noCache: Bool
    enum CodingKeys: String, CodingKey {
        case uris, download, entity
        case noCache = "no_cache"
    }
}

struct DeleteUploadBody: Encodable {
    let id: String
    let uri: String
}
