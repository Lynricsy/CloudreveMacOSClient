import Foundation

/// 七牛策略：分片 PUT `{upload_urls[0]}/{N+1}`，合并时 POST 分片列表（七牛随后自行回调服务端）。
public struct QiniuStrategy: ChunkStrategy {
    public init() {}

    public func upload(chunk: UploadChunk, body: HTTPBody, session: UploadSession, client: CloudreveClient) async throws -> String? {
        let base = try StorageHTTP.uploadURL(session, index: 0).absoluteString
        let url = try StorageHTTP.url(base + "/\(chunk.index + 1)")
        let headers = ["Content-Type": StorageHTTP.octetStream, "Authorization": Self.authorization(session)]
        let response = try await StorageHTTP.send(HTTPRequest(method: "PUT", url: url, headers: headers, body: body), client: client)
        do {
            return try JSONDecoder().decode(QiniuChunkReply.self, from: response.body).etag
        } catch {
            throw CloudreveAPIError.decoding("七牛分片响应：\(error)")
        }
    }

    public func merge(session: UploadSession, etags: [Int: String], client: CloudreveClient) async throws {
        let url = try StorageHTTP.uploadURL(session, index: 0)
        let parts = etags.keys.sorted().map { QiniuPart(etag: etags[$0] ?? "", partNumber: $0 + 1) }
        let body = try JSONEncoder().encode(QiniuCompleteBody(parts: parts, mimeType: session.mimeType))
        let headers = ["Content-Type": "application/json", "Authorization": Self.authorization(session)]
        _ = try await StorageHTTP.send(HTTPRequest(method: "POST", url: url, headers: headers, body: .data(body)), client: client)
    }

    private static func authorization(_ session: UploadSession) -> String {
        "UpToken \(session.credential ?? "")"
    }
}

private struct QiniuChunkReply: Decodable {
    let etag: String
}

private struct QiniuPart: Encodable {
    let etag: String
    let partNumber: Int
}

private struct QiniuCompleteBody: Encodable {
    let parts: [QiniuPart]
    let mimeType: String?
}
