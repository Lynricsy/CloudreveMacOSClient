import AppKit
import SwiftUI

/// 「关于」页：图标、版本、链接与许可。
struct AboutView: View {
    private static let website = URL(string: "https://cloudreve.org")
    private static let projectPage = URL(string: "https://github.com/cloudreve/cloudreve")

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(verbatim: "Cloudreve")
                .font(.title.bold())
            Text("版本 \(version)（\(build)）")
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                if let website = Self.website {
                    Link("Cloudreve 官网", destination: website)
                }
                if let projectPage = Self.projectPage {
                    Link("项目主页", destination: projectPage)
                }
            }
            Text("基于 MIT 许可证发布")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
