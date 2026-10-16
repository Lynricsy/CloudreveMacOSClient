import GRDB

/// 云盘状态（`drive.status`）。
public enum DriveStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case active
    case eventPushLost = "event_push_lost"
    case credentialExpired = "credential_expired"
}
