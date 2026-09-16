import XCTest
@testable import TikTokBrainKit

/// Settings shows these counts on the buttons that start each backfill. When the count and the
/// backfill's own filter disagree, the button reads "(277)" and a tap does nothing at all.
final class BackfillQueueTests: XCTestCase {
    private func video(transcribe: StageState = .pending, ocr: StageState = .pending) -> Video {
        let video = Video(videoID: "7000000000000000999",
                          url: URL(string: "https://www.tiktok.com/@a/video/7000000000000000999")!,
                          bookmarkedAt: Date())
        let stages: [String: StageState] = [PipelineStage.transcribe.rawValue: transcribe,
                                            PipelineStage.ocr.rawValue: ocr]
        video.stageStatesJSON = try! JSONEncoder().encode(stages)
        return video
    }

    func testAnAlreadyTriedSilentVideoNeedsNoTranscript() {
        XCTAssertTrue(video().needsTranscript)
        XCTAssertFalse(video(transcribe: .done).needsTranscript)   // tried; no speech
        let transcribed = video(); transcribed.transcript = "hello"
        XCTAssertFalse(transcribed.needsTranscript)
        let gone = video(); gone.unavailable = true
        XCTAssertFalse(gone.needsTranscript)
    }

    func testAlreadyReadFramesNeedNoRead() {
        XCTAssertTrue(video().needsVisualRead)
        XCTAssertFalse(video(ocr: .done).needsVisualRead)          // read; nothing on screen
        let flat = video(ocr: .done); flat.ocrText = "old flat pool"
        XCTAssertTrue(flat.needsVisualRead)                         // pre-grouping read, redo
        let grouped = video(); grouped.ocrText = FrameReader.frameMarker + "1\nhello"
        XCTAssertFalse(grouped.needsVisualRead)
    }
}
