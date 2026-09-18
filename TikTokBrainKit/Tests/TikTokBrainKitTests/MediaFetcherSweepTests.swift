import Foundation
import Testing
@testable import TikTokBrainKit

@Suite("Interrupted reads") struct MediaFetcherSweepTests {
    @Test func sweepClearsWhatAKilledPassLeftBehind() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let work = tmp.appendingPathComponent("tiktokbrain-media", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let frame = work.appendingPathComponent("frame.png")
        let download = tmp.appendingPathComponent("stash-ocr-123.mp4")
        let unrelated = tmp.appendingPathComponent("stash-export.json")
        for file in [frame, download, unrelated] { try Data("x".utf8).write(to: file) }

        MediaFetcher.sweepInterruptedReads(in: tmp)

        #expect(!FileManager.default.fileExists(atPath: download.path))
        #expect(!FileManager.default.fileExists(atPath: work.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
