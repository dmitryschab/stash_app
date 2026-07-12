import XCTest
@testable import TikTokBrainKit

final class MusicLinkResolverTests: XCTestCase {

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

    func testResolvesToSongLink() async throws {
        let fixtureURL = Bundle.module.url(forResource: "Fixtures/itunes-search", withExtension: "json")!
        let fixtureData = try Data(contentsOf: fixtureURL)
        MusicLinkStubURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, fixtureData)
        }

        let resolver = MusicLinkResolver(session: makeSession())
        let link = try await resolver.universalLink(title: "Example Song", artist: "Example Artist")

        XCTAssertEqual(
            link?.absoluteString,
            "https://song.link/https%3A%2F%2Fmusic.apple.com%2Fus%2Falbum%2Fexample%2F123%3Fi%3D456"
        )
        XCTAssertEqual(MusicLinkStubURLProtocol.requestCount, 1)
    }

    func testOriginalSoundReturnsNil() async throws {
        MusicLinkStubURLProtocol.requestHandler = { _ in
            XCTFail("no network request should be issued for an original sound")
            throw URLError(.badURL)
        }

        let resolver = MusicLinkResolver(session: makeSession())
        let link = try await resolver.universalLink(title: "original sound", artist: "noodleworship")

        XCTAssertNil(link)
        XCTAssertEqual(MusicLinkStubURLProtocol.requestCount, 0)
    }

    func testEmptyTitleReturnsNil() async throws {
        MusicLinkStubURLProtocol.requestHandler = { _ in
            XCTFail("no network request should be issued for an empty title")
            throw URLError(.badURL)
        }

        let resolver = MusicLinkResolver(session: makeSession())
        let link = try await resolver.universalLink(title: "   ", artist: "someone")

        XCTAssertNil(link)
        XCTAssertEqual(MusicLinkStubURLProtocol.requestCount, 0)
    }

    func testNoResultsReturnsNil() async throws {
        let emptyResponse = Data(#"{"resultCount": 0, "results": []}"#.utf8)
        MusicLinkStubURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, emptyResponse)
        }

        let resolver = MusicLinkResolver(session: makeSession())
        let link = try await resolver.universalLink(title: "Unfindable Track", artist: "Nobody")

        XCTAssertNil(link)
        XCTAssertEqual(MusicLinkStubURLProtocol.requestCount, 1)
    }
}

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
