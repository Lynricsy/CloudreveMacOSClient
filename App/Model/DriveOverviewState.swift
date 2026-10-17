import CloudreveAPI
import Foundation

/// 设置页单云盘概览的加载状态；重新加载时保留上次数据，界面不闪空。
struct DriveOverviewState: Equatable {
    var overview: AccountOverview?
    var loadedAt: Date?
    var isLoading = false
    var errorMessage: String?

    /// 上次成功加载距今不足 `maxAge` 秒。
    func isFresh(now: Date, maxAge: TimeInterval) -> Bool {
        guard let loadedAt else { return false }
        return now.timeIntervalSince(loadedAt) < maxAge
    }
}
