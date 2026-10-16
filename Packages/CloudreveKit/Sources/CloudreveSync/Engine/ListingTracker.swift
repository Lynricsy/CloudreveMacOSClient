import Foundation

/// 跨页累计一次目录枚举中出现过的子项 id，用于在末页计算删除差集。
actor ListingTracker {
    private var seen: [String: Set<String>] = [:]

    /// 首页重置；非首页但没有记录（扩展重启后从中间页继续）时不跟踪，末页将跳过删除差集。
    func record(folderID: String, ids: [String], isFirstPage: Bool) {
        if isFirstPage {
            seen[folderID] = Set(ids)
        } else if seen[folderID] != nil {
            seen[folderID]?.formUnion(ids)
        }
    }

    /// 结束本轮，返回累计的 id 集合；未跟踪时返回 nil。
    func finish(folderID: String) -> Set<String>? {
        seen.removeValue(forKey: folderID)
    }
}
