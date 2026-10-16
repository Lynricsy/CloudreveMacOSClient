import Foundation

/// 「添加云盘」窗口的打开参数；`reauthorizeDriveID` 非 nil 时为重新登录已有云盘。
struct AddDriveRequest: Codable, Hashable, Sendable {
    static let windowID = "add-drive"

    var reauthorizeDriveID: String?

    init(reauthorizeDriveID: String? = nil) {
        self.reauthorizeDriveID = reauthorizeDriveID
    }
}
