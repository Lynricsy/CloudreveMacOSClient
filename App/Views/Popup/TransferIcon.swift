import AppKit
import CloudreveSync
import SwiftUI
import UniformTypeIdentifiers

/// 系统文件图标（32pt）+ 方向/结果角标。
struct TransferIcon: View {
    let contentType: UTType
    let kind: TransferKind
    let state: TransferState

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: contentType))
            .resizable()
            .frame(width: 32, height: 32)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: badgeSymbol)
                    .font(.system(size: 12))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, badgeColor)
                    .offset(x: 3, y: 3)
            }
            .accessibilityElement()
            .accessibilityLabel(Text(badgeLabel))
    }

    private var badgeSymbol: String {
        switch state {
        case .running: kind == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private var badgeColor: Color {
        switch state {
        case .running: .accentColor
        case .done: .green
        case .failed: .red
        }
    }

    private var badgeLabel: LocalizedStringResource {
        switch state {
        case .running: kind == .upload ? "正在上传" : "正在下载"
        case .done: kind == .upload ? "已上传" : "已下载"
        case .failed: "失败"
        }
    }
}
