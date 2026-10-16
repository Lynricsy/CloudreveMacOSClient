import SwiftUI

/// 容量进度条与「已用 / 总量」文字。
struct DriveCapacityView: View {
    let used: Int64
    let total: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: Double(min(used, max(total, 1))), total: Double(max(total, 1)))
                .controlSize(.small)
            Text("\(used.formatted(.byteCount(style: .file))) / \(total.formatted(.byteCount(style: .file)))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: 260)
    }
}
