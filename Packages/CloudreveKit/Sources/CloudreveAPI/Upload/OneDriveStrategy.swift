import Foundation

/// OneDrive 策略：分片 PUT 到 `upload_urls[0]` 并带 `Content-Range`，完成后回调服务端。
public struct OneDriveStrategy: ChunkStrategy {
    /// 文件总大小（`Content-Range` 需要）。
    public let fileSize: Int64

    public init(fileSize: Int64) {
        self.fileSize = fileSize
    }

    public func upload(chunk: UploadChunk, data: Data, session: UploadSession, client: CloudreveClient) async throws -> String? {
        let url = try StorageHTTP.uploadURL(session, index: 0)
        let end = chunk.offset + Int64(data.count) - 1
        let headers = [
            "Content-Type": StorageHTTP.octetStream,
            "Content-Range": "bytes \(chunk.offset)-\(end)/\(fileSize)"
        ]
        _ = try await StorageHTTP.send(HTTPRequest(method: "PUT", url: url, headers: headers, body: .data(data)), client: client)
        return nil
    }

    public func complete(session: UploadSession, etags: [Int: String], client: CloudreveClient) async throws {
        try await client.completeOneDriveCallback(sessionID: session.sessionID, secret: session.callbackSecret)
    }
}
