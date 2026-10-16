import Foundation
import Testing
@testable import CloudreveAPI

@Suite struct UploadPlanTests {
    @Test func splitsIntoChunksWithShortTail() {
        #expect(UploadPlan.chunks(size: 10, chunkSize: 4) == [
            UploadChunk(index: 0, offset: 0, length: 4),
            UploadChunk(index: 1, offset: 4, length: 4),
            UploadChunk(index: 2, offset: 8, length: 2)
        ])
        #expect(UploadPlan.chunks(size: 8, chunkSize: 4).map(\.length) == [4, 4])
    }

    @Test func nonPositiveChunkSizeMeansSingleChunk() {
        #expect(UploadPlan.chunks(size: 10, chunkSize: 0) == [UploadChunk(index: 0, offset: 0, length: 10)])
        #expect(UploadPlan.chunks(size: 10, chunkSize: -1) == [UploadChunk(index: 0, offset: 0, length: 10)])
        #expect(UploadPlan.chunks(size: 3, chunkSize: 4) == [UploadChunk(index: 0, offset: 0, length: 3)])
    }
}
