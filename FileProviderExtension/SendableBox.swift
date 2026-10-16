import Foundation

/// 把 FileProvider 回调对象带入 Swift 并发任务。
///
/// 不变量（移除前提）：只用于包装以下线程安全对象——
/// - FileProvider 的 completionHandler：Apple 文档允许在任意线程调用，且我们保证每个只调用一次；
/// - NSFileProviderEnumerationObserver / NSFileProviderChangeObserver：可在任意线程回调；
/// - Progress、NSFileProviderManager：Foundation 文档声明线程安全。
/// SDK 尚未为这些类型/闭包标注 Sendable；若未来 SDK 标注后应删除本类型。
struct SendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
