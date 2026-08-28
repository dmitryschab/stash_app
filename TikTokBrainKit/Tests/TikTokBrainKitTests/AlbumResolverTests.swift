import XCTest
@testable import TikTokBrainKit

final class AlbumResolverTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MusicLinkStubURLProtocol.requestHandler = nil
        MusicLinkStubURLProtocol.requestCount = 0
    }

    override func tearDown() {
        MusicLinkStubURLProtocol.requestHandler = nil
        MusicLinkStubURLProtocol.requestCount = 0
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MusicLinkStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func stub(_ json: String) {
        let data = Data(json.utf8)
        MusicLinkStubURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
    }

    /// Routes by host so one test can answer iTunes and Deezer differently.
    private func stubByHost(itunes: String, deezer: String) {
        MusicLinkStubURLProtocol.requestHandler = { request in
            let isDeezer = request.url?.host?.contains("deezer") == true
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data((isDeezer ? deezer : itunes).utf8))
        }
    }

    private static let deezerHit = #"""
    {"data": [{
        "id": 119606,
        "title": "The Money Store",
        "link": "https://www.deezer.com/album/119606",
        "cover_big": "https://cdn.deezer.com/images/cover/x/500x500.jpg",
        "nb_tracks": 13,
        "artist": {"name": "Death Grips"}
    }]}
    """#

    /// iTunes Search indexes the purchasable store, which is missing most streaming-only back
    /// catalogue — it found 5 of 12 sleeves on a real recommendation list where Deezer found
    /// all 12. A miss has to fall through rather than leave a hole in the wall.
    func testAnAlbumMissingFromITunesFallsBackToDeezer() async throws {
        stubByHost(itunes: #"{"resultCount": 0, "results": []}"#, deezer: Self.deezerHit)

        let ref = try await AlbumResolver(session: makeSession())
            .album(for: MusicPick(kind: .album, title: "The Money Store", artist: "Death Grips"))

        XCTAssertEqual(ref?.albumTitle, "The Money Store")
        XCTAssertEqual(ref?.artist, "Death Grips")
        XCTAssertEqual(ref?.artworkURL?.absoluteString,
                       "https://cdn.deezer.com/images/cover/x/500x500.jpg")
        // Negative marks "artwork only, no iTunes catalogue entry": it cannot collide with an
        // iTunes id, and it is what stops the album page asking iTunes for a tracklist.
        XCTAssertEqual(ref?.collectionID, -119606)
    }

    /// The same gate as iTunes. A sleeve for the wrong record is worse than no sleeve.
    func testDeezerFallbackStillRefusesAWrongRecord() async throws {
        stubByHost(itunes: #"{"resultCount": 0, "results": []}"#, deezer: Self.deezerHit)

        let ref = try await AlbumResolver(session: makeSession())
            .album(for: MusicPick(kind: .album, title: "Exmilitary", artist: "Neutral Milk Hotel"))

        XCTAssertNil(ref)
    }

    func testSearchResolvesAlbum() async throws {
        stub(#"""
        {"resultCount": 1, "results": [{
            "wrapperType": "track",
            "trackName": "The Less I Know the Better",
            "artistName": "Tame Impala",
            "collectionId": 1440838039,
            "collectionName": "Currents",
            "collectionViewUrl": "https://music.apple.com/us/album/currents/1440838039",
            "releaseDate": "2015-07-17T07:00:00Z",
            "trackCount": 13,
            "trackNumber": 7,
            "discNumber": 1
        }]}
        """#)

        let ref = try await AlbumResolver(session: makeSession())
            .album(title: "The Less I Know the Better", artist: "Tame Impala")

        XCTAssertEqual(ref?.collectionID, 1440838039)
        XCTAssertEqual(ref?.albumTitle, "Currents")
        XCTAssertEqual(ref?.year, 2015)
        XCTAssertEqual(ref?.trackCount, 13)
        XCTAssertEqual(ref?.trackNumber, 7)
        XCTAssertEqual(ref?.albumURL?.absoluteString, "https://music.apple.com/us/album/currents/1440838039")
    }

    /// An album pick asks the album index and is matched on the collection name, so the gate
    /// never compares "Rumours" against whatever song the song index offers first.
    func testAlbumPickResolvesByCollectionName() async throws {
        let data = Data(#"""
        {"resultCount": 1, "results": [{
            "wrapperType": "collection",
            "collectionType": "Album",
            "artistName": "Fleetwood Mac",
            "collectionId": 594061854,
            "collectionName": "Rumours",
            "collectionViewUrl": "https://music.apple.com/us/album/rumours/594061854",
            "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music/v4/ab/x.jpg/100x100bb.jpg",
            "releaseDate": "1977-02-04T08:00:00Z",
            "trackCount": 11
        }]}
        """#.utf8)
        let asked = AskedEntity()
        MusicLinkStubURLProtocol.requestHandler = { request in
            asked.value = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "entity" }?.value
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let ref = try await AlbumResolver(session: makeSession())
            .album(for: MusicPick(kind: .album, title: "Rumours", artist: "Fleetwood Mac"))

        XCTAssertEqual(asked.value, "album")
        XCTAssertEqual(ref?.collectionID, 594061854)
        XCTAssertEqual(ref?.albumTitle, "Rumours")
        XCTAssertEqual(ref?.trackCount, 11)
        XCTAssertEqual(ref?.artworkURL?.absoluteString,
                       "https://is1-ssl.mzstatic.com/image/thumb/Music/v4/ab/x.jpg/600x600bb.jpg")
    }

    /// A track pick takes the song path, so its album and track number still come back.
    func testTrackPickResolvesThroughTheSongIndex() async throws {
        let asked = AskedEntity()
        let data = Data(#"""
        {"resultCount": 1, "results": [{
            "wrapperType": "track", "trackName": "Dreams", "artistName": "Fleetwood Mac",
            "collectionId": 594061854, "collectionName": "Rumours", "trackCount": 11, "trackNumber": 2
        }]}
        """#.utf8)
        MusicLinkStubURLProtocol.requestHandler = { request in
            asked.value = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "entity" }?.value
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }

        let ref = try await AlbumResolver(session: makeSession())
            .album(for: MusicPick(kind: .track, title: "Dreams", artist: "Fleetwood Mac"))

        XCTAssertEqual(asked.value, "song")
        XCTAssertEqual(ref?.trackNumber, 2)
        XCTAssertEqual(ref?.albumTitle, "Rumours")
    }

    /// iTunes only offers the 100 px sleeve; the CDN serves the same path at any size.
    func testSearchUpscalesTheSleeve() async throws {
        stub(#"""
        {"resultCount": 1, "results": [{
            "wrapperType": "track",
            "trackName": "Midnight City",
            "artistName": "M83",
            "collectionId": 1440843425,
            "collectionName": "Hurry Up, We're Dreaming",
            "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/cb/x.jpg/100x100bb.jpg",
            "trackCount": 22
        }]}
        """#)

        let ref = try await AlbumResolver(session: makeSession())
            .album(title: "Midnight City", artist: "M83")

        XCTAssertEqual(ref?.artworkURL?.absoluteString,
                       "https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/cb/x.jpg/600x600bb.jpg")
    }

    /// A catalogue entry with no art must not become a broken sleeve.
    func testArtworkIsNilWhenITunesOffersNone() {
        XCTAssertNil(AlbumResolver.artwork(nil))
    }

    func testLookupOrdersTracklistAndSkipsCollection() async throws {
        stub(#"""
        {"resultCount": 4, "results": [
            {"wrapperType": "collection", "collectionName": "Currents"},
            {"wrapperType": "track", "trackName": "Eventually", "trackNumber": 5, "discNumber": 1},
            {"wrapperType": "track", "trackName": "Let It Happen", "trackNumber": 1, "discNumber": 1},
            {"wrapperType": "track", "trackName": "Nangs", "trackNumber": 2, "discNumber": 1}
        ]}
        """#)

        let names = try await AlbumResolver(session: makeSession()).tracklist(collectionID: 1440838039)

        XCTAssertEqual(names, ["Let It Happen", "Nangs", "Eventually"])
    }

    func testOriginalSoundSkipsNetwork() async throws {
        MusicLinkStubURLProtocol.requestHandler = { _ in
            XCTFail("no network request should be issued for an original sound")
            throw URLError(.badURL)
        }

        let ref = try await AlbumResolver(session: makeSession())
            .album(title: "original sound", artist: "someone")

        XCTAssertNil(ref)
        XCTAssertEqual(MusicLinkStubURLProtocol.requestCount, 0)
    }
}

/// Which iTunes entity a lookup asked for, captured from inside the Sendable stub handler.
private final class AskedEntity: @unchecked Sendable {
    var value: String?
}
