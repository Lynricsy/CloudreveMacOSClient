import CloudreveSync
import Foundation

/// 界面展示用的云盘摘要（由 `DriveRecord` 映射，只保留界面读取的字段）。
struct DriveSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let siteURL: URL
    let siteTitle: String?
    let userEmail: String?
    let rootFileID: String
    let status: DriveStatus
    let ignorePatterns: [String]
    let capacityTotal: Int64
    let capacityUsed: Int64
    let capacityUpdatedAt: Date?
    /// 最近一次与服务端全量核对（reconcile）的时间。
    let lastReconcileAt: Date?

    init(record: DriveRecord) {
        id = record.id
        name = record.name
        siteURL = record.siteURL
        siteTitle = record.siteTitle
        userEmail = record.userEmail
        rootFileID = record.rootFileID
        status = record.status
        ignorePatterns = record.ignorePatterns
        capacityTotal = record.capacityTotal
        capacityUsed = record.capacityUsed
        capacityUpdatedAt = record.capacityUpdatedAt
        lastReconcileAt = record.lastReconcileAt
    }

    /// 容量信息是否早于 `maxAge` 秒（或从未获取）。
    func isCapacityStale(now: Date, maxAge: TimeInterval) -> Bool {
        guard let capacityUpdatedAt else { return true }
        return now.timeIntervalSince(capacityUpdatedAt) > maxAge
    }
}
