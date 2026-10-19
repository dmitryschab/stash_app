import XCTest
@testable import TikTokBrainKit

/// The about-text a save is searched by: what the request carries for one save, which saves are
/// still owed one, and what the stored text stands in for.
final class AboutTests: XCTestCase {

    // MARK: Fixtures

    private func makeVideo(
        _ id: String = "1",
        category: String = Category.recipe.rawValue,
        title: String = "Miso Ramen",
        transcript: String? = nil,
        transcribe: StageState? = nil
    ) -> Video {
        let video = Video(videoID: id, url: URL(string: "https://tiktok.com/x/\(id)")!, bookmarkedAt: .now)
        video.categoryRaw = category
        video.title = title
        video.transcript = transcript
        if let transcribe {
            video.stageStatesJSON = try! JSONEncoder().encode(
                [PipelineStage.transcribe.rawValue: transcribe])
        }
        return video
    }

    // MARK: What a save sends

    func testSpeechSaveSendsNoImage() {
        // Someone is talking: the words are the answer, and a picture would only cost more.
        let video = makeVideo(transcript: "hi there friends", transcribe: .done)
        XCTAssertNil(AboutItem(video: video, cover: Data([1])).image)
    }

    func testSilentSaveSendsItsCover() {
        let video = makeVideo(transcript: nil, transcribe: .done)
        XCTAssertTrue(video.hasNoSpeech)
        XCTAssertEqual(AboutItem(video: video, cover: Data([1, 2])).image, "AQI=")
    }

    func testSilentSaveWithoutCoverSendsNoImage() {
        let video = makeVideo(transcript: nil, transcribe: .done)
        XCTAssertNil(AboutItem(video: video, cover: nil).image)
    }

    func testFailedTranscriptStillGetsATextOnlyItem() {
        // A failed transcript is not silence: the video may well have speech, and a picture
        // would stand in for words nobody got to hear. It is still owed an about-text.
        let video = makeVideo(transcript: nil, transcribe: .failed)
        XCTAssertFalse(video.hasNoSpeech)
        XCTAssertNil(AboutItem(video: video, cover: Data([1])).image)
        XCTAssertTrue(AboutBackfill.pending(in: [video]).contains { $0 === video })
    }

    func testMusicPicksBecomeTitleByArtist() throws {
        let video = makeVideo(category: Category.music.rawValue)
        video.musicJSON = try JSONEncoder().encode([MusicPick(kind: .track, title: "Lovesong", artist: "The Cure")])
        XCTAssertEqual(AboutItem(video: video, cover: nil).music, ["Lovesong by The Cure"])
    }

    func testALongCyrillicSaveStaysUnderTheServersTextCap() throws {
        // The server refuses the whole request (a batch of 8) when one item's text passes 16 KB of
        // UTF-8, and Cyrillic is two bytes a letter: one long save must not starve the rest.
        let video = makeVideo(transcript: String(repeating: "д", count: 20_000), transcribe: .done)
        video.caption = String(repeating: "б", count: 5_000)
        video.ocrText = String(repeating: "в", count: 5_000)
        video.summary = String(repeating: "г", count: 5_000)

        let json = try JSONEncoder().encode(AboutItem(video: video, cover: nil))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let text = ["category", "transcript", "ocrText", "caption", "summary"]
            .compactMap { fields[$0] as? String }
            + ((fields["music"] as? [String]) ?? [])

        XCTAssertLessThan(text.reduce(0) { $0 + $1.utf8.count }, 16 * 1024)
        XCTAssertEqual((fields["transcript"] as? String)?.count, 4000)
    }

    func testAMusicSaveNeverSendsItsTranscript() {
        // Lyrics describe nothing on screen, and the server's prompt never reads them: they do
        // not leave the device.
        let video = makeVideo(category: Category.music.rawValue, transcript: "never gonna give you up",
                              transcribe: .done)
        XCTAssertEqual(AboutItem(video: video, cover: nil).transcript, "")
    }

    // MARK: Who is owed one

    func testPendingSkipsUnanalyzedUnavailableAndGuessed() {
        let analyzed = makeVideo("a")
        let unanalyzed = makeVideo("b", category: "", title: "")
        let unavailable = makeVideo("c")
        unavailable.unavailable = true
        let guessed = makeVideo("d", title: "")   // a category and no words: Clef's guess
        let second = makeVideo("e")

        let pending = AboutBackfill.pending(in: [second, unanalyzed, unavailable, guessed, analyzed])
        XCTAssertEqual(pending.map(\.videoID), ["e", "a"])
    }

    func testPendingDropsAWrittenSave() {
        let video = makeVideo()
        video.aboutRevision = BoxAboutClient.revision
        XCTAssertTrue(AboutBackfill.pending(in: [video]).isEmpty)
    }

    // MARK: What gets searched

    func testEmbeddingTextIsTheAboutTextAlone() {
        let video = makeVideo(title: "pasta night")
        video.about = "a dog skates"
        XCTAssertEqual(video.embeddingText, "a dog skates")
        video.about = nil
        XCTAssertEqual(video.embeddingText, "")
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

    func testClientPostsItemsWithTheServersFieldNames() async throws {
        BoxStubURLProtocol.stub = .init(statusCode: 200, data: Data(#"{"abouts":["ramen","skating"]}"#.utf8))
        let silent = makeVideo("1", transcribe: .done)
        silent.caption = "dinner"
        let spoken = makeVideo("2", transcript: "hello", transcribe: .done)

        let client = BoxAboutClient(config: boxConfig(), session: makeSession())
        let abouts = try await client.write([
            AboutItem(video: silent, cover: Data([1, 2])), AboutItem(video: spoken, cover: nil),
        ])

        XCTAssertEqual(abouts, ["ramen", "skating"])
        XCTAssertEqual(BoxStubURLProtocol.lastRequest?.url?.absoluteString, "http://localhost:9/v1/about")
        let body = try XCTUnwrap(BoxStubURLProtocol.lastRequestBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [[String: Any]]])
        let first = try XCTUnwrap(payload["items"]?.first)
        XCTAssertEqual(Set(first.keys),
                       ["videoID", "category", "transcript", "ocrText", "caption", "summary", "music", "image"])
        XCTAssertEqual(first["videoID"] as? String, "1")
        XCTAssertEqual(first["caption"] as? String, "dinner")
        XCTAssertEqual(first["image"] as? String, "AQI=")
        // Strings the save does not have go as "", not null: the server's fields are not optional.
        XCTAssertEqual(first["transcript"] as? String, "")
        XCTAssertNil(payload["items"]?.last?["image"])
    }

    func testAnEmptyBatchNeverLeavesTheDevice() async throws {
        let client = BoxAboutClient(config: boxConfig(), session: makeSession())
        let abouts = try await client.write([])
        XCTAssertEqual(abouts, [])
        XCTAssertNil(BoxStubURLProtocol.lastRequest)
    }

    func testClientRejectsAShortAnswer() async {
        // Pairing text 0 with save 1 would file a confident description under the wrong video.
        BoxStubURLProtocol.stub = .init(statusCode: 200, data: Data(#"{"abouts":["only one"]}"#.utf8))
        let client = BoxAboutClient(config: boxConfig(), session: makeSession())
        do {
            _ = try await client.write([
                AboutItem(video: makeVideo("1"), cover: nil), AboutItem(video: makeVideo("2"), cover: nil),
            ])
            XCTFail("Expected the client to throw")
        } catch let error as BoxError {
            guard case .malformedPayload = error else {
                return XCTFail("Expected .malformedPayload, got \(error)")
            }
        } catch {
            XCTFail("Expected BoxError, got \(error)")
        }
    }
}
