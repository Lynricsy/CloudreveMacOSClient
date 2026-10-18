import Foundation

/// 又拍云策略：单次 multipart 表单 POST 到 `upload_urls[0]`，仅支持一块；无完成请求（由 Uploader 固定等待回调）。
public struct UpyunStrategy: ChunkStrategy {
    public init() {}

    public func upload(chunk: UploadChunk, body: HTTPBody, session: UploadSession, client: CloudreveClient) async throws -> String? {
        guard chunk.index == 0 else {
            throw CloudreveAPIError.server(code: -1, message: "又拍云仅支持单块上传", correlationID: nil)
        }
        let url = try StorageHTTP.uploadURL(session, index: 0)
        let boundary = "CloudreveBoundary\(UUID().uuidString)"
        var fields = [("policy", session.uploadPolicy ?? ""), ("authorization", session.credential ?? "")]
        if let mimeType = session.mimeType { fields.append(("content-type", mimeType)) }
        let multipart = FileManager.default.temporaryDirectory.appendingPathComponent("upyun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: multipart) }
        try Self.writeMultipart(to: multipart, boundary: boundary, fields: fields, file: body)
        let headers = ["Content-Type": "multipart/form-data; boundary=\(boundary)"]
        _ = try await StorageHTTP.send(HTTPRequest(method: "POST", url: url, headers: headers, body: .file(multipart)), client: client)
        return nil
    }

    /// 在磁盘上构造 `multipart/form-data`（文件内容流式复制，不整体读入内存）：
    /// 文本字段在前，文件字段 `file`（filename `file`）在后。
    static func writeMultipart(to destination: URL, boundary: String, fields: [(String, String)], file: HTTPBody) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var head = ""
        for (name, value) in fields {
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"file\"\r\n"
        head += "Content-Type: \(StorageHTTP.octetStream)\r\n\r\n"
        try output.write(contentsOf: Data(head.utf8))
        switch file {
        case .none: break
        case .data(let data): try output.write(contentsOf: data)
        case .file(let source): try ChunkStaging.copyAll(from: source, to: output)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }
}
