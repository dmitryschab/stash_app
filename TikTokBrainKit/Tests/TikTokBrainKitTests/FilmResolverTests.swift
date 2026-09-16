import XCTest
@testable import TikTokBrainKit

final class FilmResolverTests: XCTestCase {
    private func resolver(pages: [[String: Any]], status: Int = 200) throws -> FilmResolver {
        let data = try JSONSerialization.data(withJSONObject: ["query": ["pages": pages]])
        FilmPosterStub.requestCount = 0
        FilmPosterStub.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "pilicense" }?.value, "any")
            XCTAssertEqual(request.url?.host, "en.wikipedia.org")
            return (HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: nil, headerFields: nil)!, data)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FilmPosterStub.self]
        return FilmResolver(session: URLSession(configuration: config))
    }

    private func page(_ title: String, year: Int, image: String? = "https://upload.wikimedia.org/wikipedia/en/example.jpg") -> [String: Any] {
        var value: [String: Any] = [
            "pageid": year, "title": title,
            "terms": ["description": ["\(year) American science fiction film"]],
            "extract": "\(title) is a \(year) American science fiction film.",
            "fullurl": "https://en.wikipedia.org/wiki/" + title.replacingOccurrences(of: " ", with: "_"),
        ]
        if let image { value["thumbnail"] = ["source": image, "width": 200, "height": 300] }
        return value
    }

    func testResolvesFilmPosterAndYearRatherThanAnUnrelatedTopResult() async throws {
        let resolver = try resolver(pages: [page("Inception of an Empire", year: 2012), page("Inception", year: 2010)])
        let ref = try await resolver.film(for: FilmPick(title: "Inception"))
        XCTAssertEqual(ref?.title, "Inception")
        XCTAssertEqual(ref?.year, 2010)
        XCTAssertEqual(ref?.posterURL?.host, "upload.wikimedia.org")
        XCTAssertEqual(ref?.detailURL.absoluteString, "https://en.wikipedia.org/wiki/Inception")
    }

    func testYearDisambiguatesRemakesAndUnspecifiedYearDoesNotGuess() async throws {
        let resolver = try resolver(pages: [page("Dune (1984 film)", year: 1984), page("Dune (2021 film)", year: 2021)])
        let ambiguous = try await resolver.film(for: FilmPick(title: "Dune"))
        XCTAssertNil(ambiguous)
        let exact = try await resolver.film(for: FilmPick(title: "Dune", year: 2021))
        XCTAssertEqual(exact?.year, 2021)
        let wrongYear = try await resolver.film(for: FilmPick(title: "Dune", year: 2000))
        XCTAssertNil(wrongYear)
    }

    func testMissingPosterKeepsMatchedMovieDetails() async throws {
        let resolver = try resolver(pages: [page("Primer (film)", year: 2004, image: nil)])
        let ref = try await resolver.film(for: FilmPick(title: "Primer"))
        XCTAssertEqual(ref?.year, 2004)
        XCTAssertNil(ref?.posterURL)
        XCTAssertEqual(ref?.title, "Primer")
    }

    func testNonFilmPageAndUnsafeImageAreNotPresentedAsPosters() async throws {
        var word = page("Primer", year: 2004)
        word["terms"] = ["description": ["Introductory textbook"]]
        word["extract"] = "A primer is an introductory textbook."
        let resolver = try resolver(pages: [word])
        let nonFilm = try await resolver.film(for: FilmPick(title: "Primer"))
        XCTAssertNil(nonFilm)
        let unsafeResolver = try self.resolver(pages: [page("Primer (film)", year: 2004, image: "http://other.example/poster.jpg")])
        let safeRef = try await unsafeResolver.film(for: FilmPick(title: "Primer"))
        XCTAssertNotNil(safeRef)
        XCTAssertNil(safeRef?.posterURL)
    }

    func testCachesConfirmedMissAndCoalescesSimultaneousLookups() async throws {
        let resolver = try resolver(pages: [page("Inception", year: 2010)])
        async let first = resolver.film(for: FilmPick(title: "Inception"))
        async let second = resolver.film(for: FilmPick(title: "Inception"))
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(FilmPosterStub.requestCount, 1)
        _ = try await resolver.film(for: FilmPick(title: "No such film"))
        _ = try await resolver.film(for: FilmPick(title: "No such film"))
        XCTAssertEqual(FilmPosterStub.requestCount, 2)
    }

    func testHTTPFailureIsRetryableAndNotCachedAsMissing() async throws {
        let resolver = try resolver(pages: [], status: 503)
        for _ in 0..<2 {
            do {
                _ = try await resolver.film(for: FilmPick(title: "Inception"))
                XCTFail("A failed catalogue request must remain retryable")
            } catch { }
        }
        XCTAssertEqual(FilmPosterStub.requestCount, 2)
    }

    func testConflictingYearAndLandscapeImageDoNotBecomeMoviePosters() async throws {
        var conflict = page("Inception", year: 2010)
        conflict["extract"] = "Inception is a 2011 American science fiction film."
        let resolver = try resolver(pages: [conflict])
        let inconsistent = try await resolver.film(for: FilmPick(title: "Inception"))
        XCTAssertNil(inconsistent)

        var landscape = page("The Matrix", year: 1999)
        landscape["thumbnail"] = ["source": "https://upload.wikimedia.org/wikipedia/en/cast.jpg", "width": 300, "height": 200]
        let posterResolver = try self.resolver(pages: [landscape])
        let ref = try await posterResolver.film(for: FilmPick(title: "Matrix"))
        XCTAssertEqual(ref?.title, "The Matrix")
        XCTAssertNil(ref?.posterURL)
    }
}

private final class FilmPosterStub: URLProtocol {
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
