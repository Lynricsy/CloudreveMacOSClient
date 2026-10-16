import Foundation
import Testing
@testable import CloudreveAPI

@Suite struct StrategySelectorTests {
    private func pick(_ type: String, relay: Bool? = nil, urls: [String]? = nil) throws -> any ChunkStrategy {
        try StrategySelector.strategy(for: UploaderFixtures.session(type: type, chunkSize: 4, relay: relay, uploadURLs: urls), fileSize: 10)
    }

    @Test func localAndRelayUseLocal() throws {
        #expect(try pick("local") is LocalStrategy)
        #expect(try pick("s3", relay: true) is LocalStrategy)
        #expect(try pick("onedrive", relay: true) is LocalStrategy)
    }

    @Test func remoteDependsOnUploadURL() throws {
        #expect(try pick("remote", urls: ["https://slave.example.com/api/v4/slave/upload/s1"]) is RemoteStrategy)
        #expect(try pick("remote", urls: ["/api/v4/file/upload/s1"]) is LocalStrategy)
        #expect(try pick("remote", urls: [""]) is LocalStrategy)
        #expect(try pick("remote") is LocalStrategy)
    }

    @Test func storageVendors() throws {
        for variant in S3FamilyStrategy.Variant.allCases {
            #expect((try pick(variant.rawValue) as? S3FamilyStrategy)?.variant == variant)
        }
        #expect((try pick("onedrive") as? OneDriveStrategy)?.fileSize == 10)
        #expect(try pick("qiniu") is QiniuStrategy)
        #expect(try pick("upyun") is UpyunStrategy)
    }

    @Test func unknownTypeThrows() {
        #expect(throws: CloudreveAPIError.server(code: -1, message: "unsupported policy type", correlationID: nil)) {
            _ = try pick("ftp")
        }
    }
}
