/// 跨 await 的串行门闩：提交的任务按调用顺序逐个执行，前一个结束（含失败）后才开始下一个。
///
/// 仅把调用方改成 actor 不够：actor 在 await 处可重入，两个调用会交错执行。
/// 这里在第一个挂起点之前同步更新队尾，因此顺序由进入 `run` 的先后决定。
actor SerialGate {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            return try await body()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
