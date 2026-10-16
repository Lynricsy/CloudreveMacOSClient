import GRDB

/// `app_setting` 表：App 与扩展共享的键值设置。
public struct AppSettingRecord: SyncRecord, Equatable {
    public static let databaseTableName = "app_setting"

    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case key, value
    }
}
