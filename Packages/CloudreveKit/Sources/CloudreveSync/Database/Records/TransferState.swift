import GRDB

/// 传输状态（`transfer.state`）。
public enum TransferState: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case running, done, failed
}
