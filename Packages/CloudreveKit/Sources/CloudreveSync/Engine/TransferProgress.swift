import Foundation
import Synchronization

/// 一次传输的活动记录：开始时写入 `transfer` 行，进度按 ≥512KB 或 ≥500ms 节流更新。
/// 记录失败不影响同步操作本身（只是弹窗少一条活动），因此写库错误被忽略。
final class TransferProgress: Sendable {
    static let byteStep: Int64 = 512 * 1024
    static let timeStep: TimeInterval = 0.5

    let total: Int64
    private let id: String?
    private let store: TransferStore
    private let now: @Sendable () -> Date
    private let last = Mutex<(bytes: Int64, time: Date)>((0, .distantPast))

    init(
        store: TransferStore, driveID: String, kind: TransferKind, itemID: String?, name: String, uri: String,
        total: Int64, now: @escaping @Sendable () -> Date
    ) {
        self.store = store
        self.total = total
        self.now = now
        id = try? store.start(driveID: driveID, kind: kind, itemID: itemID, name: name, uri: uri, total: total)
    }

    func report(_ done: Int64) {
        guard let id else { return }
        let current = now()
        let due = last.withLock { last in
            guard done - last.bytes >= Self.byteStep || current.timeIntervalSince(last.time) >= Self.timeStep else { return false }
            last = (done, current)
            return true
        }
        if due { try? store.progress(id: id, done: done) }
    }

    func finish(error: String?, isConflict: Bool = false) {
        guard let id else { return }
        try? store.finish(id: id, error: error, isConflict: isConflict)
    }
}
