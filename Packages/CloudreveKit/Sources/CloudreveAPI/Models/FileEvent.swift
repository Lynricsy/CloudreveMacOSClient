import Foundation

/// SSE `event` 负载中的单个文件事件。`from`/`to` 为相对订阅根的路径（如 `/b/c.txt`）。
public struct FileEvent: Codable, Sendable, Equatable {
    public var type: FileEventType
    public var fileID: String
    public var from: String
    public var to: String?

    public init(type: FileEventType, fileID: String, from: String, to: String? = nil) {
        self.type = type
        self.fileID = fileID
        self.from = from
        self.to = to
    }

    enum CodingKeys: String, CodingKey {
        case type, from, to
        case fileID = "file_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(FileEventType.self, forKey: .type)
        fileID = try container.decode(String.self, forKey: .fileID)
        from = try container.decodeIfPresent(String.self, forKey: .from) ?? ""
        to = try container.decodeIfPresent(String.self, forKey: .to)
    }

    /// 负载可能是单个对象或数组；无法解析时返回空数组。
    public static func decodeList(_ data: Data) -> [FileEvent] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([FileEvent].self, from: data) { return list }
        if let single = try? decoder.decode(FileEvent.self, from: data) { return [single] }
        return []
    }
}

/// 文件事件类型。
public enum FileEventType: String, Codable, Sendable {
    case create, modify, rename, delete
}
