import Foundation

/// 添加云盘窗口的状态机：输入地址 → 检查服务器 → 浏览器授权 → 设置 → 成功 / 失败。
enum AddDriveStep: Equatable, Sendable {
    case enterURL
    case checking
    case authorizing
    case settingUp
    case success(driveID: String)
    case failed(String)
}
