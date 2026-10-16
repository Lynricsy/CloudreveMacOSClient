import GRDB

/// 传输方向（`transfer.kind`）。
public enum TransferKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case upload, download
}
