import CloudreveSync
import SwiftUI

/// 编辑云盘的用户忽略规则（一行一个，仅匹配文件名）。
struct IgnorePatternsEditor: View {
    let drive: DriveSummary

    @Environment(DriveManager.self) private var driveManager
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("忽略规则：\(drive.name)")
                .font(.headline)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 180)
                .border(.separator)
            Text("一行一个规则，仅匹配文件名，支持 * 和 ?；以 # 开头的行为注释。默认规则：\(Self.defaultRulesText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    driveManager.updateIgnorePatterns(id: drive.id, Self.patterns(from: text))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { text = drive.ignorePatterns.joined(separator: "\n") }
    }

    /// 按行拆分并去掉首尾空白与空行。
    static func patterns(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static let defaultRulesText = IgnoreRules.defaults.joined(separator: "、")
}
