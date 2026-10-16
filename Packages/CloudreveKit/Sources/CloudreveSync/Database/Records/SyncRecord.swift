import Foundation
import GRDB

/// 所有表记录的公共约定：日期列统一存为 Unix 秒（DOUBLE）。
public protocol SyncRecord: Codable, FetchableRecord, PersistableRecord, Sendable {}

extension SyncRecord {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}
