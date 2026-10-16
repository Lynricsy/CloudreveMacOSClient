import Foundation

/// 又拍云策略：单次 multipart 表单 POST 到 `upload_urls[0]`，仅支持一块；无完成请求（由 Uploader 固定等待回调）。
public struct UpyunStrategy: ChunkStrategy {
    public init() {}

    public func upload(chunk: UploadChunk, data: Data, session: UploadSession, client: CloudreveClient) async throws -> String? {
        guard chunk.index == 0 else {
            throw CloudreveAPIError.server(code: -1, message: "又拍云仅支持单块上传", correlationID: nil)
        }
        let url = try StorageHTTP.uploadURL(session, index: 0)
        let boundary = "CloudreveBoundary\(UUID().uuidString)"
        var fields = [("policy", session.uploadPolicy ?? ""), ("authorization", session.credential ?? "")]
        if let mimeType = session.mimeType { fields.append(("content-type", mimeType)) }
        let body = Self.multipartBody(boundary: boundary, fields: fields, file: data)
        let headers = ["Content-Type": "multipart/form-data; boundary=\(boundary)"]
        _ = try await StorageHTTP.send(HTTPRequest(method: "POST", url: url, headers: headers, body: .data(body)), client: client)
        return nil
    }

    public func complete(session: UploadSession, etags: [Int: String], client: CloudreveClient) async throws {}

    /// 手工构造 `multipart/form-data`：文本字段在前，文件字段 `file`（filename `file`）在后。
    static func multipartBody(boundary: String, fields: [(String, String)], file: Data) -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"file\"\r\n".utf8))
        body.append(Data("Content-Type: \(StorageHTTP.octetStream)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
