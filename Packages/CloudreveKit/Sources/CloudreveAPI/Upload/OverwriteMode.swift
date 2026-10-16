import Foundation

/// 上传目标的覆盖方式。
public enum OverwriteMode: Sendable, Equatable {
    /// 新建文件（目标不能已存在；会话请求不带 `entity_type`）。
    case create
    /// 为已有文件上传新版本；`previous` 为乐观锁 entity id。
    case version(previous: String?)
}
