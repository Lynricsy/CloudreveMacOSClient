import SwiftUI

/// 单个传输任务；点击在 Finder 中定位文件。
struct TransferRowView: View {
    let row: TransferRow

    @Environment(DriveManager.self) private var driveManager

    var body: some View {
        Button {
            Task { await driveManager.reveal(row) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                TransferIcon(contentType: row.contentType, kind: row.kind, state: row.state)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    TransferDetail(row: row)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Text("在 Finder 中显示"))
    }
}
