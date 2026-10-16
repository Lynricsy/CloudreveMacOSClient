import CloudreveSync
import SwiftUI

/// 云盘状态在界面上的颜色与文字（颜色之外总配文字，避免只靠颜色传达信息）。
extension DriveStatus {
    var indicatorColor: Color {
        switch self {
        case .active: .green
        case .eventPushLost: .orange
        case .credentialExpired: .red
        }
    }

    var displayText: LocalizedStringResource {
        switch self {
        case .active: "已连接"
        case .eventPushLost: "推送中断，定期同步"
        case .credentialExpired: "需要重新登录"
        }
    }
}
