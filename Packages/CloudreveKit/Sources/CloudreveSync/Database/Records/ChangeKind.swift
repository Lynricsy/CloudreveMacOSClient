import GRDB

/// 变更日志类型（`change_log.kind`）。
public enum ChangeKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case update, delete
}
