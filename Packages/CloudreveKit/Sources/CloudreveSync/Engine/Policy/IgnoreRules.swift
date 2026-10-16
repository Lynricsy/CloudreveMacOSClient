import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// 忽略规则：fnmatch 通配，仅匹配文件名（不含路径）。
public struct IgnoreRules: Sendable {
    /// 内置规则：Office 锁文件、临时文件、LibreOffice 锁、Finder 元数据。
    public static let defaults = ["~$*", "~*.tmp", ".~lock.*", ".DS_Store"]

    public let patterns: [String]

    /// `userPatterns` 中空行与 `#` 开头的行被忽略。
    public init(userPatterns: [String]) {
        let cleaned = userPatterns
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        patterns = Self.defaults + cleaned
    }

    public func matches(name: String) -> Bool {
        patterns.contains { fnmatch($0, name, 0) == 0 }
    }
}
