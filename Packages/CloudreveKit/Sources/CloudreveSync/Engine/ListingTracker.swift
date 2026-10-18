import Foundation

/// 一次目录枚举（跨页）的累计状态。
struct ListingSession: Sendable {
    let folderID: String
    /// 开始列目录前的变更日志最新序号：之后由其他途径写入的子项不属于本轮删除差集。
    let startSeq: Int64
    /// 本轮各页出现过的子项 id。
    var seen: Set<String>
}

/// 按枚举会话（而非目录）跟踪分页，用于在末页计算删除差集。
///
/// 同一目录可能被系统枚举与 reconcile 等同时分页列出；按目录共用一个集合时，后开始的一轮会重置先开始那轮的累计，
/// 导致其末页把仍存在的子项当成已删除。会话 id 编进返回给调用方的分页令牌，各轮互不干扰。
actor ListingTracker {
    /// 同时保留的会话上限：系统中途放弃的枚举不会走到末页，超出时淘汰最早的会话（其末页将跳过删除差集）。
    static let capacity = 64

    private var sessions: [String: ListingSession] = [:]
    private var order: [String] = []

    /// 首页成功后开始新会话，返回会话 id。
    func start(folderID: String, startSeq: Int64, ids: [String]) -> String {
        let id = UUID().uuidString
        sessions[id] = ListingSession(folderID: folderID, startSeq: startSeq, seen: Set(ids))
        order.append(id)
        if order.count > Self.capacity {
            sessions[order.removeFirst()] = nil
        }
        return id
    }

    /// 累计后续页；会话未知（扩展重启或已淘汰）时不跟踪。
    func record(session: String, folderID: String, ids: [String]) {
        guard sessions[session]?.folderID == folderID else { return }
        sessions[session]?.seen.formUnion(ids)
    }

    /// 累计末页并结束会话，返回累计状态；未跟踪时返回 nil。
    func finish(session: String, folderID: String, ids: [String]) -> ListingSession? {
        guard sessions[session]?.folderID == folderID, var state = sessions.removeValue(forKey: session) else { return nil }
        order.removeAll { $0 == session }
        state.seen.formUnion(ids)
        return state
    }
}

/// 返回给调用方的分页令牌：`ck1:<会话 id>:<服务端令牌>`。
/// 不带前缀的令牌（升级前保存的或无会话的）原样作为服务端令牌使用，末页不做删除差集。
struct ListingPageToken: Equatable {
    private static let prefix = "ck1:"

    var session: String?
    var server: String

    init(session: String?, server: String) {
        self.session = session
        self.server = server
    }

    init(parsing token: String) {
        let rest = token.dropFirst(Self.prefix.count)
        if token.hasPrefix(Self.prefix), let separator = rest.firstIndex(of: ":") {
            session = String(rest[..<separator])
            server = String(rest[rest.index(after: separator)...])
        } else {
            session = nil
            server = token
        }
    }

    var encoded: String {
        guard let session else { return server }
        return Self.prefix + session + ":" + server
    }
}
