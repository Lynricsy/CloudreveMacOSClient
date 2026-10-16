import Foundation

/// 直传存储的公共工具：发送外部请求、解析上传地址、提取 etag。
enum StorageHTTP {
    static let octetStream = "application/octet-stream"

    /// 透传外部请求；非 2xx → `.http`。
    static func send(_ request: HTTPRequest, client: CloudreveClient) async throws -> HTTPResponse {
        let response = try await client.send(external: request)
        guard (200..<300).contains(response.status) else {
            throw CloudreveAPIError.http(status: response.status, body: String(decoding: response.body, as: UTF8.self))
        }
        return response
    }

    /// 会话中第 `index` 个上传地址。
    static func uploadURL(_ session: UploadSession, index: Int) throws -> URL {
        guard let urls = session.uploadURLs, urls.indices.contains(index) else {
            throw CloudreveAPIError.decoding("上传会话缺少第 \(index) 个上传地址")
        }
        return try url(urls[index])
    }

    /// 解析绝对地址。
    static func url(_ text: String?) throws -> URL {
        guard let text, !text.isEmpty, let url = URL(string: text) else {
            throw CloudreveAPIError.decoding("无效的存储地址：\(text ?? "nil")")
        }
        return url
    }

    /// 响应头 `etag`，去掉两侧引号。
    static func etag(_ response: HTTPResponse) -> String? {
        guard let raw = response.headers["etag"] else { return nil }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}
