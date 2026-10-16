import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 在取消回调与创建任务的闭包之间安全传递 URLSessionTask。
final class TaskBox: Sendable {
    private struct State {
        var task: URLSessionTask?
        var cancelled = false
    }

    private let state = Mutex(State())

    func set(_ task: URLSessionTask) {
        let alreadyCancelled = state.withLock { state in
            state.task = task
            return state.cancelled
        }
        if alreadyCancelled { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { state in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }
}
