import Foundation

/// 从机（remote）策略：分片直传从机 `upload_urls[0]?chunk=N`，Authorization 原样使用会话 credential。
public struct RemoteStrategy: ChunkStrategy {
    public init() {}

    public func upload(chunk: UploadChunk, data: Data, session: UploadSession, client: CloudreveClient) async throws -> String? {
        let base = session.uploadURLs?.first ?? ""
        let separator = base.contains("?") ? "&" : "?"
        let url = try StorageHTTP.url(base + separator + "chunk=\(chunk.index)")
        var headers = ["Content-Type": StorageHTTP.octetStream]
        if let credential = session.credential { headers["Authorization"] = credential }
        let response = try await StorageHTTP.send(
            HTTPRequest(method: "POST", url: url, headers: headers, body: .data(data)), client: client
        )
        // 从机返回 `{code, msg}`，code != 0 为错误；无法解析的响应体视为成功。
        if let reply = try? JSONDecoder().decode(NodeReply.self, from: response.body), reply.code != 0 {
            throw CloudreveAPIError.server(code: reply.code, message: reply.msg ?? "", correlationID: nil)
        }
        return nil
    }

    public func complete(session: UploadSession, etags: [Int: String], client: CloudreveClient) async throws {}
}

/// 从机响应。
private struct NodeReply: Decodable {
    let code: Int
    let msg: String?
}
