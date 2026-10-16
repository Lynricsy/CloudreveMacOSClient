import Foundation

/// 所有网络访问的唯一出口。
public protocol HTTPTransport: Sendable {
    /// 发送请求并收齐响应体。
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    /// 发送请求并以分块流返回响应体（SSE、下载）。取消流的消费即取消请求。
    func stream(_ request: HTTPRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, any Error>)
}
