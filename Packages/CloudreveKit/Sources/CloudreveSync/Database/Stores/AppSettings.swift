import CloudreveAPI
import Foundation
import GRDB

/// App 与扩展共享的键值设置（`app_setting` 表）。
public struct AppSettings: Sendable {
    public static let logLevelKey = "log_level"

    private let db: any DatabaseWriter

    public init(db: any DatabaseWriter) {
        self.db = db
    }

    public func get(_ key: String) throws -> String? {
        try db.read { db in try AppSettingRecord.fetchOne(db, key: key)?.value }
    }

    public func set(_ key: String, _ value: String) throws {
        try db.write { db in try AppSettingRecord(key: key, value: value).save(db) }
    }

    /// 读取布尔设置：`true`/`1` 为真，`false`/`0` 为假，缺失或无法识别时返回 `defaultValue`。
    public func bool(_ key: String, default defaultValue: Bool) throws -> Bool {
        switch try get(key) {
        case "true", "1": return true
        case "false", "0": return false
        default: return defaultValue
        }
    }

    /// 日志级别（键 `log_level`），缺失、无法识别或读库失败时为 `.info`。
    public var logLevel: LogLevel {
        (try? get(Self.logLevelKey)).flatMap(LogLevel.init(rawValue:)) ?? .info
    }
}
