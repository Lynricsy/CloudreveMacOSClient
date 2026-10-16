import Foundation

/// `PUT /file/upload` 创建的上传会话。可编码以便持久化后断点续传。
public struct UploadSession: Codable, Sendable, Equatable {
    public var sessionID: String
    public var uploadID: String?
    public var chunkSize: Int64
    /// Unix 秒。
    public var expires: Int64
    public var uploadURLs: [String]?
    public var credential: String?
    public var completeURL: String?
    public var storagePolicy: StoragePolicy?
    public var uri: String
    public var callbackSecret: String
    public var mimeType: String?
    public var uploadPolicy: String?
    /// 存在即表示该策略要求客户端加密（暂不支持）。
    public var encryptMetadata: EncryptMetadataMarker?

    public init(
        sessionID: String, uploadID: String? = nil, chunkSize: Int64, expires: Int64,
        uploadURLs: [String]? = nil, credential: String? = nil, completeURL: String? = nil,
        storagePolicy: StoragePolicy? = nil, uri: String, callbackSecret: String = "",
        mimeType: String? = nil, uploadPolicy: String? = nil, encryptMetadata: EncryptMetadataMarker? = nil
    ) {
        self.sessionID = sessionID
        self.uploadID = uploadID
        self.chunkSize = chunkSize
        self.expires = expires
        self.uploadURLs = uploadURLs
        self.credential = credential
        self.completeURL = completeURL
        self.storagePolicy = storagePolicy
        self.uri = uri
        self.callbackSecret = callbackSecret
        self.mimeType = mimeType
        self.uploadPolicy = uploadPolicy
        self.encryptMetadata = encryptMetadata
    }

    enum CodingKeys: String, CodingKey {
        case expires, credential, uri, completeURL
        case sessionID = "session_id"
        case uploadID = "upload_id"
        case chunkSize = "chunk_size"
        case uploadURLs = "upload_urls"
        case storagePolicy = "storage_policy"
        case callbackSecret = "callback_secret"
        case mimeType = "mime_type"
        case uploadPolicy = "upload_policy"
        case encryptMetadata = "encrypt_metadata"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        uploadID = try container.decodeIfPresent(String.self, forKey: .uploadID)
        chunkSize = try container.decodeIfPresent(Int64.self, forKey: .chunkSize) ?? 0
        expires = try container.decodeIfPresent(Int64.self, forKey: .expires) ?? 0
        uploadURLs = try container.decodeIfPresent([String].self, forKey: .uploadURLs)
        credential = try container.decodeIfPresent(String.self, forKey: .credential)
        completeURL = try container.decodeIfPresent(String.self, forKey: .completeURL)
        storagePolicy = try container.decodeIfPresent(StoragePolicy.self, forKey: .storagePolicy)
        uri = try container.decodeIfPresent(String.self, forKey: .uri) ?? ""
        callbackSecret = try container.decodeIfPresent(String.self, forKey: .callbackSecret) ?? ""
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        uploadPolicy = try container.decodeIfPresent(String.self, forKey: .uploadPolicy)
        encryptMetadata = try container.decodeIfPresent(EncryptMetadataMarker.self, forKey: .encryptMetadata)
    }
}

/// 只记录 `encrypt_metadata` 字段存在与否，不解析内容。
public struct EncryptMetadataMarker: Codable, Sendable, Equatable {
    public init() {}
    public init(from decoder: any Decoder) throws {}
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([String: String]())
    }
}
