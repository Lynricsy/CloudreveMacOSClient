import Foundation

/// File Provider 域操作的错误。
enum DomainControllerError: LocalizedError, Sendable, Equatable {
    /// 系统中不存在该云盘对应的域。
    case domainNotFound(String)

    var errorDescription: String? {
        switch self {
        case .domainNotFound:
            String(localized: "系统中找不到该云盘的 Finder 位置，请尝试移除后重新添加")
        }
    }
}
