import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import CloudreveAPI

@Suite struct StreamingDelegateTests {
    /// 取消导致的完成回调先于头部 continuation 注册到达：注册后必须立即以取消结束，而不是永久挂起。
    @Test func completionBeforeHeadContinuationIsDelivered() async throws {
        let (_, dataContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let delegate = StreamingDelegate(dataContinuation: dataContinuation)
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://drive.example.com/")!)
        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))

        let outcome = Mutex<String?>(nil)
        Task {
            do {
                _ = try await withCheckedThrowingContinuation { delegate.setHeadContinuation($0) }
                outcome.withLock { $0 = "head" }
            } catch {
                outcome.withLock { $0 = error is CancellationError ? "cancelled" : "\(error)" }
            }
        }
        for _ in 0..<200 where outcome.withLock({ $0 }) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(outcome.withLock { $0 } == "cancelled")
    }

    /// 已取消的任务调用 `stream`：必须抛出取消，不得挂起。
    @Test func streamFromCancelledTaskThrowsCancellation() async throws {
        let outcome = Mutex<String?>(nil)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await URLSessionTransport().stream(HTTPRequest(method: "GET", url: URL(string: "https://127.0.0.1:9/")!))
                outcome.withLock { $0 = "head" }
            } catch {
                outcome.withLock { $0 = error is CancellationError ? "cancelled" : "\(error)" }
            }
        }
        for _ in 0..<500 where outcome.withLock({ $0 }) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        #expect(outcome.withLock { $0 } == "cancelled")
    }
}
