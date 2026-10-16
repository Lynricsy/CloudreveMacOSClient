import Foundation

/// App 与 File Provider 扩展共享的 App Group 容器路径。
enum AppGroupPaths {
    static let groupID = "group.plus.ling.cloudreve"

    /// App Group 容器根目录。缺少 entitlement 属于配置错误，直接终止。
    static var containerURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            fatalError("无法访问 App Group 容器 \(groupID)：请检查 com.apple.security.application-groups entitlement")
        }
        return url
    }

    /// 共享 SQLite 数据库路径（目录不存在时自动创建）。
    static var databaseURL: URL {
        let directory = containerURL.appending(path: "Library", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "cloudreve.sqlite", directoryHint: .notDirectory)
    }
}
