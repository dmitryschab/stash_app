import XCTest
@testable import TikTokBrainKit

final class MusicLinkResolverTests: XCTestCase {

    private let appleURL = "https://music.apple.com/us/album/example/123?i=456"
    private let songLinkURL =
        "https://song.link/https%3A%2F%2Fmusic.apple.com%2Fus%2Falbum%2Fexample%2F123%3Fi%3D456"

    override func setUp() {
        super.setUp()
        MusicLinkStubURLProtocol.reset()
    }

    override func tearDown() {
        MusicLinkStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MusicLinkStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeBox() -> BoxConfig {
        BoxConfig(baseURL: URL(string: "http://box.test/v1")!,
                  chatModel: "m", whisperModel: "w", apiKey: "secret")
    }

    private func itunesFixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/itunes-search", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    /// Routes by host so each source can be stubbed — or omitted — independently.
    private func stub(itunes: Data?, odesli: Data? = nil, spotify: Data? = nil) {
        MusicLinkStubURLProtocol.requestHandler = { request in
            let host = request.url?.host ?? ""
            let body: Data?
            switch host {
            case "itunes.apple.com": body = itunes
            case "api.song.link": body = odesli
            case "box.test": body = spotify
            default: body = nil
            }
            guard let body else {
                let response = HTTPURLResponse(url: request.url!, statusCode: 500,
                                               httpVersion: nil, headerFields: nil)!
                return (response, Data("{}".utf8))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
    }

    private func odesliBody(spotify: Bool) -> Data {
        var platforms = #""tidal": {"url": "https://listen.tidal.com/track/999"}"#
        if spotify {
            platforms += #", "spotify": {"url": "https://open.spotify.com/track/odesli"}"#
        }
        // Odesli's own Apple entry carries its affiliate tag — the resolver must ignore it.
        platforms += #", "appleMusic": {"url": "https://geo.music.apple.com/us/album/_/123?at=affiliate"}"#
        return Data(#"{"pageUrl": "https://song.link/us/i/456", "linksByPlatform": {\#(platforms)}}"#.utf8)
    }

    // MARK: - The happy path: three services from three sources

    func testResolvesAppleFromITunesTidalFromOdesliSpotifyFromBox() async throws {
        stub(itunes: try itunesFixture(),
             odesli: odesliBody(spotify: false),
             spotify: Data(#"{"url": "https://open.spotify.com/track/abc", "album": null}"#.utf8))

        let resolver = MusicLinkResolver(session: makeSession(), box: makeBox())
        let result = try await resolver.resolve(title: "Example Song", artist: "Example Artist")

        XCTAssertEqual(result.links.map(\.service), [.appleMusic, .spotify, .tidal])
        // Apple comes from iTunes, not Odesli's affiliate-tagged link.
        XCTAssertEqual(result.links[0].url.absoluteString, appleURL)
        XCTAssertEqual(result.links[1].url.absoluteString, "https://open.spotify.com/track/abc")
        XCTAssertEqual(result.links[2].url.absoluteString, "https://listen.tidal.com/track/999")
        XCTAssertEqual(result.universalLink?.absoluteString, "https://song.link/us/i/456")
    }

    func testBoxIsNotCalledWhenOdesliAlreadyHasSpotify() async throws {
        stub(itunes: try itunesFixture(), odesli: odesliBody(spotify: true))

        let resolver = MusicLinkResolver(session: makeSession(), box: makeBox())
        let result = try await resolver.resolve(title: "Example Song", artist: "Example Artist")

        XCTAssertEqual(result.links.first(where: { $0.service == .spotify })?.url.absoluteString,
                       "https://open.spotify.com/track/odesli")
        XCTAssertFalse(MusicLinkStubURLProtocol.requestedHosts.contains("box.test"))
    }

    func testBoxTokenIsSentAsBearer() async throws {
        stub(itunes: try itunesFixture(),
             odesli: odesliBody(spotify: false),
             spotify: Data(#"{"url": "https://open.spotify.com/track/abc"}"#.utf8))

        let resolver = MusicLinkResolver(session: makeSession(), box: makeBox())
        _ = try await resolver.resolve(title: "Example Song", artist: "Example Artist")

        let auth = MusicLinkStubURLProtocol.headers(forHost: "box.test")?["Authorization"]
        XCTAssertEqual(auth, "Bearer secret")
    }

    // MARK: - Degradation

    func testOdesliFailureStillYieldsAppleMusicAndSongLinkFallback() async throws {
        stub(itunes: try itunesFixture())  // odesli + box both 500

        let resolver = MusicLinkResolver(session: makeSession(), box: makeBox())
        let result = try await resolver.resolve(title: "Example Song", artist: "Example Artist")

        XCTAssertEqual(result.links.map(\.service), [.appleMusic])
        // No Odesli page URL, so the resolver builds the song.link wrapper itself.
        XCTAssertEqual(result.universalLink?.absoluteString, songLinkURL)
    }

    func testNoBoxConfiguredMeansNoSpotify() async throws {
        stub(itunes: try itunesFixture(), odesli: odesliBody(spotify: false))

        let resolver = MusicLinkResolver(session: makeSession())  // box: nil
        let result = try await resolver.resolve(title: "Example Song", artist: "Example Artist")

        XCTAssertEqual(result.links.map(\.service), [.appleMusic, .tidal])
        XCTAssertFalse(MusicLinkStubURLProtocol.requestedHosts.contains("box.test"))
    }

    // MARK: - Nothing to resolve

    func testOriginalSoundResolvesToNothing() async throws {
        MusicLinkStubURLProtocol.requestHandler = { _ in
            XCTFail("no network request should be issued for an original sound")
            throw URLError(.badURL)
        }

        let resolver = MusicLinkResolver(session: makeSession(), box: makeBox())
        let result = try await resolver.resolve(title: "original sound", artist: "noodleworship")

        XCTAssertEqual(result, .none)
        XCTAssertEqual(MusicLinkStubURLProtocol.requestCount, 0)
    }

    func testEmptyTitleResolvesToNothing() async throws {
        MusicLinkStubURLProtocol.requestHandler = { _ in
            XCTFail("no network request should be issued for an empty title")
            throw URLError(.badURL)
        }

        let resolver = MusicLinkResolver(session: makeSession(), box: makeBox())
        let result = try await resolver.resolve(title: "   ", artist: "someone")

        XCTAssertEqual(result, .none)
        XCTAssertEqual(MusicLinkStubURLProtocol.requestCount, 0)
    }

    func testNoITunesHitResolvesToNothing() async throws {
        stub(itunes: Data(#"{"resultCount": 0, "results": []}"#.utf8))

        let resolver = MusicLinkResolver(session: makeSession(), box: makeBox())
        let result = try await resolver.resolve(title: "Unfindable Track", artist: "Nobody")

        // Without an Apple seed there is nothing to hand Odesli, so it isn't called.
        XCTAssertEqual(result, .none)
        XCTAssertEqual(MusicLinkStubURLProtocol.requestCount, 1)
    }
}

/// `TrackData.links` is persisted as a JSON blob on `Video`, so both the shape the app
/// writes today and the one it wrote before per-service links existed must decode.
final class TrackDataCodableTests: XCTestCase {

    func testBlobWrittenBeforePerServiceLinksStillDecodes() throws {
        let legacy = Data(#"""
        {"title": "Midnight City", "artist": "M83", "universalLink": "https://song.link/x"}
        """#.utf8)

        let track = try JSONDecoder().decode(TrackData.self, from: legacy)

        XCTAssertEqual(track.title, "Midnight City")
        XCTAssertEqual(track.universalLink?.absoluteString, "https://song.link/x")
        XCTAssertNil(track.links)
    }

    /// Mirrors the JSON `SampleData` hand-builds for the seeded library.
    func testCurrentBlobDecodesLinks() throws {
        let current = Data(#"""
        {"title": "Midnight City", "artist": "M83", "links": [
          {"service": "appleMusic", "url": "https://music.apple.com/us/album/x/1?i=2"},
          {"service": "tidal", "url": "https://listen.tidal.com/track/17761850"}
        ]}
        """#.utf8)

        let track = try JSONDecoder().decode(TrackData.self, from: current)

        XCTAssertEqual(track.links?.map(\.service), [.appleMusic, .tidal])
        XCTAssertEqual(track.links?.last?.url.absoluteString, "https://listen.tidal.com/track/17761850")
    }

    func testRoundTrip() throws {
        let track = TrackData(
            title: "Midnight City", artist: "M83", universalLink: nil,
            links: [TrackLink(service: .spotify, url: URL(string: "https://open.spotify.com/track/abc")!)])

        let decoded = try JSONDecoder().decode(TrackData.self, from: JSONEncoder().encode(track))

        XCTAssertEqual(decoded, track)
    }
}

final class MusicLinkStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var requestedHosts: [String] = []
    nonisolated(unsafe) private static var headersByHost: [String: [String: String]] = [:]

    static func reset() {
        requestHandler = nil
        requestCount = 0
        requestedHosts = []
        headersByHost = [:]
    }

    static func headers(forHost host: String) -> [String: String]? { headersByHost[host] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MusicLinkStubURLProtocol.requestCount += 1
        if let host = request.url?.host {
            MusicLinkStubURLProtocol.requestedHosts.append(host)
            MusicLinkStubURLProtocol.headersByHost[host] = request.allHTTPHeaderFields ?? [:]
        }
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
