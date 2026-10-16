import Foundation

/// `GET /file` 列目录响应。
public struct ListResponse: Codable, Sendable {
    public var files: [FileResponse]
    public var parent: FileResponse?
    public var pagination: Pagination?
    public var storagePolicy: StoragePolicy?

    public init(files: [FileResponse], parent: FileResponse? = nil, pagination: Pagination? = nil, storagePolicy: StoragePolicy? = nil) {
        self.files = files
        self.parent = parent
        self.pagination = pagination
        self.storagePolicy = storagePolicy
    }

    enum CodingKeys: String, CodingKey {
        case files, parent, pagination
        case storagePolicy = "storage_policy"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decodeIfPresent([FileResponse].self, forKey: .files) ?? []
        parent = try container.decodeIfPresent(FileResponse.self, forKey: .parent)
        pagination = try container.decodeIfPresent(Pagination.self, forKey: .pagination)
        storagePolicy = try container.decodeIfPresent(StoragePolicy.self, forKey: .storagePolicy)
    }
}
