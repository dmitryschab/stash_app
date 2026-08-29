import XCTest
@testable import TikTokBrainKit

final class SharedLinkResolverTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_785_000_000)

    private func link(_ suffix: String) -> URL {
        URL(string: "https://vm.tiktok.com/ZM\(suffix)/")!
    }

    private func bookmark(_ id: String) -> Bookmark {
        Bookmark(id: id, url: URL(string: "https://www.tiktok.com/@a/video/\(id)")!, date: when)
    }

    func testResolvedLinksKeepTheirSubmissionOrder() async {
        let links = [link("1"), link("2"), link("3")]
        let batch = await SharedLinkResolver.resolve(links) { url in
            self.bookmark(String(url.absoluteString.suffix(2).prefix(1)))
        }
        XCTAssertEqual(batch.bookmarks.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(batch.requeue, [])
        XCTAssertEqual(batch.rejected, [])
        XCTAssertNil(batch.rejectionMessage)
    }

    /// Two links, one video. Sharing the same TikTok twice — or once through vm.tiktok.com and
    /// once through the /t/ form — used to submit the id twice, which the box 422s as a whole
    /// import. Because a failed submission requeues its links, that was a trap the inbox could
    /// never climb out of: every retry added another copy.
    func testTheSameVideoSharedTwiceIsSubmittedOnce() async {
        let links = [link("short"), link("other")]
        let batch = await SharedLinkResolver.resolve(links) { _ in self.bookmark("7") }

        XCTAssertEqual(batch.bookmarks.map(\.id), ["7"])
        XCTAssertEqual(batch.requeue, [], "a duplicate is resolved, not held for another attempt")
        XCTAssertEqual(batch.rejected, [])
    }

    /// The failure that matters: a link the network could not reach is held, not lost. The
    /// inbox file has already been deleted by the time this runs, so a dropped link is gone.
    func testAnUnreachableLinkIsHeldForAnotherAttempt() async {
        let batch = await SharedLinkResolver.resolve([link("offline")]) { url in
            throw TikTokLink.Failure.unreachable(url.absoluteString)
        }
        XCTAssertEqual(batch.requeue, [link("offline")])
        XCTAssertEqual(batch.bookmarks, [])
        XCTAssertEqual(batch.rejected, [])
        XCTAssertNil(batch.rejectionMessage, "nothing to report — it will be tried again")
    }

    func testDeadAndNonTikTokLinksAreDroppedNotHeld() async {
        let dead = link("gone")
        let notTikTok = URL(string: "https://www.instagram.com/reel/abc/")!
        let batch = await SharedLinkResolver.resolve([dead, notTikTok]) { url in
            if url == notTikTok { throw TikTokLink.Failure.notTikTok(url.absoluteString) }
            throw TikTokLink.Failure.unresolved(url.absoluteString)
        }
        XCTAssertEqual(batch.requeue, [], "retrying a deleted video never succeeds")
        XCTAssertEqual(batch.rejected.count, 2)
        XCTAssertEqual(batch.rejectionMessage,
                       "Couldn't open that TikTok link. It may be private, deleted or "
                       + "region-locked. (2 shared links couldn't be opened)")
    }

    func testASingleRejectionReadsAsItsOwnSentence() async {
        let batch = await SharedLinkResolver.resolve([link("x")]) { url in
            throw TikTokLink.Failure.notTikTok(url.absoluteString)
        }
        XCTAssertEqual(batch.rejectionMessage,
                       "That link isn't a TikTok video — Stash can only save TikToks.")
    }

    /// An unrecognised error is not evidence the video is gone, so the link is held.
    func testAnUnknownErrorIsTreatedAsRetryable() async {
        let batch = await SharedLinkResolver.resolve([link("weird")]) { _ in
            throw URLError(.badServerResponse)
        }
        XCTAssertEqual(batch.requeue, [link("weird")])
        XCTAssertEqual(batch.rejected, [])
    }

    /// One bad link in a run of shares must not take the others down with it.
    func testAMixedBatchKeepsWhatResolved() async {
        let good = link("good")
        let dead = link("dead")
        let offline = link("offline")
        let batch = await SharedLinkResolver.resolve([good, dead, offline]) { url in
            switch url {
            case dead: throw TikTokLink.Failure.unresolved(url.absoluteString)
            case offline: throw TikTokLink.Failure.unreachable(url.absoluteString)
            default: return self.bookmark("7000000000000000001")
            }
        }
        XCTAssertEqual(batch.bookmarks.map(\.id), ["7000000000000000001"])
        XCTAssertEqual(batch.requeue, [offline])
        XCTAssertEqual(batch.rejected, [.unresolved(dead.absoluteString)])
    }
}
