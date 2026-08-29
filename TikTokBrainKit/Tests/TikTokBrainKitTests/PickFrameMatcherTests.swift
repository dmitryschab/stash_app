// Which sampled frame shows which pick. The grouped OCR text is the only bridge between a
// product name and a moment in the video — FrameReader stamps every block with the frame it
// came from ("[3] BENQ SCREENBAR | €179"), and these tests pin how a pick's name finds its
// block, because a wrong match puts the wrong product's picture on the pick page.

import Foundation
import Testing
@testable import TikTokBrainKit

@Suite("Pick frame matching")
struct PickFrameMatcherTests {

    let haul = """
    [1] QUICK OFFICE TOUR | subscribe for more
    [4] LOGITECH MX MASTER 4 | 129 9€ | the best mouse i've owned
    [7] BENQ SCREENBAR HALO 2 | €179
    [9] SATECHI CUBEDOCK | with SSD enclosure | $39.9
    """

    @Test func aPickFindsTheFrameThatNamesIt() {
        #expect(PickFrames.frameIndex(for: "Logitech MX Master 4", in: haul) == 3)
        #expect(PickFrames.frameIndex(for: "BenQ ScreenBar Halo 2", in: haul) == 6)
    }

    @Test func markersAreFramePositionsNotBlockPositions() {
        // FrameReader drops duplicate frames, so the running block count drifts from the frame
        // number — "[9]" is the ninth sampled frame even when it is the fourth block.
        #expect(PickFrames.frameIndex(for: "Satechi CubeDock", in: haul) == 8)
    }

    @Test func aPickTheVideoNeverShowsMatchesNothing() {
        #expect(PickFrames.frameIndex(for: "Sony WH-1000XM6", in: haul) == nil)
    }

    @Test func halfANameIsNotAMatch() {
        // "Grovemade Standing Desk" against a frame that only says "standing desk setup" —
        // two generic words must not steal a brand's slot.
        let text = "[2] my standing desk setup | link below"
        #expect(PickFrames.frameIndex(for: "Grovemade Standing Desk", in: text) == nil)
    }

    @Test func caseAndPunctuationDoNotMatter() {
        let text = "[5] aesop® résurrection hand balm | worth it?"
        #expect(PickFrames.frameIndex(for: "Aesop Resurrection Hand Balm", in: text) == 4)
    }

    @Test func legacyUnmarkedTextMapsToNoFrame() {
        // OCR stored before FrameReader grouped by frame has no markers — there is nothing to
        // point a picture at, and pretending otherwise would show a random frame.
        #expect(PickFrames.frameIndex(for: "Logitech MX Master 4",
                                      in: "LOGITECH MX MASTER 4 129€ subscribe") == nil)
        #expect(PickFrames.frameIndex(for: "Logitech MX Master 4", in: nil) == nil)
    }

    @Test func theBestScoringFrameWinsATie() {
        let text = """
        [2] LOGITECH keyboard also great
        [5] LOGITECH MX MASTER 4 | in stores now
        """
        #expect(PickFrames.frameIndex(for: "Logitech MX Master 4", in: text) == 4)
    }
}
