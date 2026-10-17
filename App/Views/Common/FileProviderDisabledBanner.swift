import SwiftUI

/// 「文件提供程序」未启用提示：新添加的云盘默认未启用，启用前 Finder 无法访问其中的文件。
struct FileProviderDisabledBanner: View {
    @Environment(DriveManager.self) private var driveManager

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("需要启用文件提供程序")
                    .font(.callout.bold())
                Text("在「系统设置 → 通用 → 登录项与扩展」中找到「文件提供程序」，打开 Cloudreve，Finder 才能访问云盘。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开系统设置") { driveManager.openFileProviderSettings() }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
