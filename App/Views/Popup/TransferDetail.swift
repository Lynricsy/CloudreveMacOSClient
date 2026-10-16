import SwiftUI

/// 任务行第二部分：进行中显示进度与速度；已结束显示时间、父目录与错误。
struct TransferDetail: View {
    let row: TransferRow

    var body: some View {
        if row.state == .running {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(Self.bytes(row.doneBytes)) / \(Self.bytes(row.totalBytes)) · \(Self.bytes(Int64(row.bytesPerSecond)))/s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                ProgressView(value: row.fraction)
                    .controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let finishedAt = row.finishedAt {
                        Text("\(Text(finishedAt, style: .relative))前")
                    }
                    if let parentName = row.parentName {
                        Label(parentName, systemImage: "folder")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let error = row.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    private static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }
}
