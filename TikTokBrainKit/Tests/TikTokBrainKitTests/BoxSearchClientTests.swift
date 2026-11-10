import XCTest
@testable import TikTokBrainKit

/// The reading half of search: what goes up to /search and what comes back.
final class BoxSearchClientTests: XCTestCase {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoxStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func client() -> BoxSearchClient {
        BoxSearchClient(
            config: BoxConfig(baseURL: URL(string: "http://localhost:9/v1")!,
                              chatModel: "test-chat", whisperModel: "test-whisper"),
            session: makeSession())
    }

    override func setUp() {
        super.setUp()
        BoxStubURLProtocol.reset()
    }

    override func tearDown() {
        BoxStubURLProtocol.reset()
        super.tearDown()
    }

    func testPostsTheQueryAndCandidatesAndReturnsThePickedIDs() async throws {
        BoxStubURLProtocol.stub = .init(statusCode: 200, data: Data(#"{"ids":["b","a"]}"#.utf8))

        let picked = try await client().pick(query: "dinner", candidates: [
            .init(id: "a", about: "A mushroom risotto."), .init(id: "b", about: "Tofu stir-fry.")])

        XCTAssertEqual(picked, ["b", "a"])
        XCTAssertEqual(BoxStubURLProtocol.lastRequest?.url?.absoluteString,
                       "http://localhost:9/v1/search")
        let body = try XCTUnwrap(BoxStubURLProtocol.lastRequestBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["query"] as? String, "dinner")
        XCTAssertEqual((payload["candidates"] as? [[String: String]])?.map { $0["id"] }, ["a", "b"])
    }

    func testOnlyTheServersCapGoesUpAndALongTextIsCut() async throws {
        BoxStubURLProtocol.stub = .init(statusCode: 200, data: Data(#"{"ids":[]}"#.utf8))
        let many = (0..<100).map { BoxSearchClient.Candidate(id: "\($0)", about: String(repeating: "я", count: 900)) }

        _ = try await client().pick(query: "x", candidates: many)

        let body = try XCTUnwrap(BoxStubURLProtocol.lastRequestBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sent = try XCTUnwrap(payload["candidates"] as? [[String: String]])
        XCTAssertEqual(sent.count, BoxSearchClient.maxCandidates)
        // Under the server's 2000-byte limit even in a two-byte script.
        XCTAssertTrue(sent.allSatisfy { ($0["about"]?.utf8.count ?? 0) < 2000 })
    }

    func testNoCandidatesNeverLeavesTheDevice() async throws {
        let picked = try await client().pick(query: "x", candidates: [])
        XCTAssertEqual(picked, [])
        XCTAssertNil(BoxStubURLProtocol.lastRequest)
    }

    func testAFailedSearchThrowsSoTheCallerKeepsItsOwnList() async {
        BoxStubURLProtocol.stub = .init(statusCode: 503, data: Data())
        do {
            _ = try await client().pick(query: "x", candidates: [.init(id: "a", about: "b")])
            XCTFail("Expected the client to throw")
        } catch let error as BoxError {
            guard case .badResponse(503) = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("Expected BoxError, got \(error)")
        }
    }
}
