import XCTest
@testable import TikTokBrainKit

/// The arithmetic behind "Meaning, not just keywords": what a vector survives on its way into
/// SwiftData and back, what cosine says about two of them, and the blend that turns three
/// unrelated numbers into one ranking.
final class EmbeddingSearchTests: XCTestCase {

    // MARK: Pack / unpack

    func testPackedVectorRoundTrips() {
        let values: [Float] = [0, 1, -1, 0.5, -0.0078125, 1234.5, .leastNormalMagnitude]
        XCTAssertEqual(EmbeddingVector.unpack(EmbeddingVector.pack(values)), values)
    }

    func testAPackedVectorIsFourLittleEndianBytesPerFloat() {
        // Pinned, not derived: the bytes are what sits in the store, so an accidental switch to
        // big-endian or Float64 would read every existing library back as noise.
        let data = EmbeddingVector.pack([1.0])
        XCTAssertEqual([UInt8](data), [0x00, 0x00, 0x80, 0x3F])
        XCTAssertEqual(EmbeddingVector.pack(Array(repeating: 0, count: 256)).count, 256 * 4)
    }

    func testUnpackingSomethingThatIsNotAVectorYieldsNoFloats() {
        XCTAssertEqual(EmbeddingVector.unpack(Data()), [])
        // Three bytes is not a float; a truncated blob must not produce a garbage tail.
        XCTAssertEqual(EmbeddingVector.unpack(Data([1, 2, 3])), [])
    }

    // MARK: Cosine

    func testCosineOfIdenticalVectorsIsOne() {
        XCTAssertEqual(EmbeddingVector.cosine([1, 2, 3], [1, 2, 3]), 1, accuracy: 1e-9)
        // Direction, not magnitude.
        XCTAssertEqual(EmbeddingVector.cosine([1, 2, 3], [10, 20, 30]), 1, accuracy: 1e-9)
    }

    func testOrthogonalVectorsScoreZero() {
        XCTAssertEqual(EmbeddingVector.cosine([1, 0], [0, 1]), 0, accuracy: 1e-9)
    }

    func testAnOppositeVectorIsClampedToZeroRatherThanGoingNegative() {
        // A negative cosine means "unrelated". Left negative it would drag a save below one that
        // matched nothing at all, and recency alone could then outrank a real match.
        XCTAssertEqual(EmbeddingVector.cosine([1, 0], [-1, 0]), 0)
    }

    func testMismatchedOrEmptyVectorsScoreZeroInsteadOfTrapping() {
        // Exactly the shape of a vector stored by an older model, which has to degrade to
        // lexical rather than crash the list it is being sorted.
        XCTAssertEqual(EmbeddingVector.cosine([1, 0, 0], [1, 0]), 0)
        XCTAssertEqual(EmbeddingVector.cosine([], []), 0)
        XCTAssertEqual(EmbeddingVector.cosine([0, 0], [1, 1]), 0)
    }

    // MARK: Blend

    func testTheBlendIsSixtyFiveThirtyFive() {
        XCTAssertEqual(SearchBlend.semanticWeight
                        + SearchBlend.lexicalWeight
                        + SearchBlend.recencyWeight, 1, accuracy: 1e-9)
        XCTAssertEqual(SearchBlend.score(cosine: 1, lexical: 1, recency: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(SearchBlend.score(cosine: 0, lexical: 0, recency: 0), 0)
        XCTAssertEqual(SearchBlend.score(cosine: 1, lexical: 0, recency: 0), 0.65, accuracy: 1e-9)
        XCTAssertEqual(SearchBlend.score(cosine: 0, lexical: 1, recency: 0), 0.30, accuracy: 1e-9)
        XCTAssertEqual(SearchBlend.score(cosine: 0, lexical: 0, recency: 1), 0.05, accuracy: 1e-9)
    }

    func testMeaningBeatsAWordMatchOnSomethingOlder() {
        // The whole promise of the feature: a save that says the same thing in other words wins
        // over one that happens to share a token.
        let meaning = SearchBlend.score(cosine: 0.9, lexical: 0, recency: 0)
        let keyword = SearchBlend.score(cosine: 0, lexical: 1, recency: 1)
        XCTAssertGreaterThan(meaning, keyword)
    }

    func testRecencyOnlyBreaksTies() {
        // 0.05 is deliberately too small to move anything on its own: a newer save wins only
        // against an equally good older one.
        let newerButWeaker = SearchBlend.score(cosine: 0.5, lexical: 0.5, recency: 1)
        let olderButStronger = SearchBlend.score(cosine: 0.6, lexical: 0.5, recency: 0)
        XCTAssertGreaterThan(olderButStronger, newerButWeaker)

        let newer = SearchBlend.score(cosine: 0.5, lexical: 0.5, recency: 1)
        let older = SearchBlend.score(cosine: 0.5, lexical: 0.5, recency: 0)
        XCTAssertGreaterThan(newer, older)
    }

    // MARK: Client

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoxStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func boxConfig() -> BoxConfig {
        BoxConfig(baseURL: URL(string: "http://localhost:9/v1")!,
                  chatModel: "test-chat", whisperModel: "test-whisper")
    }

    override func setUp() {
        super.setUp()
        BoxStubURLProtocol.reset()
    }

    override func tearDown() {
        BoxStubURLProtocol.reset()
        super.tearDown()
    }

    func testTheClientPostsTextsAndDecodesVectors() async throws {
        BoxStubURLProtocol.stub = .init(statusCode: 200, data: try JSONSerialization.data(
            withJSONObject: ["vectors": [[1.0, 0.0], [0.0, 1.0]], "model": "titan", "dims": 2]))

        let client = BoxEmbeddingClient(config: boxConfig(), session: makeSession())
        let vectors = try await client.embed(["a recipe", "an album"])

        XCTAssertEqual(vectors, [[1, 0], [0, 1]])
        XCTAssertEqual(BoxStubURLProtocol.lastRequest?.url?.absoluteString,
                       "http://localhost:9/v1/embeddings")
        XCTAssertEqual(BoxStubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer local")
        let body = try XCTUnwrap(BoxStubURLProtocol.lastRequestBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [String]])
        XCTAssertEqual(payload["texts"], ["a recipe", "an album"])
    }

    func testAnEmptyBatchNeverLeavesTheDevice() async throws {
        let client = BoxEmbeddingClient(config: boxConfig(), session: makeSession())
        let vectors = try await client.embed([])
        XCTAssertEqual(vectors.count, 0)
        XCTAssertNil(BoxStubURLProtocol.lastRequest)
    }

    func testAShortAnswerIsRejectedRatherThanMisaligned() async {
        // Pairing vector 0 with video 1 would make every result confidently wrong, which is
        // worse than having no meaning half at all.
        BoxStubURLProtocol.stub = .init(statusCode: 200, data: Data(
            #"{"vectors":[[1.0,0.0]],"model":"titan","dims":2}"#.utf8))

        let client = BoxEmbeddingClient(config: boxConfig(), session: makeSession())
        do {
            _ = try await client.embed(["one", "two"])
            XCTFail("Expected the client to throw")
        } catch let error as BoxError {
            guard case .malformedPayload = error else {
                return XCTFail("Expected .malformedPayload, got \(error)")
            }
        } catch {
            XCTFail("Expected BoxError, got \(error)")
        }
    }

    func testAnUnreachableBoxMapsToBoxError() async {
        BoxStubURLProtocol.stub = .init(error: URLError(.cannotConnectToHost))
        let client = BoxEmbeddingClient(config: boxConfig(), session: makeSession())
        do {
            _ = try await client.embed(["x"])
            XCTFail("Expected the client to throw")
        } catch let error as BoxError {
            guard case .unreachable = error else {
                return XCTFail("Expected .unreachable, got \(error)")
            }
        } catch {
            XCTFail("Expected BoxError, got \(error)")
        }
    }

    // MARK: Embed text

    func testTheEmbedTextCarriesTheAnalysisAndTruncatesTheLongFields() {
        let video = Video(videoID: "1", url: URL(string: "https://tiktok.com/x")!, bookmarkedAt: .now)
        video.title = "Miso Ramen"
        video.topics = ["ramen", "noodles"]
        video.summary = "A quick miso ramen."
        video.caption = "POV miso ramen"
        // Letters that appear in none of the fields above, so the counts below are the slices.
        video.transcript = String(repeating: "x", count: 5000)
        video.ocrText = String(repeating: "z", count: 5000)

        let text = video.embeddingText
        XCTAssertTrue(text.contains("Miso Ramen"))
        XCTAssertTrue(text.contains("ramen noodles"))
        XCTAssertTrue(text.contains("A quick miso ramen."))
        XCTAssertTrue(text.contains("POV miso ramen"))
        XCTAssertEqual(text.filter { $0 == "x" }.count, 1000)
        XCTAssertEqual(text.filter { $0 == "z" }.count, 500)
    }

    func testAnUnanalyzedSaveHasNothingToEmbed() {
        // The backfill skips these rather than sending the box a blank string per video.
        let video = Video(videoID: "1", url: URL(string: "https://tiktok.com/x")!, bookmarkedAt: .now)
        XCTAssertTrue(video.embeddingText.isEmpty)
    }
}
