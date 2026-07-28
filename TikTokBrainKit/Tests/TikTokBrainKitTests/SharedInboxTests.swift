import XCTest
@testable import TikTokBrainKit

final class SharedInboxTests: XCTestCase {
    private var directory: URL!
    private var inbox: SharedInbox!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-inbox-\(UUID().uuidString)", isDirectory: true)
        inbox = SharedInbox(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWriteThenDrainReturnsTheLinkAndEmptiesTheDirectory() throws {
        let link = URL(string: "https://vm.tiktok.com/ZMabc123/")!
        try inbox.write(link)
        XCTAssertEqual(inbox.pendingCount, 1)

        XCTAssertEqual(inbox.drain(), [link])
        XCTAssertEqual(inbox.pendingCount, 0)
        XCTAssertEqual(inbox.drain(), [], "a drained inbox hands the same link over twice")
    }

    /// A run of shares has to reach the library in the order they were made, and the extension
    /// writes each one from a separate process launch.
    func testDrainReturnsLinksOldestFirst() throws {
        let links = (1...3).map { URL(string: "https://vm.tiktok.com/ZM\($0)/")! }
        for link in links {
            try inbox.write(link)
            // Creation dates have second resolution on some filesystems; space the writes so the
            // primary sort key is the one under test rather than the filename tiebreak.
            Thread.sleep(forTimeInterval: 1.05)
        }
        XCTAssertEqual(inbox.drain(), links)
    }

    /// A file that cannot be parsed is dropped rather than retried, otherwise every later share
    /// queues up behind a link that can never succeed.
    func testUnparseableFileIsDroppedNotRetried() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a url at all".utf8).write(
            to: directory.appendingPathComponent("broken.txt"))
        let good = URL(string: "https://www.tiktok.com/@a/video/7000000000000000001")!
        try inbox.write(good)

        XCTAssertEqual(inbox.drain(), [good])
        XCTAssertEqual(inbox.pendingCount, 0)
    }

    /// The failure path the app relies on: a submission that could not go through writes its
    /// links back, and they come out again on the next drain.
    func testLinksWrittenBackAfterAFailedSubmissionSurvive() throws {
        let link = URL(string: "https://vm.tiktok.com/ZMretry/")!
        try inbox.write(link)
        let drained = inbox.drain()

        for link in drained { try inbox.write(link) }
        XCTAssertEqual(inbox.drain(), [link])
    }

    func testDrainOnAMissingDirectoryIsEmptyRatherThanAnError() {
        XCTAssertEqual(inbox.drain(), [])
        XCTAssertEqual(inbox.pendingCount, 0)
    }
}
