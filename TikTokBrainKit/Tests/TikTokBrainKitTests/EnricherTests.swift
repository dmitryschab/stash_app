import XCTest
@testable import TikTokBrainKit

final class EnricherTests: XCTestCase {

    private func loadFixtureHTML() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/video-page", withExtension: "html"),
            "video-page.html fixture missing from test bundle"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParsesCaptionHashtagsAuthor() throws {
        let meta = try Enricher().parse(html: loadFixtureHTML())
        XCTAssertEqual(meta.caption, "POV: 15-minute miso ramen #recipe #ramen")
        XCTAssertEqual(meta.hashtags, ["recipe", "ramen"])
        XCTAssertEqual(meta.author, "noodleworship")
    }

    func testParsesSoundAndStream() throws {
        let meta = try Enricher().parse(html: loadFixtureHTML())
        XCTAssertEqual(meta.soundTitle, "original sound")
        XCTAssertEqual(meta.soundArtist, "noodleworship")
        XCTAssertEqual(meta.streamURL, URL(string: "https://v16.tiktokcdn.example/play/abc.mp4"))
        XCTAssertEqual(meta.thumbnailURL, URL(string: "https://p16.example/cover.jpg"))
    }

    func testMissingScriptTagThrows() {
        XCTAssertThrowsError(try Enricher().parse(html: "<html></html>")) { error in
            guard case BoxError.malformedPayload = error else {
                return XCTFail("Expected BoxError.malformedPayload, got \(error)")
            }
        }
    }
}
