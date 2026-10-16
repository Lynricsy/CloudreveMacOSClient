import Foundation

/// working set 自某 anchor 以来的变化。
public struct ChangeBatch: Sendable {
    public var updated: [SyncItem]
    public var deleted: [String]
    public var anchor: Int64
    public var moreComing: Bool

    public init(updated: [SyncItem], deleted: [String], anchor: Int64, moreComing: Bool) {
        self.updated = updated
        self.deleted = deleted
        self.anchor = anchor
        self.moreComing = moreComing
    }
}
