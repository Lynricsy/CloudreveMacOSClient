import Foundation

/// 上传分片：序号、文件内偏移与长度。
public struct UploadChunk: Sendable, Equatable {
    public var index: Int
    public var offset: Int64
    public var length: Int64

    public init(index: Int, offset: Int64, length: Int64) {
        self.index = index
        self.offset = offset
        self.length = length
    }
}
