import XCTest
@testable import TikTokBrainKit

final class MusicPickResolverTests: XCTestCase {

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

    private func respond(_ json: String) {
        MusicLinkStubURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }
    }

    private func hit(track: String, collection: String, artist: String) -> String {
        """
        {"resultCount":1,"results":[{
          "trackName":"\(track)","collectionName":"\(collection)","artistName":"\(artist)",
          "trackViewUrl":"https://music.apple.com/us/album/x/1?i=2",
          "collectionViewUrl":"https://music.apple.com/us/album/x/1"
        }]}
        """
    }

    // MARK: - Query shape

    /// A "top 5 albums" video and a "top 5 songs" video need different iTunes entities. Getting
    /// this wrong links a whole album for a single song, or vice versa.
    func testKindDecidesWhichEntityIsSearched() async throws {
        let entities = RecordedEntities()
        MusicLinkStubURLProtocol.requestHandler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            entities.append(query?.first { $0.name == "entity" }?.value ?? "")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"resultCount":0,"results":[]}"#.utf8))
        }
        let resolver = MusicPickResolver(session: makeSession())
        _ = try await resolver.link(for: MusicPick(kind: .album, title: "Dreamcore, Vol. 1"))
        _ = try await resolver.link(for: MusicPick(kind: .track, title: "Atlantis"))
        // Preferred entity first, then the other: the model cannot reliably tell an album from
        // a single, so a miss on the stated kind is retried rather than given up on.
        XCTAssertEqual(entities.values, ["album", "song", "song", "album"])
    }

    /// An album pick links to the collection page, a track pick to the track page.
    func testAlbumAndTrackLinkToDifferentPages() async throws {
        respond(hit(track: "Atlantis", collection: "Atlantis", artist: "LTJ Bukem"))
        let resolver = MusicPickResolver(session: makeSession())

        let album = try await resolver.link(
            for: MusicPick(kind: .album, title: "Atlantis", artist: "LTJ Bukem"))
        XCTAssertEqual(album?.absoluteString,
                       "https://song.link/https%3A%2F%2Fmusic.apple.com%2Fus%2Falbum%2Fx%2F1")

        let track = try await resolver.link(
            for: MusicPick(kind: .track, title: "Atlantis", artist: "LTJ Bukem"))
        XCTAssertEqual(track?.absoluteString,
                       "https://song.link/https%3A%2F%2Fmusic.apple.com%2Fus%2Falbum%2Fx%2F1%3Fi%3D2")
    }

    // MARK: - The gate

    /// The whole point. iTunes answered, but not with this release, so there is no link.
    func testAnUnconvincingHitYieldsNoLinkRatherThanTheWrongOne() async throws {
        respond(hit(track: "Jungle Skeletons: Fire Various Selection, Vol. 1",
                    collection: "Jungle Skeletons: Fire Various Selection, Vol. 1",
                    artist: "Silent Monkz"))
        let resolver = MusicPickResolver(session: makeSession())
        let link = try await resolver.link(
            for: MusicPick(kind: .album, title: "jungle selection vol 1"))
        XCTAssertNil(link)
        XCTAssertEqual(MusicLinkStubURLProtocol.requestCount, 2,
                       "asked as an album, then as a track, and rejected both answers")
    }

    /// The gate scans past a bad first hit — which is why the search asks for five, not one.
    func testARightAnswerFurtherDownTheListIsStillFound() async throws {
        respond("""
        {"resultCount":2,"results":[
          {"trackName":"Polaris (Remix)","collectionName":"Some Compilation","artistName":"Nobody",
           "trackViewUrl":"https://music.apple.com/us/album/wrong/9?i=9",
           "collectionViewUrl":"https://music.apple.com/us/album/wrong/9"},
          {"trackName":"Polaris","collectionName":"Polaris","artistName":"KMC",
           "trackViewUrl":"https://music.apple.com/us/album/right/1?i=2",
           "collectionViewUrl":"https://music.apple.com/us/album/right/1"}
        ]}
        """)
        let resolver = MusicPickResolver(session: makeSession())
        let link = try await resolver.link(for: MusicPick(kind: .album, title: "Polaris", artist: "KMC"))
        XCTAssertEqual(link?.absoluteString,
                       "https://song.link/https%3A%2F%2Fmusic.apple.com%2Fus%2Falbum%2Fright%2F1")
    }

    // MARK: - Guards

    func testOriginalSoundIsNotSearchedFor() async throws {
        MusicLinkStubURLProtocol.requestHandler = { _ in
            XCTFail("no request should be issued for an original sound")
            throw URLError(.badURL)
        }
        let resolver = MusicPickResolver(session: makeSession())
        let link = try await resolver.link(for: MusicPick(kind: .track, title: "original sound - someone"))
        XCTAssertNil(link)
        XCTAssertEqual(MusicLinkStubURLProtocol.requestCount, 0)
    }

    func testAnEmptyTitleIsNotSearchedFor() async throws {
        MusicLinkStubURLProtocol.requestHandler = { _ in
            XCTFail("no request should be issued for an empty title")
            throw URLError(.badURL)
        }
        let resolver = MusicPickResolver(session: makeSession())
        let link = try await resolver.link(for: MusicPick(kind: .track, title: "   "))
        XCTAssertNil(link)
        XCTAssertEqual(MusicLinkStubURLProtocol.requestCount, 0)
    }

    func testNoResultsYieldsNoLink() async throws {
        respond(#"{"resultCount":0,"results":[]}"#)
        let resolver = MusicPickResolver(session: makeSession())
        let link = try await resolver.link(for: MusicPick(kind: .track, title: "Nothing Here"))
        XCTAssertNil(link)
    }

    // MARK: - Batch

    /// Resolving a list keeps every pick and its order, whether or not each one matched. A pick
    /// that could not be linked must survive as a name — dropping it silently loses a
    /// recommendation the video actually made.
    func testResolveKeepsEveryPickInOrderIncludingTheUnmatched() async {
        respond(hit(track: "Genesis", collection: "Genesis", artist: "Nedaj"))
        let resolver = MusicPickResolver(session: makeSession())
        let picks = [
            MusicPick(kind: .album, title: "Genesis", artist: "Nedaj"),
            MusicPick(kind: .album, title: "Totally Unrelated Record", artist: "Someone Else"),
            MusicPick(kind: .track, title: "Genesis", artist: "Nedaj"),
        ]
        let resolved = await resolver.resolve(picks)

        XCTAssertEqual(resolved.map(\.title),
                       ["Genesis", "Totally Unrelated Record", "Genesis"])
        XCTAssertNotNil(resolved[0].link)
        XCTAssertNil(resolved[1].link, "no confident match — the name stands alone")
        XCTAssertNotNil(resolved[2].link)
    }

    /// A network failure must not take the whole list down with it.
    func testATransportFailureLeavesThePickUnlinkedRatherThanThrowing() async {
        MusicLinkStubURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        let resolver = MusicPickResolver(session: makeSession())
        let resolved = await resolver.resolve([MusicPick(kind: .track, title: "Anything")])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertNil(resolved[0].link)
    }
}

// Shared by MusicPickResolverTests and AlbumResolverTests.
final class MusicLinkStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MusicLinkStubURLProtocol.requestCount += 1
        guard let handler = MusicLinkStubURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Collects what the stub saw. A plain `var` cannot be mutated from a `@Sendable` closure.
final class RecordedEntities: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ value: String) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
