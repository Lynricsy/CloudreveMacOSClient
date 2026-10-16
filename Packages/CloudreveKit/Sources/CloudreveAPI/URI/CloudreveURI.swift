import Foundation

/// `cloudreve://my/<path>` 形式的文件 URI。内部保存已解码的路径段。
public struct CloudreveURI: Hashable, Codable, Sendable, CustomStringConvertible {
    public let fs: String
    public let segments: [String]

    private static let scheme = "cloudreve://"
    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/")
        return set
    }()

    public init(fs: String = "my", segments: [String]) {
        self.fs = fs
        self.segments = segments.filter { !$0.isEmpty }
    }

    /// 解析 `cloudreve://my/a/b`；只支持 `my` 文件系统。
    public init?(string: String) {
        guard string.hasPrefix(Self.scheme) else { return nil }
        var rest = string.dropFirst(Self.scheme.count)
        if let queryStart = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            rest = rest[..<queryStart]
        }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let authority = parts.first, authority == "my" else { return nil }
        var decoded: [String] = []
        for part in parts.dropFirst() where !part.isEmpty {
            guard let segment = part.removingPercentEncoding else { return nil }
            decoded.append(segment)
        }
        self.init(fs: authority, segments: decoded)
    }

    /// 由 `/a/b` 形式的路径构造 `my` URI。
    public static func my(_ path: String) -> CloudreveURI {
        CloudreveURI(segments: path.split(separator: "/").map(String.init))
    }

    public var isRoot: Bool { segments.isEmpty }

    public func appending(_ name: String) -> CloudreveURI {
        CloudreveURI(fs: fs, segments: segments + [name])
    }

    public var parent: CloudreveURI? {
        guard !segments.isEmpty else { return nil }
        return CloudreveURI(fs: fs, segments: Array(segments.dropLast()))
    }

    public var lastPathComponent: String { segments.last ?? "" }

    public var description: String {
        guard !segments.isEmpty else { return Self.scheme + fs }
        let encoded = segments.map { $0.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? $0 }
        return Self.scheme + fs + "/" + encoded.joined(separator: "/")
    }

    /// 相对 `root` 的路径（`/b/c.txt`；根本身为 `/`）；不在 `root` 之下返回 nil。
    public func relativePath(under root: CloudreveURI) -> String? {
        guard fs == root.fs, segments.starts(with: root.segments) else { return nil }
        return "/" + segments.dropFirst(root.segments.count).joined(separator: "/")
    }

    /// 把相对路径（`/b/c.txt`）拼接到根之下。
    public static func join(root: CloudreveURI, relative: String) -> CloudreveURI {
        CloudreveURI(fs: root.fs, segments: root.segments + relative.split(separator: "/").map(String.init))
    }

    /// 是否为 `other` 本身或其后代。
    public func isDescendant(ofOrEqualTo other: CloudreveURI) -> Bool {
        fs == other.fs && segments.starts(with: other.segments)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let uri = CloudreveURI(string: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无效 URI：\(text)")
        }
        self = uri
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
