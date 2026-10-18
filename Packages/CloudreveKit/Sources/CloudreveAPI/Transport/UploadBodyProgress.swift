/// 请求体发送进度：传输层从磁盘文件（`.file`）发送请求体时回报本请求已发送的字节数。
///
/// 上传器经 TaskLocal 传入，避免给每种存储策略的分片上传签名都加进度参数；
/// 未设置时传输层不回报。一个分片可能发出多个请求（如先取地址再 PUT），由上传器取最大值并按分片长度截断。
public enum UploadBodyProgress {
    @TaskLocal public static var handler: (@Sendable (_ totalBytesSent: Int64) -> Void)?
}
