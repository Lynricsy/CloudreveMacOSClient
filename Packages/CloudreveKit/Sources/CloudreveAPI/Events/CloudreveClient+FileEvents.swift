import Foundation

extension CloudreveClient {
    /// 订阅目录事件并解析为 SSE 事件流。
    /// 服务端可能以 JSON 信封拒绝订阅（推送关闭、凭证失效）：凭证失效码会 `recover` 后重试一次，
    /// 其他业务码抛 `.server`；非 200 抛 `.http`。
    public func fileEvents(uri: CloudreveURI) -> AsyncThrowingStream<SSEEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let chunks = try await openEventStream(uri: uri, retried: false)
                    var parser = SSEParser()
                    for try await chunk in chunks {
                        for event in parser.feed(chunk) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func openEventStream(uri: CloudreveURI, retried: Bool) async throws -> AsyncThrowingStream<Data, any Error> {
        guard let tokens else { throw CloudreveAPIError.credentialInvalid }
        let token = try await tokens.accessToken()
        let (head, chunks) = try await events(uri: uri)
        guard head.status == 200 else {
            throw CloudreveAPIError.http(status: head.status, body: try await Self.collect(chunks))
        }
        guard head.headers["content-type"]?.contains("application/json") == true else { return chunks }
        let body = try await Self.collect(chunks)
        let envelope = try? CloudreveDate.makeDecoder().decode(APIEnvelope<EmptyData>.self, from: Data(body.utf8))
        let code = envelope?.code ?? -1
        if CloudreveAPIError.credentialCodes.contains(code) {
            guard !retried else { throw CloudreveAPIError.credentialInvalid }
            _ = try await tokens.recover(afterUnauthorizedWith: token)
            return try await openEventStream(uri: uri, retried: true)
        }
        throw CloudreveAPIError.server(code: code, message: envelope?.msg ?? body, correlationID: envelope?.correlationID)
    }

    /// 收齐流为字符串（错误响应体）。
    static func collect(_ chunks: AsyncThrowingStream<Data, any Error>) async throws -> String {
        var data = Data()
        for try await chunk in chunks { data.append(chunk) }
        return String(decoding: data, as: UTF8.self)
    }
}
