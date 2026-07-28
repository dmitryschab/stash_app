import XCTest
@testable import TikTokBrainKit

/// What the analyzer is allowed to send back, and what the app does with each shape.
final class MusicPickDecodingTests: XCTestCase {
    private func analysis(_ json: String) throws -> Analysis {
        try JSONDecoder().decode(Analysis.self, from: Data(json.utf8))
    }

    /// The shape this whole change exists to accept.
    func testAFiveReleaseListDecodesAsFivePicks() throws {
        let decoded = try analysis("""
        {"category":"music","title":"5 jungle projects","summary":"...","topics":["jungle"],
         "recipe":null,"code":null,
         "music":[
           {"kind":"album","title":"Dreamcore, Vol. 1","artist":"dreamstation"},
           {"kind":"album","title":"Atlantis (I Need You)","artist":"LTJ Bukem"},
           {"kind":"album","title":"Reflections / Secret Portraits","artist":"New Balance"},
           {"kind":"album","title":"Genesis","artist":""},
           {"kind":"album","title":"Polaris","artist":"KMC"}
         ]}
        """)
        XCTAssertEqual(decoded.music.count, 5)
        XCTAssertEqual(decoded.music.map(\.title).first, "Dreamcore, Vol. 1")
        XCTAssertEqual(decoded.music.last, MusicPick(kind: .album, title: "Polaris", artist: "KMC"))
        XCTAssertTrue(decoded.music.allSatisfy { $0.link == nil }, "links are resolved later")
    }

    func testANonMusicVideoDecodesToNoPicks() throws {
        let decoded = try analysis("""
        {"category":"recipe","title":"Miso ramen","summary":"...","topics":[],
         "recipe":{"name":"Miso Ramen","ingredients":[],"steps":[]},"music":[],"code":null}
        """)
        XCTAssertEqual(decoded.music, [])
    }

    /// A model that omits the key entirely must not fail the whole analysis.
    func testAMissingMusicKeyIsNotAnError() throws {
        let decoded = try analysis("""
        {"category":"comedy","title":"A skit","summary":"...","topics":[]}
        """)
        XCTAssertEqual(decoded.music, [])
        XCTAssertEqual(decoded.category, .comedy)
    }

    /// A response written against the old prompt still reads — the shape change cannot break
    /// an in-flight request, and a library saved before this change still shows its music.
    func testTheLegacySingleTrackKeyStillReads() throws {
        let decoded = try analysis("""
        {"category":"music","title":"A song","summary":"...","topics":[],
         "recipe":null,"code":null,
         "track":{"title":"Example Song","artist":"Example Artist",
                  "universalLink":"https://song.link/x"}}
        """)
        XCTAssertEqual(decoded.music, [MusicPick(kind: .track, title: "Example Song",
                                                 artist: "Example Artist",
                                                 link: URL(string: "https://song.link/x"))])
    }

    func testAnEmptyLegacyTrackDoesNotBecomeAPick() throws {
        let decoded = try analysis("""
        {"category":"music","title":"A song","summary":"...","topics":[],
         "track":{"title":"","artist":"","universalLink":null}}
        """)
        XCTAssertEqual(decoded.music, [])
    }

    /// Titleless entries are dropped rather than searched for — there is nothing to look up.
    func testEntriesWithNoTitleAreDropped() throws {
        let decoded = try analysis("""
        {"category":"music","title":"x","summary":"","topics":[],
         "music":[{"kind":"album","title":"  ","artist":"Someone"},
                  {"kind":"track","title":"Real One","artist":""}]}
        """)
        XCTAssertEqual(decoded.music.map(\.title), ["Real One"])
    }

    /// An unbounded array is an unbounded number of iTunes lookups.
    func testThePickListIsCapped() throws {
        let entries = (1...30).map { #"{"kind":"track","title":"Song \#($0)","artist":""}"# }
        let decoded = try analysis("""
        {"category":"music","title":"x","summary":"","topics":[],
         "music":[\(entries.joined(separator: ","))]}
        """)
        XCTAssertEqual(decoded.music.count, MusicPick.maxPerVideo)
        XCTAssertEqual(decoded.music.first?.title, "Song 1", "the cap keeps the earliest, in order")
    }

    /// A model inventing a kind must not fail the decode; a track is the narrower guess.
    func testAnUnknownKindFallsBackToTrack() throws {
        let decoded = try analysis("""
        {"category":"music","title":"x","summary":"","topics":[],
         "music":[{"kind":"mixtape","title":"Something","artist":""}]}
        """)
        XCTAssertEqual(decoded.music.first?.kind, .track)
    }

    /// Encoding never writes the retired key back out.
    func testEncodingEmitsMusicAndNeverTrack() throws {
        let source = Analysis(category: .music, title: "x", summary: "", topics: [],
                              music: [MusicPick(kind: .album, title: "Polaris", artist: "KMC")])
        let json = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        XCTAssertTrue(json.contains("\"music\""))
        XCTAssertFalse(json.contains("\"track\""))
    }
}
