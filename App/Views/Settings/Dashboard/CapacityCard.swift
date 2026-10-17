import SwiftUI

/// 占满宽度的容量卡片：大号已用量、百分比、粗进度条与剩余空间。
struct CapacityCard: View {
    let used: Int64
    let total: Int64
    let updatedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(used.formatted(.byteCount(style: .file)))
                    .font(.system(size: 28, weight: .bold))
                    .monospacedDigit()
                Text("/ \(total.formatted(.byteCount(style: .file)))")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Text(fraction.formatted(.percent.precision(.fractionLength(0...2))))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
                    .monospacedDigit()
            }
            CapacityBar(fraction: fraction)
                .frame(height: 10)
            HStack {
                Text("剩余 \(max(total - used, 0).formatted(.byteCount(style: .file)))")
                Spacer()
                if let updatedAt {
                    Text("更新于 \(updatedAt, format: .relative(presentation: .named))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quinary, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("存储空间"))
    }

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(Double(used) / Double(total), 1)
    }
}
