// What the TikTok sync wire promises the app: every state of POST /v1/tiktok/sync, and that the
// favourites a finished archive hands over become exactly the bookmarks an export of the same
// favourites would — so the import that follows dedupes them the same way.

import Foundation
import Testing
@testable import TikTokBrainKit

@Suite("TikTok sync decode")
struct TikTokSyncTests {

    private func sync(_ json: String) throws -> TikTokSyncResult {
        try TikTokConnectClient.decodeSync(Data(json.utf8))
    }

    /// The box's answer for a list of `(date, link)` pairs, as the extractor writes it.
    private func ready(_ favorites: [(String, String)]) -> String {
        let items = favorites.map { #"{"date": "\#($0.0)", "link": "\#($0.1)"}"# }
        return #"{"state": "ready", "favorites": [\#(items.joined(separator: ", "))]}"#
    }

    @Test func theShippedExportAndItsSyncAreTheSameBookmarks() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/export-user_data", withExtension: "json"))
        let exported = try ExportParser().parse(jsonData: Data(contentsOf: url))
        // The fixture's three favourites; its "Like List" item is not one, so the box never sends it.
        let synced = try sync(ready([
            ("2026-07-04 12:00:00", "https://www.tiktokv.com/share/video/7234567890123456789/"),
            ("2026-07-03 09:30:00", "https://www.tiktokv.com/share/video/7234567890123456789/"),
            ("2026-06-30 08:00:00", "https://www.tiktokv.com/share/video/7111111111111111111/"),
        ]))
        #expect(exported.count == 2)
        #expect(synced == .ready(exported))
    }

    /// The mapping's edges: lowercase keys, a link with no numeric id, a duplicate whose older
    /// copy comes second, and a date neither side can read.
    @Test func theEdgesMapTheSameWay() throws {
        let favorites = [
            ("2026-10-01 12:00:00", "https://www.tiktokv.com/share/video/7400000000000000001/"),
            ("2026-09-01 12:00:00", "https://www.tiktokv.com/share/video/7400000000000000001/"),
            ("2026-08-15 07:45:00", "https://vm.tiktok.com/ZMabcdef/"),
            ("not a date", "https://www.tiktokv.com/share/video/7400000000000000002/"),
        ]
        let rows = favorites.map { #"{"date": "\#($0.0)", "link": "\#($0.1)"}"# }
        let export = #"{"Likes and Favorites": {"Favorite Videos": {"FavoriteVideoList": [\#(rows.joined(separator: ", "))]}}}"#
        let exported = try ExportParser().parse(jsonData: Data(export.utf8))
        #expect(exported.map(\.id) == ["7400000000000000001", "https://vm.tiktok.com/ZMabcdef/"])
        #expect(try sync(ready(favorites)) == .ready(exported))
    }

    @Test func everyOtherStateDecodes() throws {
        #expect(try sync(#"{"state": "not_connected"}"#) == .notConnected)
        #expect(try sync(#"{"state": "not_enabled"}"#) == .notEnabled)
        #expect(try sync(#"{"state": "pending"}"#) == .pending)
        #expect(try sync(#"{"state": "requested"}"#) == .requested)
        #expect(try sync(#"{"state": "idle", "nextSyncAt": 1791417600}"#) == .idle(nextSyncAt: 1_791_417_600))
        #expect(try sync(#"{"state": "ready", "favorites": []}"#) == .ready([]))
    }

    @Test func anAnswerThisBuildCannotReadIsUnreachable() {
        #expect(throws: TikTokConnectError.unreachable) { try sync(#"{"state": "later"}"#) }
        #expect(throws: TikTokConnectError.unreachable) { try sync(#"{"state": "idle"}"#) }
        #expect(throws: TikTokConnectError.unreachable) { try sync("<html>bad gateway</html>") }
    }

    /// Every archive repeats the whole list, so a favourite already in the library must never
    /// be submitted — and charged — again; the budget then takes the newest of what is left.
    @Test func aSyncNeverResubmitsAVideoTheLibraryHas() throws {
        let synced = try sync(ready([
            ("2026-10-03 12:00:00", "https://www.tiktokv.com/share/video/7400000000000000003/"),
            ("2026-10-02 12:00:00", "https://www.tiktokv.com/share/video/7400000000000000002/"),
            ("2026-10-01 12:00:00", "https://www.tiktokv.com/share/video/7400000000000000001/"),
        ]))
        guard case .ready(let favorites) = synced else { Issue.record("not ready: \(synced)"); return }
        let library: Set<String> = ["7400000000000000002"]
        let ids = { (budget: Int) in
            TikTokSyncResult.toSubmit(favorites, libraryIDs: library, budget: budget).map(\.id)
        }
        #expect(ids(10) == ["7400000000000000003", "7400000000000000001"])
        #expect(ids(1) == ["7400000000000000003"])
        #expect(ids(0).isEmpty)
        #expect(TikTokSyncResult.toSubmit(favorites, libraryIDs: Set(favorites.map(\.id)), budget: 10).isEmpty)
    }

    @Test func meCarriesTheLastSyncWhenThereIsOne() throws {
        let synced = try JSONDecoder().decode(TikTokConnection.self, from: Data("""
            {"displayName": "dmitry", "connectedAt": 1791331200,
             "lastSyncAt": 1791417600, "lastSyncCount": 42}
            """.utf8))
        let never = try JSONDecoder().decode(TikTokConnection.self, from: Data("""
            {"displayName": "dmitry", "connectedAt": 1791331200, "lastSyncAt": null, "lastSyncCount": null}
            """.utf8))
        #expect(synced.lastSyncAt == 1_791_417_600 && synced.lastSyncCount == 42)
        #expect(never == TikTokConnection(displayName: "dmitry", connectedAt: 1_791_331_200))
    }
}
