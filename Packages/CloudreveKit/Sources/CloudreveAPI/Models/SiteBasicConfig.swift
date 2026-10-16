import Foundation

/// `GET /site/config/basic` 中客户端关心的字段。
public struct SiteBasicConfig: Codable, Sendable, Equatable {
    public var title: String?
    public var logo: String?
    public var instanceID: String?

    public init(title: String? = nil, logo: String? = nil, instanceID: String? = nil) {
        self.title = title
        self.logo = logo
        self.instanceID = instanceID
    }

    enum CodingKeys: String, CodingKey {
        case title, logo
        case instanceID = "instance_id"
    }
}
