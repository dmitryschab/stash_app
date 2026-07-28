import XCTest
@testable import TikTokBrainKit

/// Returns a canned response whose `url` is the "landing" URL, which is what `URLSession`
/// reports after it has followed a redirect chain — the property `TikTokLink.resolve` reads.
final class TikTokLinkURLProtocol: URLProtocol {
    nonisolated(unsafe) static var landingURL: URL?
    nonisolated(unsafe) static var error: Error?
    nonisolated(unsafe) static var requestedUserAgent: String?

    static func reset() {
        landingURL = nil
        error = nil
        requestedUserAgent = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestedUserAgent = request.value(forHTTPHeaderField: "User-Agent")
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: Self.landingURL ?? request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html></html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class TikTokLinkTests: XCTestCase {
    private func makeSession() -> URLSession {
        TikTokLinkURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TikTokLinkURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private let shared = Date(timeIntervalSince1970: 1_785_000_000)

    // MARK: - Video id

    func testVideoIDReadsCanonicalAndPhotoPaths() {
        XCTAssertEqual(
            TikTokLink.videoID(in: URL(string: "https://www.tiktok.com/@jazzcat/video/7523456789012345678")!),
            "7523456789012345678")
        XCTAssertEqual(
            TikTokLink.videoID(in: URL(string: "https://www.tiktok.com/@jazzcat/photo/7523456789012345678/")!),
            "7523456789012345678")
        XCTAssertEqual(
            TikTokLink.videoID(in: URL(string: "https://www.tiktok.com/@jazzcat/video/7523456789012345678?_t=8x&_r=1")!),
            "7523456789012345678")
    }

    func testVideoIDIsNilWithoutANumericSegment() {
        XCTAssertNil(TikTokLink.videoID(in: URL(string: "https://vm.tiktok.com/ZMabc123/")!))
        XCTAssertNil(TikTokLink.videoID(in: URL(string: "https://www.tiktok.com/@jazzcat")!))
        XCTAssertNil(TikTokLink.videoID(in: URL(string: "https://www.tiktok.com/@jazzcat/video/notanumber")!))
        XCTAssertNil(TikTokLink.videoID(in: URL(string: "https://www.tiktok.com/@jazzcat/video/")!))
    }

    // MARK: - Digging a link out of shared text

    /// TikTok's share sheet often hands over the caption and the link as one `public.plain-text`
    /// blob rather than a bare `public.url`.
    func testFirstLinkFindsTheURLInsideASentence() {
        let text = "5 jazz albums that changed everything 🎷 https://vm.tiktok.com/ZMabc123/ check it"
        XCTAssertEqual(
            TikTokLink.firstLink(in: text),
            URL(string: "https://vm.tiktok.com/ZMabc123/"))
    }

    func testFirstLinkSkipsNonTikTokLinks() {
        let text = "read https://example.com/post then https://www.tiktok.com/@a/video/7000000000000000001"
        XCTAssertEqual(
            TikTokLink.firstLink(in: text),
            URL(string: "https://www.tiktok.com/@a/video/7000000000000000001"))
        XCTAssertNil(TikTokLink.firstLink(in: "just https://example.com/post and nothing else"))
        XCTAssertNil(TikTokLink.firstLink(in: "no links here"))
    }

    /// A host that merely *contains* "tiktok.com" is not TikTok.
    func testIsTikTokRejectsLookalikeHosts() {
        XCTAssertFalse(TikTokLink.isTikTok(URL(string: "https://tiktok.com.evil.example/@a/video/1")!))
        XCTAssertFalse(TikTokLink.isTikTok(URL(string: "https://nottiktok.com/@a/video/1")!))
        XCTAssertTrue(TikTokLink.isTikTok(URL(string: "https://vm.tiktok.com/ZM1/")!))
        XCTAssertTrue(TikTokLink.isTikTok(URL(string: "https://tiktok.com/@a/video/1")!))
    }

    // MARK: - Resolution

    func testResolveShortCircuitsWhenTheLinkAlreadyCarriesAnID() async throws {
        let session = makeSession()
        let bookmark = try await TikTokLink.resolve(
            URL(string: "https://www.tiktok.com/@jazzcat/video/7523456789012345678?_t=8x&_r=1")!,
            session: session, now: shared)

        XCTAssertEqual(bookmark.id, "7523456789012345678")
        XCTAssertEqual(bookmark.url.absoluteString,
                       "https://www.tiktok.com/@jazzcat/video/7523456789012345678")
        XCTAssertEqual(bookmark.date, shared)
        XCTAssertNil(TikTokLinkURLProtocol.requestedUserAgent, "no request should have been made")
    }

    func testResolveFollowsAShortLinkToTheCanonicalURL() async throws {
        let session = makeSession()
        TikTokLinkURLProtocol.landingURL =
            URL(string: "https://www.tiktok.com/@jazzcat/video/7523456789012345678?_t=8x&_r=1")

        let bookmark = try await TikTokLink.resolve(
            URL(string: "https://vm.tiktok.com/ZMabc123/")!, session: session, now: shared)

        XCTAssertEqual(bookmark.id, "7523456789012345678")
        XCTAssertEqual(bookmark.url.absoluteString,
                       "https://www.tiktok.com/@jazzcat/video/7523456789012345678")
        XCTAssertEqual(TikTokLinkURLProtocol.requestedUserAgent, TikTokLink.desktopUserAgent)
    }

    /// A resolution that lands on the mobile host still has to submit: the box allowlists only
    /// four spellings and `m.tiktok.com` is not one of them.
    func testResolveNormalisesTheHostToTheSpellingTheBoxAllows() async throws {
        let session = makeSession()
        TikTokLinkURLProtocol.landingURL =
            URL(string: "https://m.tiktok.com/@jazzcat/video/7523456789012345678")

        let bookmark = try await TikTokLink.resolve(
            URL(string: "https://vt.tiktok.com/ZMabc123/")!, session: session, now: shared)

        XCTAssertEqual(bookmark.url.absoluteString,
                       "https://www.tiktok.com/@jazzcat/video/7523456789012345678")
    }

    func testResolveRejectsANonTikTokLinkWithoutARequest() async {
        let session = makeSession()
        do {
            _ = try await TikTokLink.resolve(
                URL(string: "https://www.instagram.com/reel/abc/")!, session: session, now: shared)
            XCTFail("expected a notTikTok failure")
        } catch let failure as TikTokLink.Failure {
            XCTAssertEqual(failure, .notTikTok("https://www.instagram.com/reel/abc/"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(TikTokLinkURLProtocol.requestedUserAgent)
    }

    func testResolveReportsUnresolvedWhenTheLandingURLHasNoID() async {
        let session = makeSession()
        TikTokLinkURLProtocol.landingURL = URL(string: "https://www.tiktok.com/login")

        do {
            _ = try await TikTokLink.resolve(
                URL(string: "https://vm.tiktok.com/ZMgone/")!, session: session, now: shared)
            XCTFail("expected an unresolved failure")
        } catch let failure as TikTokLink.Failure {
            XCTAssertEqual(failure, .unresolved("https://vm.tiktok.com/ZMgone/"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The distinction that decides whether a shared link is held for another try or dropped:
    /// a dead video is permanent, a dead network is not.
    func testResolveReportsUnreachableWhenTheRequestFails() async {
        let session = makeSession()
        TikTokLinkURLProtocol.error = URLError(.notConnectedToInternet)

        do {
            _ = try await TikTokLink.resolve(
                URL(string: "https://vm.tiktok.com/ZMoffline/")!, session: session, now: shared)
            XCTFail("expected an unreachable failure")
        } catch let failure as TikTokLink.Failure {
            XCTAssertEqual(failure, .unreachable("https://vm.tiktok.com/ZMoffline/"))
            XCTAssertTrue(failure.isRetryable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testOnlyAnUnreachableFailureIsWorthRetrying() {
        XCTAssertFalse(TikTokLink.Failure.notTikTok("x").isRetryable)
        XCTAssertFalse(TikTokLink.Failure.unresolved("x").isRetryable)
        XCTAssertTrue(TikTokLink.Failure.unreachable("x").isRetryable)
    }
}
