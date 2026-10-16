import CloudreveAPI
import Foundation

/// 监听器需要的引擎能力（便于测试替换）。
public protocol RemoteChangeApplier: Sendable {
    /// 全量兜底，返回是否产生了变更。
    func reconcile() async throws -> Bool
    /// 应用推送事件，返回是否产生了变更。
    func applyRemoteEvents(_ events: [FileEvent]) async throws -> Bool
}

extension SyncEngine: RemoteChangeApplier {}
