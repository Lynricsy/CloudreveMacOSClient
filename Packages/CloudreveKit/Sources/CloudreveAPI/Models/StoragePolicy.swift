import Foundation

/// 存储策略（上传协议由 `type` 与 `relay` 决定）。
public struct StoragePolicy: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var type: String
    public var maxSize: Int64
    public var relay: Bool?
    public var chunkConcurrency: Int?

    public init(id: String = "", name: String = "", type: String, maxSize: Int64 = 0, relay: Bool? = nil, chunkConcurrency: Int? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.maxSize = maxSize
        self.relay = relay
        self.chunkConcurrency = chunkConcurrency
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type, relay
        case maxSize = "max_size"
        case chunkConcurrency = "chunk_concurrency"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try container.decode(String.self, forKey: .type)
        maxSize = try container.decodeIfPresent(Int64.self, forKey: .maxSize) ?? 0
        relay = try container.decodeIfPresent(Bool.self, forKey: .relay)
        chunkConcurrency = try container.decodeIfPresent(Int.self, forKey: .chunkConcurrency)
    }
}
