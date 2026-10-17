import CloudreveAPI
import Foundation

extension DriveManager {
    /// 概览在 1 分钟内视为新鲜，切换设置页标签或重开窗口不重复请求。
    static let overviewMaxAge: TimeInterval = 60

    /// 加载设置页概览，同时刷新容量。`force` 为假且数据新鲜时直接返回。
    func loadOverview(id: String, force: Bool) async {
        var state = overviews[id] ?? DriveOverviewState()
        guard !state.isLoading, force || !state.isFresh(now: Date(), maxAge: Self.overviewMaxAge),
              let record = try? driveStore.get(id: id) else { return }
        state.isLoading = true
        overviews[id] = state

        async let capacity: Void = refreshCapacity(driveID: id)
        do {
            let overview = try await DriveRuntime.makeClient(drive: record).accountOverview(rootURI: record.remoteRootURI)
            state.overview = overview
            state.loadedAt = Date()
            state.errorMessage = nil
        } catch {
            if case CloudreveAPIError.credentialInvalid = error {
                try? driveStore.updateStatus(id: id, .credentialExpired)
            }
            state.errorMessage = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.shared.info("DriveManager", "加载概览失败：\(state.errorMessage ?? "")")
        }
        await capacity
        state.isLoading = false
        // 等待期间云盘可能已被移除，此时不再写回。
        guard drive(id: id) != nil else { return }
        overviews[id] = state
    }
}
