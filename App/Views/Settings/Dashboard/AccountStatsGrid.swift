import CloudreveAPI
import SwiftUI

/// 三列指标网格：分享、回收站、同步、用户组、存储策略、服务端。`overview` 为 nil 时显示占位。
struct AccountStatsGrid: View {
    let drive: DriveSummary
    let overview: AccountOverview?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            StatTile(title: "分享", systemImage: "link", value: shareValue, detail: shareDetail)
            StatTile(title: "回收站", systemImage: "trash", value: trashValue, detail: trashDetail)
            StatTile(title: "完整核对", systemImage: "arrow.triangle.2.circlepath", value: reconcileValue, detail: "与服务端全量比对目录")
            StatTile(
                title: "用户组", systemImage: "person.crop.circle",
                value: overview?.user.group?.name ?? placeholder, detail: registeredDetail
            )
            StatTile(
                title: "存储策略", systemImage: "internaldrive",
                value: overview?.storagePolicy?.name ?? placeholder, detail: overview?.storagePolicy?.type ?? " "
            )
            StatTile(
                title: "服务端", systemImage: "server.rack",
                value: overview.map { "v\($0.serverVersion)" } ?? placeholder,
                detail: drive.siteTitle ?? drive.siteURL.host() ?? " "
            )
        }
    }

    private let placeholder = "—"

    private var shareValue: String {
        guard let shares = overview?.shares else { return placeholder }
        return Self.count(shares.count) + " 个"
    }

    private var shareDetail: String {
        guard let shares = overview?.shares else { return " " }
        var text = "共浏览 \(shares.visits.formatted()) 次"
        if shares.expired > 0 { text += " · \(shares.expired) 个已过期" }
        return text
    }

    private var trashValue: String {
        guard let trash = overview?.trash else { return placeholder }
        return Self.count(trash) + " 项"
    }

    private var trashDetail: String {
        guard let seconds = overview?.user.group?.trashRetention, seconds > 0 else { return " " }
        let duration = Duration.seconds(seconds)
        return "保留 \(duration.formatted(.units(allowed: [.days, .hours], width: .wide, maximumUnitCount: 1)))"
    }

    private var reconcileValue: String {
        guard let date = drive.lastReconcileAt else { return "尚未核对" }
        return date.formatted(.relative(presentation: .named))
    }

    private var registeredDetail: String {
        guard let date = overview?.user.createdAt else { return " " }
        return "注册于 \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    /// 截断的分页计数显示为「N+」。
    private static func count(_ value: PagedCount) -> String {
        value.count.formatted() + (value.isTruncated ? "+" : "")
    }
}
