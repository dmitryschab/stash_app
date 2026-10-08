// What the TikTok connect wire promises the app: the connect route's answer, and the same object
// riding on /v1/me — where it may be absent (a server older than P1) or null (not connected),
// and neither may fail the rest of the payload.

import Foundation
import Testing
@testable import TikTokBrainKit

@Suite("TikTok connection decode")
struct TikTokConnectionTests {

    /// The app's `MeResponse` is private to StashSession; this is its shape, cut to the field
    /// the test is about plus one it must not cost.
    private struct Me: Decodable {
        let userID: String
        let tiktok: TikTokConnection?
    }

    @Test func theConnectAnswerDecodes() throws {
        let connection = try JSONDecoder().decode(
            TikTokConnection.self,
            from: Data(#"{"displayName": "dmitry", "connectedAt": 1791331200}"#.utf8))
        #expect(connection == TikTokConnection(displayName: "dmitry", connectedAt: 1_791_331_200))
    }

    @Test func meCarriesTheConnectionWhenThereIsOne() throws {
        let me = try JSONDecoder().decode(Me.self, from: Data("""
            {"userID": "u-1", "quota": null,
             "tiktok": {"displayName": "dmitry", "connectedAt": 1791331200}}
            """.utf8))
        #expect(me.tiktok?.displayName == "dmitry")
        #expect(me.tiktok?.connectedAt == 1_791_331_200)
    }

    @Test func meWithoutTheKeyOrWithNullStillDecodes() throws {
        let older = try JSONDecoder().decode(Me.self, from: Data(#"{"userID": "u-1"}"#.utf8))
        let disconnected = try JSONDecoder().decode(
            Me.self, from: Data(#"{"userID": "u-1", "tiktok": null}"#.utf8))
        #expect(older.userID == "u-1" && older.tiktok == nil)
        #expect(disconnected.userID == "u-1" && disconnected.tiktok == nil)
    }

    /// The EEA and the UK, as the box's `ALLOWED_STOREFRONTS` has them.
    @Test func theAllowedStorefrontsAreTheEEAAndTheUK() {
        let allowed = TikTokConnectClient.allowedStorefronts
        #expect(allowed.count == 31)
        #expect(allowed.isSuperset(of: ["LVA", "NLD", "GBR", "NOR"]))
        #expect(allowed.isDisjoint(with: ["USA", "CHE"]))
    }
}
