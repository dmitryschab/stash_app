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

    func testActualZipThrows() throws {
        let zip = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).zip")
        try Data("PK\u{03}\u{04}".utf8).write(to: zip)
        defer { try? FileManager.default.removeItem(at: zip) }

        XCTAssertThrowsError(try ExportParser().parse(zipAt: zip)) { error in
            XCTAssertEqual(error as? CocoaError, CocoaError(.fileReadUnknown))
        }
    }
}
