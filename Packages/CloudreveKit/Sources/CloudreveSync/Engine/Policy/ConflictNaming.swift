import Foundation

/// 冲突副本命名，与 Windows 版一致：`__conflict__{yyyyMMddHHmmss}_{原文件名}`。
public enum ConflictNaming {
    public static let prefix = "__conflict__"

    public static func conflictCopyName(for name: String, at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "\(prefix)\(formatter.string(from: date))_\(name)"
    }
}
