import Synchronization

/// 汇总并发分片的上传进度：已完成分片 + 各进行中分片的已发送字节（按分片长度截断），只向上单调回报。
///
/// 仅在分片完成时回报会让进度按分片（数十 MB）跳变，弹窗速度在 0 与峰值之间来回跳。
final class ChunkProgressTracker: Sendable {
    private struct State {
        var completed: Int64
        var inFlight: [Int: Int64] = [:]
        var reported: Int64 = -1
    }

    private let total: Int64
    private let report: Uploader.ProgressHandler
    private let state: Mutex<State>

    init(completed: Int64, total: Int64, report: @escaping Uploader.ProgressHandler) {
        self.total = total
        self.report = report
        state = Mutex(State(completed: completed))
    }

    /// 分片 `chunk` 当前请求已发送 `sent` 字节；重试从 0 重新计数时保持已回报的最大值。
    func sent(_ sent: Int64, of chunk: UploadChunk) {
        update { state in
            state.inFlight[chunk.index] = min(chunk.length, max(state.inFlight[chunk.index] ?? 0, sent))
        }
    }

    func completed(_ chunk: UploadChunk) {
        update { state in
            state.inFlight[chunk.index] = nil
            state.completed += chunk.length
        }
    }

    /// 当前值（用于开始时回报续传基线）。
    func reportCurrent() {
        update { _ in }
    }

    /// 在锁内计算并回报，保证多个回调线程之间顺序单调。
    private func update(_ mutate: (inout State) -> Void) {
        state.withLock { state in
            mutate(&state)
            let done = min(total, state.completed + state.inFlight.values.reduce(0, +))
            guard done > state.reported else { return }
            state.reported = done
            report(done, total)
        }
    }
}
