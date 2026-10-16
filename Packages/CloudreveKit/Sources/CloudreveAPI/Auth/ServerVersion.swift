import Foundation

/// 服务端版本号（`/site/ping` 返回，如 `4.14.0` 或 `4.14.0-pro`）。
public struct ServerVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init(components: [Int]) {
        self.components = components
    }

    /// 去掉 `v` 前缀与 `-` 之后的后缀，按 `.` 数值解析。
    public static func parse(_ text: String) -> ServerVersion? {
        var core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if core.hasPrefix("v") { core.removeFirst() }
        if let dash = core.firstIndex(of: "-") { core = String(core[..<dash]) }
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return ServerVersion(components: parts.compactMap { $0 })
    }

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    /// 是否满足最低版本要求。
    public var isSupported: Bool {
        guard let minimum = ServerVersion.parse(OAuthConstants.minimumServerVersion) else { return false }
        return self >= minimum
    }
}
