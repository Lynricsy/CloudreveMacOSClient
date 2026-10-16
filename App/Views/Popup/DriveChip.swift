import CloudreveSync
import SwiftUI

/// 筛选胶囊按钮；`status` 非 nil 时显示状态圆点。
struct DriveChip<Content: View>: View {
    let isSelected: Bool
    let status: DriveStatus?
    let action: () -> Void
    @ViewBuilder let label: () -> Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let status {
                    DriveStatusDot(status: status)
                }
                label()
                    .lineLimit(1)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
