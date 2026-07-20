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
