import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 基于 URLSession 的真实传输层。
public final class URLSessionTransport: HTTPTransport {
    private let configuration: URLSessionConfiguration
    private let session: URLSession

    public init(userAgentVersion: String = "0.1.0") {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        configuration.httpAdditionalHeaders = ["User-Agent": "cloudreve-macos/\(userAgentVersion)"]
        self.configuration = configuration
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = Self.makeURLRequest(request)
        do {
            switch request.body {
            case .none, .data:
                let (data, response) = try await session.data(for: urlRequest)
                return HTTPResponse(status: Self.status(of: response), headers: Self.headers(of: response), body: data)
            case .file(let fileURL):
                return try await upload(urlRequest, fromFile: fileURL)
            }
        } catch {
            throw Self.mapError(error)
        }
    }

    public func stream(_ request: HTTPRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, any Error>) {
        let (stream, dataContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let delegate = StreamingDelegate(dataContinuation: dataContinuation)
        let streamSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = streamSession.dataTask(with: Self.makeURLRequest(request))
        dataContinuation.onTermination = { _ in
            task.cancel()
            streamSession.finishTasksAndInvalidate()
        }
        let head = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponseHead, any Error>) in
                delegate.setHeadContinuation(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (head, stream)
    }

    private func upload(_ urlRequest: URLRequest, fromFile fileURL: URL) async throws -> HTTPResponse {
        let session = self.session
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, any Error>) in
                let task = session.uploadTask(with: urlRequest, fromFile: fileURL) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let response {
                        continuation.resume(returning: HTTPResponse(
                            status: Self.status(of: response), headers: Self.headers(of: response), body: data ?? Data()
                        ))
                    } else {
                        continuation.resume(throwing: CloudreveAPIError.transport("空响应"))
                    }
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    static func makeURLRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if case .data(let data) = request.body {
            urlRequest.httpBody = data
        }
        return urlRequest
    }

    static func status(of response: URLResponse) -> Int {
        (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    static func headers(of response: URLResponse) -> [String: String] {
        guard let http = response as? HTTPURLResponse else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            result[String(describing: key).lowercased()] = String(describing: value)
        }
        return result
    }

    /// URLError → CloudreveAPIError.transport；任务取消 → CancellationError。
    static func mapError(_ error: any Error) -> any Error {
        if error is CancellationError || error is CloudreveAPIError { return error }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            return CloudreveAPIError.transport(urlError.localizedDescription)
        }
        return CloudreveAPIError.transport(String(describing: error))
    }
}
