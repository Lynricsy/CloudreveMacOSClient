import CloudreveSync
import SwiftUI

/// 云盘状态圆点；颜色之外通过 help 与无障碍标签提供文字。
struct DriveStatusDot: View {
    let status: DriveStatus

    var body: some View {
        Circle()
            .fill(status.indicatorColor)
            .frame(width: 8, height: 8)
            .help(Text(status.displayText))
            .accessibilityLabel(Text(status.displayText))
    }
}
