import CloudreveAPI
import Foundation
import GRDB

/// `drive` 表：一个已挂载的云盘（对应一个 File Provider 域）。
public struct DriveRecord: SyncRecord, Equatable {
    public static let databaseTableName = "drive"

    public var id: String
    public var name: String
    public var siteURL: URL
    public var remoteRootURI: CloudreveURI
    public var rootFileID: String
    public var userID: String
    public var userEmail: String?
    public var siteTitle: String?
    /// 请求头 `X-Cr-Client-Id`；SSE 依靠它排除本客户端自己的改动。
    public var clientID: UUID
    public var status: DriveStatus
    /// 用户忽略规则；列中存 JSON 数组文本。
    public var ignorePatterns: [String]
    public var capacityTotal: Int64
    public var capacityUsed: Int64
    public var capacityUpdatedAt: Date?
    public var lastReconcileAt: Date?
    public var createdAt: Date

    public init(
        id: String, name: String, siteURL: URL, remoteRootURI: CloudreveURI, rootFileID: String,
        userID: String, userEmail: String? = nil, siteTitle: String? = nil, clientID: UUID = UUID(),
        status: DriveStatus = .active, ignorePatterns: [String] = [], capacityTotal: Int64 = 0, capacityUsed: Int64 = 0,
        capacityUpdatedAt: Date? = nil, lastReconcileAt: Date? = nil, createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.siteURL = siteURL
        self.remoteRootURI = remoteRootURI
        self.rootFileID = rootFileID
        self.userID = userID
        self.userEmail = userEmail
        self.siteTitle = siteTitle
        self.clientID = clientID
        self.status = status
        self.ignorePatterns = ignorePatterns
        self.capacityTotal = capacityTotal
        self.capacityUsed = capacityUsed
        self.capacityUpdatedAt = capacityUpdatedAt
        self.lastReconcileAt = lastReconcileAt
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case siteURL = "site_url"
        case remoteRootURI = "remote_root_uri"
        case rootFileID = "root_file_id"
        case userID = "user_id"
        case userEmail = "user_email"
        case siteTitle = "site_title"
        case clientID = "client_id"
        case ignorePatterns = "ignore_patterns"
        case capacityTotal = "capacity_total"
        case capacityUsed = "capacity_used"
        case capacityUpdatedAt = "capacity_updated_at"
        case lastReconcileAt = "last_reconcile_at"
        case createdAt = "created_at"
    }

    // URL / URI / UUID / 数组在库中均以纯文本存储，因此手写编解码，避免 GRDB 默认的 JSON / BLOB 形式。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        siteURL = try Self.decodeText(container, .siteURL) { URL(string: $0) }
        remoteRootURI = try Self.decodeText(container, .remoteRootURI) { CloudreveURI(string: $0) }
        rootFileID = try container.decode(String.self, forKey: .rootFileID)
        userID = try container.decode(String.self, forKey: .userID)
        userEmail = try container.decodeIfPresent(String.self, forKey: .userEmail)
        siteTitle = try container.decodeIfPresent(String.self, forKey: .siteTitle)
        clientID = try Self.decodeText(container, .clientID) { UUID(uuidString: $0) }
        status = try container.decode(DriveStatus.self, forKey: .status)
        ignorePatterns = try Self.decodeText(container, .ignorePatterns) {
            try? JSONDecoder().decode([String].self, from: Data($0.utf8))
        }
        capacityTotal = try container.decode(Int64.self, forKey: .capacityTotal)
        capacityUsed = try container.decode(Int64.self, forKey: .capacityUsed)
        capacityUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .capacityUpdatedAt)
        lastReconcileAt = try container.decodeIfPresent(Date.self, forKey: .lastReconcileAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(siteURL.absoluteString, forKey: .siteURL)
        try container.encode(remoteRootURI.description, forKey: .remoteRootURI)
        try container.encode(rootFileID, forKey: .rootFileID)
        try container.encode(userID, forKey: .userID)
        try container.encode(userEmail, forKey: .userEmail)
        try container.encode(siteTitle, forKey: .siteTitle)
        try container.encode(clientID.uuidString, forKey: .clientID)
        try container.encode(status, forKey: .status)
        try container.encode(String(decoding: JSONEncoder().encode(ignorePatterns), as: UTF8.self), forKey: .ignorePatterns)
        try container.encode(capacityTotal, forKey: .capacityTotal)
        try container.encode(capacityUsed, forKey: .capacityUsed)
        try container.encode(capacityUpdatedAt, forKey: .capacityUpdatedAt)
        try container.encode(lastReconcileAt, forKey: .lastReconcileAt)
        try container.encode(createdAt, forKey: .createdAt)
    }

    private static func decodeText<T>(
        _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, _ parse: (String) -> T?
    ) throws -> T {
        let text = try container.decode(String.self, forKey: key)
        guard let value = parse(text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "无效的 \(key.rawValue)：\(text)")
        }
        return value
    }
}
