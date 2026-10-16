import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 把 URLSessionDataDelegate 回调转换为「头部 continuation + 数据流」。
/// Linux 上没有 `URLSession.bytes(for:)`，所以统一走 delegate。
final class StreamingDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var headContinuation: CheckedContinuation<HTTPResponseHead, any Error>?
        var headDelivered = false
    }

    private let state = Mutex(State())
    private let dataContinuation: AsyncThrowingStream<Data, any Error>.Continuation

    init(dataContinuation: AsyncThrowingStream<Data, any Error>.Continuation) {
        self.dataContinuation = dataContinuation
    }

    func setHeadContinuation(_ continuation: CheckedContinuation<HTTPResponseHead, any Error>) {
        state.withLock { $0.headContinuation = continuation }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let head = HTTPResponseHead(
            status: URLSessionTransport.status(of: response),
            headers: URLSessionTransport.headers(of: response)
        )
        takeHeadContinuation()?.resume(returning: head)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        dataContinuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            let mapped = URLSessionTransport.mapError(error)
            takeHeadContinuation()?.resume(throwing: mapped)
            dataContinuation.finish(throwing: mapped)
        } else {
            takeHeadContinuation()?.resume(throwing: CloudreveAPIError.transport("响应在头部之前结束"))
            dataContinuation.finish()
        }
        session.finishTasksAndInvalidate()
    }

    /// 取出尚未使用的头部 continuation，保证只 resume 一次。
    private func takeHeadContinuation() -> CheckedContinuation<HTTPResponseHead, any Error>? {
        state.withLock { state in
            guard !state.headDelivered, let continuation = state.headContinuation else { return nil }
            state.headDelivered = true
            state.headContinuation = nil
            return continuation
        }
    }
}
