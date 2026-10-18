import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 把 URLSessionDataDelegate 回调转换为「头部 continuation + 数据流」。
/// Linux 上没有 `URLSession.bytes(for:)`，所以统一走 delegate。
///
/// 头部结果可能先于 continuation 注册到达（例如任务在注册前已被取消，URLSession 仍会回调完成），
/// 此时先保存结果，注册时立即 resume，避免调用方永久挂起。
final class StreamingDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var headContinuation: CheckedContinuation<HTTPResponseHead, any Error>?
        /// 尚无 continuation 时到达的头部结果。
        var earlyResult: Result<HTTPResponseHead, any Error>?
        var headDelivered = false
    }

    private let state = Mutex(State())
    private let dataContinuation: AsyncThrowingStream<Data, any Error>.Continuation

    init(dataContinuation: AsyncThrowingStream<Data, any Error>.Continuation) {
        self.dataContinuation = dataContinuation
    }

    func setHeadContinuation(_ continuation: CheckedContinuation<HTTPResponseHead, any Error>) {
        let early = state.withLock { state -> Result<HTTPResponseHead, any Error>? in
            guard let result = state.earlyResult else {
                state.headContinuation = continuation
                return nil
            }
            state.earlyResult = nil
            state.headDelivered = true
            return result
        }
        if let early { continuation.resume(with: early) }
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
        deliverHead(.success(head))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        dataContinuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            let mapped = URLSessionTransport.mapError(error)
            deliverHead(.failure(mapped))
            dataContinuation.finish(throwing: mapped)
        } else {
            deliverHead(.failure(CloudreveAPIError.transport("响应在头部之前结束")))
            dataContinuation.finish()
        }
        session.finishTasksAndInvalidate()
    }

    /// 头部结果只交付一次：已注册 continuation 则 resume，否则保存待注册时交付。
    private func deliverHead(_ result: Result<HTTPResponseHead, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<HTTPResponseHead, any Error>? in
            guard !state.headDelivered else { return nil }
            guard let continuation = state.headContinuation else {
                if state.earlyResult == nil { state.earlyResult = result }
                return nil
            }
            state.headDelivered = true
            state.headContinuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
