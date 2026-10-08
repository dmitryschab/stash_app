import XCTest
@testable import TikTokBrainKit

final class ExportParserTests: XCTestCase {

    private func utcDate(_ string: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: string)!
    }

    private func fixtureData() throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/export-user_data", withExtension: "json")!
        return try Data(contentsOf: url)
    }

    private func zipFixture(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "zip")!
    }

    func testParsesFavoritesOnly() throws {
        let url = Bundle.module.url(forResource: "Fixtures/export-user_data", withExtension: "json")!
        let bookmarks = try ExportParser().parse(jsonData: Data(contentsOf: url))
        XCTAssertEqual(bookmarks.count, 2)
        XCTAssertFalse(bookmarks.contains { $0.url.absoluteString.contains("should-not-appear") })
    }

    func testDedupKeepsNewest() throws {
        let bookmarks = try ExportParser().parse(jsonData: fixtureData())
        let match = bookmarks.first { $0.id == "7234567890123456789" }
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.date, utcDate("2026-07-04 12:00:00"))
    }

    func testVideoIDParsing() throws {
        let bookmarks = try ExportParser().parse(jsonData: fixtureData())
        let ids = Set(bookmarks.map { $0.id })
        XCTAssertEqual(ids, ["7234567890123456789", "7111111111111111111"])
    }

    func testParsesFromDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try fixtureData().write(to: dir.appendingPathComponent("user_data.json"))

        let bookmarks = try ExportParser().parse(zipAt: dir)
        XCTAssertEqual(bookmarks.count, 2)
    }

    func testParsesDeflatedZip() throws {
        let bookmarks = try ExportParser().parse(zipAt: zipFixture("export-deflated"))
        XCTAssertEqual(bookmarks, try ExportParser().parse(jsonData: fixtureData()))
    }

    func testParsesStoredZip() throws {
        let bookmarks = try ExportParser().parse(zipAt: zipFixture("export-stored"))
        XCTAssertEqual(bookmarks, try ExportParser().parse(jsonData: fixtureData()))
    }

    func testTxtOnlyZipYieldsNoBookmarks() throws {
        XCTAssertEqual(try ExportParser().parse(zipAt: zipFixture("export-txt")), [])
    }

    func testMacRezippedZipSkipsAppleDoubleMembers() throws {
        let bookmarks = try ExportParser().parse(zipAt: zipFixture("export-mac-rezipped"))
        XCTAssertEqual(bookmarks, try ExportParser().parse(jsonData: fixtureData()))
    }

    /// A central directory can promise any size it likes; believing a 4 GB one would allocate it.
    func testOversizedMemberThrows() throws {
        var archive = try Data(contentsOf: zipFixture("export-deflated"))
        let central = try XCTUnwrap(archive.range(of: Data([0x50, 0x4B, 0x01, 0x02])))
        let size = (central.lowerBound + 24)..<(central.lowerBound + 28)
        archive.replaceSubrange(size, with: Data([0xFE, 0xFF, 0xFF, 0xFF]))  // 0xFFFF_FFFE
        let zip = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).zip")
        try archive.write(to: zip)
        defer { try? FileManager.default.removeItem(at: zip) }

        XCTAssertThrowsError(try ExportParser().parse(zipAt: zip)) { error in
            XCTAssertEqual(error as? CocoaError, CocoaError(.fileReadCorruptFile))
        }
    }

    // MARK: - Instagram

    private func instagramFixture(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")!
    }

    /// Reels only, newest save per reel, canonical `/reel/<code>/` links the box accepts.
    func testInstagramSavedPostsKeepReelsOnly() throws {
        let bookmarks = try ExportParser().parse(zipAt: instagramFixture("instagram-saved_posts"))
        XCTAssertEqual(bookmarks, [
            Bookmark(id: "C8abcDEF12", url: URL(string: "https://www.instagram.com/reel/C8abcDEF12/")!,
                     date: Date(timeIntervalSince1970: 1717243200)),
            Bookmark(id: "C2olderREEL", url: URL(string: "https://www.instagram.com/reel/C2olderREEL/")!,
                     date: Date(timeIntervalSince1970: 1559390400)),
        ])
    }

    func testInstagramOlderLayout() throws {
        let bookmarks = try ExportParser().parse(zipAt: instagramFixture("instagram-saved_posts-older"))
        XCTAssertEqual(bookmarks.map(\.id), ["OLDreel123"])
    }

    /// The zip as Meta hands it over: saved_posts.json nested two folders down, beside other
    /// activity files in the same shape that are not saves.
    func testInstagramZipReadsSavesNotLikes() throws {
        let bookmarks = try ExportParser().parse(zipAt: zipFixture("instagram-export"))
        XCTAssertEqual(Set(bookmarks.map(\.id)), ["C8abcDEF12", "C2olderREEL"])
    }

    func testGarbageZipThrows() throws {
        let zip = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).zip")
        try Data([0x9F, 0x2C, 0x04, 0xE1]).write(to: zip)
        defer { try? FileManager.default.removeItem(at: zip) }

        XCTAssertThrowsError(try ExportParser().parse(zipAt: zip)) { error in
            XCTAssertEqual(error as? CocoaError, CocoaError(.fileReadCorruptFile))
        }
    }
}
