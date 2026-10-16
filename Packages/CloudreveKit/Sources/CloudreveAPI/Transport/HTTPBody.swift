import Foundation

/// 请求体：内存数据或磁盘文件（大文件上传避免整块读入内存）。
public enum HTTPBody: Sendable, Equatable {
    case none
    case data(Data)
    case file(URL)
}
