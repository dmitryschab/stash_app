import XCTest
import SwiftData
@testable import TikTokBrainKit

final class CloudImportTests: XCTestCase {
    private func makeClient(
        authorization: @escaping @Sendable () -> String? = { "developer-token" },
        retryDelays: [UInt64] = [0, 0, 0],
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> CloudImportClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudImportURLProtocol.self]
        CloudImportURLProtocol.handler = handler
        return CloudImportClient(
            baseURL: URL(string: "https://stash.example/v1")!,
            authorization: authorization,
            session: URLSession(configuration: configuration),
            retryDelays: retryDelays
        )
    }

    private func response(for request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    }

    private func bookmark(id: String = "1") -> Bookmark {
        Bookmark(
            id: id,
            url: URL(string: "https://www.tiktok.com/@x/video/\(id)")!,
            date: Date(timeIntervalSince1970: 1_751_363_200)
        )
    }

    private func status(
        state: CloudImportState,
        done: Int,
        total: Int = 2,
        unavailable: Int = 0,
        partialFailures: Int = 0,
        updatedAt: Date = Date(timeIntervalSince1970: 10),
        map: CloudImportMap? = nil
    ) -> CloudImportStatus {
        CloudImportStatus(
            importID: "import-1",
            state: state,
            fastPass: CloudImportProgress(done: done, total: total),
            unavailable: unavailable,
            partialFailures: partialFailures,
            estimatedCostUSD: 0.25,
            updatedAt: updatedAt,
            map: map
        )
    }

    // MARK: - Map and guesses

    func testStatusDecodesWithAndWithoutAMapAndDropsUnknownCategories() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let base = """
        {"importID":"i","state":"fast_pass","fastPass":{"done":0,"total":10},"unavailable":0,
         "partialFailures":0,"estimatedCostUSD":0,"updatedAt":"2026-10-07T10:00:00Z"
        """
        let without = try decoder.decode(CloudImportStatus.self, from: Data((base + "}").utf8))
        XCTAssertNil(without.map)

        let with = try decoder.decode(CloudImportStatus.self, from: Data((base + """
        ,"map":{"sampled":3,"done":2,"counts":{"coding":1,"gardening":1},"guesses":{"7":"coding","8":"gardening"}}}
        """).utf8))
        let map = try XCTUnwrap(with.map)
        XCTAssertEqual(map.sampled, 3)
        XCTAssertEqual(map.done, 2)
        XCTAssertEqual(map.counts, [.coding: 1])
        XCTAssertEqual(map.guesses, ["7": .coding])

        // Round-trips through the persisted sync state.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(with)
        XCTAssertEqual(try decoder.decode(CloudImportStatus.self, from: encoded).map, map)
    }

    func testSyncStateKeepsTheMapWithTheHigherDone() {
        var state = CloudImportSyncState(importID: "import-1")
        let early = CloudImportMap(sampled: 60, done: 10, counts: [.coding: 10])
        let late = CloudImportMap(sampled: 60, done: 40, counts: [.coding: 30, .recipe: 10])
        state.apply(status: status(state: .fastPass, done: 1, map: late))
        state.apply(status: status(state: .fastPass, done: 2, map: early))
        XCTAssertEqual(state.status?.map, late)
        state.apply(status: status(state: .fastPass, done: 3, map: nil))
        XCTAssertEqual(state.status?.map, late)   // a poll without a map does not erase it
    }

    func testGuessesFillOnlyEmptyUnanalysedRowsAndTheFastPassOverridesThem() throws {
        let container = try ModelContainer(for: Video.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        for id in ["1", "2", "3"] {
            context.insert(Video(videoID: id, url: URL(string: "https://www.tiktok.com/@x/video/\(id)")!,
                                 bookmarkedAt: Date(timeIntervalSince1970: 1)))
        }
        try context.save()
        // "2" was analysed in an earlier import.
        _ = try CloudImportResultUpserter.apply([CloudImportResult(videoID: "2", analysisRevision: 8, category: "music", title: "Old")], to: context)

        let changed = try CloudImportResultUpserter.applyGuesses(["1": .coding, "2": .recipe, "9": .film], to: context)
        XCTAssertEqual(changed, 1)
        let videos = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Video>()).map { ($0.videoID, $0) })
        XCTAssertEqual(videos["1"]?.categoryRaw, "coding")
        XCTAssertEqual(videos["1"]?.isGuessed, true)               // a guess is not an analysis
        XCTAssertEqual(videos["2"]?.categoryRaw, "music")          // analysed rows are left alone
        XCTAssertEqual(videos["2"]?.isGuessed, false)
        XCTAssertEqual(videos["3"]?.categoryRaw, "")
        XCTAssertEqual(videos["3"]?.isGuessed, false)              // nothing is not a guess

        XCTAssertEqual(try CloudImportResultUpserter.applyGuesses(["1": .coding], to: context), 0)   // idempotent

        _ = try CloudImportResultUpserter.apply([CloudImportResult(videoID: "1", analysisRevision: 8, category: "learning", title: "Real")], to: context)
        XCTAssertEqual(videos["1"]?.categoryRaw, "learning")       // the fast pass wins a disagreement
        XCTAssertEqual(videos["1"]?.isGuessed, false)
    }

    func testARowAnalysedOnDeviceAtRevisionZeroIsNotAGuess() {
        // The old on-device pipeline and the demo seed both leave revision 0 behind — with a
        // title. Only a row with a category and nothing else is Clef's.
        let video = Video(videoID: "1", url: URL(string: "https://www.tiktok.com/@x/video/1")!, bookmarkedAt: Date())
        video.categoryRaw = "recipe"
        video.title = "Pasta"
        XCTAssertFalse(video.isGuessed)
        video.title = ""
        video.summary = "A dish."
        XCTAssertFalse(video.isGuessed)
        video.summary = ""
        XCTAssertTrue(video.isGuessed)
    }

    func testAFailedFastPassClearsAGuessAndTheRetryThenLands() throws {
        // The map lands first, then the fast pass fails this video. The guess must go with the
        // failure — a guessed row is not in "Needs a look", not archived and never retried —
        // and the retry that follows, at the same revision, must still be accepted.
        let container = try ModelContainer(for: Video.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.insert(Video(videoID: "1", url: URL(string: "https://www.tiktok.com/@x/video/1")!,
                             bookmarkedAt: Date(timeIntervalSince1970: 1)))
        try context.save()
        _ = try CloudImportResultUpserter.applyGuesses(["1": .coding], to: context)
        _ = try CloudImportResultUpserter.apply([CloudImportResult(videoID: "1", analysisRevision: 8, errorCode: "analysis_failed")], to: context)
        let video = try XCTUnwrap(context.fetch(FetchDescriptor<Video>()).first)
        XCTAssertEqual(video.categoryRaw, "")
        XCTAssertFalse(video.isGuessed)
        let applied = try CloudImportResultUpserter.apply([CloudImportResult(videoID: "1", analysisRevision: 8, category: "coding", title: "Real")], to: context)
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(video.categoryRaw, "coding")
        XCTAssertEqual(video.title, "Real")
    }

    func testAnUnavailableResultClearsAGuess() throws {
        let container = try ModelContainer(for: Video.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.insert(Video(videoID: "1", url: URL(string: "https://www.tiktok.com/@x/video/1")!,
                             bookmarkedAt: Date(timeIntervalSince1970: 1)))
        try context.save()
        _ = try CloudImportResultUpserter.applyGuesses(["1": .coding], to: context)
        _ = try CloudImportResultUpserter.apply([CloudImportResult(videoID: "1", analysisRevision: 8, unavailable: true, errorCode: "unavailable")], to: context)
        let video = try XCTUnwrap(context.fetch(FetchDescriptor<Video>()).first)
        XCTAssertTrue(video.unavailable)
        XCTAssertEqual(video.categoryRaw, "")
    }

    func testSubmissionEncodesRequestUsingWireNames() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/imports")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer developer-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try requestBody(from: request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["clientImportID"] as? String, "11111111-1111-4111-8111-111111111111")
            let videos = try XCTUnwrap(json["videos"] as? [[String: Any]])
            XCTAssertEqual(videos.first?["videoID"] as? String, "1")
            XCTAssertEqual(videos.first?["url"] as? String, "https://www.tiktok.com/@x/video/1")
            XCTAssertNotNil(videos.first?["bookmarkedAt"] as? String)
            return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data(#"{"importID":"import-1","state":"accepted","accepted":1,"duplicates":0}"#.utf8))
        }

        let result = try await client.submit(
            bookmarks: [bookmark()],
            clientImportID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        )

        XCTAssertEqual(result.importID, "import-1")
        XCTAssertEqual(result.accepted, 1)
    }

    func testSubmissionRetryReusesTheSameClientImportID() async throws {
        let recorder = RequestRecorder()
        let client = makeClient { request in
            let attempt = recorder.record(try requestBody(from: request))
            if attempt == 1 {
                return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data(#"{"importID":"import-1","state":"accepted","accepted":1,"duplicates":0}"#.utf8))
        }

        _ = try await client.submit(
            bookmarks: [bookmark()],
            clientImportID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        )

        XCTAssertEqual(recorder.bodies.count, 2)
        XCTAssertEqual(recorder.bodies[0], recorder.bodies[1])
    }

    func testSyncStateIgnoresRegressingStatus() {
        var sync = CloudImportSyncState(importID: "import-1", clientImportID: nil)
        sync.apply(status: status(state: .fastPass, done: 2, unavailable: 1, partialFailures: 1, updatedAt: Date(timeIntervalSince1970: 20)))
        sync.apply(status: status(state: .accepted, done: 0, unavailable: 0, partialFailures: 0, updatedAt: Date(timeIntervalSince1970: 30)))

        XCTAssertEqual(sync.status?.state, .fastPass)
        XCTAssertEqual(sync.status?.fastPass.done, 2)
        XCTAssertEqual(sync.status?.unavailable, 1)
        XCTAssertEqual(sync.status?.partialFailures, 1)
    }

    func testAllResultsFollowsPaginationCursor() async throws {
        let client = makeClient { request in
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cursor" })?.value
            if cursor == nil {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"results":[{"videoID":"1","analysisRevision":1}],"nextCursor":"1"}"#.utf8))
            }
            XCTAssertEqual(cursor, "1")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"results":[{"videoID":"2","analysisRevision":1}],"nextCursor":null}"#.utf8))
        }

        let results = try await client.allResults(importID: "import-1")

        XCTAssertEqual(results.map(\.videoID), ["1", "2"])
    }

    func testResultUpsertAcceptsNewerRevisionAndDeduplicatesOlderResults() throws {
        let container = try ModelContainer(for: Video.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.insert(Video(
            videoID: "1",
            url: URL(string: "https://www.tiktok.com/@x/video/1")!,
            bookmarkedAt: Date(timeIntervalSince1970: 1)
        ))
        try context.save()

        let first = try CloudImportResultUpserter.apply([
            CloudImportResult(videoID: "1", analysisRevision: 1, category: "recipe", title: "First"),
            CloudImportResult(videoID: "1", analysisRevision: 1, category: "recipe", title: "Duplicate"),
            CloudImportResult(videoID: "1", analysisRevision: 2, category: "music", title: "Newest"),
        ], to: context)
        let second = try CloudImportResultUpserter.apply([
            CloudImportResult(videoID: "1", analysisRevision: 1, category: "recipe", title: "Old"),
            CloudImportResult(videoID: "1", analysisRevision: 2, category: "music", title: "Same"),
        ], to: context)

        let video = try XCTUnwrap(context.fetch(FetchDescriptor<Video>()).first)
        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 0)
        XCTAssertEqual(video.cloudAnalysisRevision, 2)
        XCTAssertEqual(video.categoryRaw, "music")
        XCTAssertEqual(video.title, "Newest")
    }

    /// A retried save comes back at the revision its failure was stored with — the box stamps
    /// both with the current one — so "strictly newer" alone would drop the success on the floor.
    func testResultUpsertLetsASameRevisionSuccessReplaceAFailure() throws {
        let container = try ModelContainer(for: Video.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.insert(Video(videoID: "1", url: URL(string: "https://www.tiktok.com/@x/video/1")!,
                             bookmarkedAt: Date(timeIntervalSince1970: 1)))
        try context.save()

        let failed = try CloudImportResultUpserter.apply([
            CloudImportResult(videoID: "1", analysisRevision: 8, errorCode: "provider_402")], to: context)
        let failedAgain = try CloudImportResultUpserter.apply([
            CloudImportResult(videoID: "1", analysisRevision: 8, errorCode: "provider_402")], to: context)
        let retried = try CloudImportResultUpserter.apply([
            CloudImportResult(videoID: "1", analysisRevision: 8, category: "music", title: "Retried")], to: context)
        let replayed = try CloudImportResultUpserter.apply([
            CloudImportResult(videoID: "1", analysisRevision: 8, category: "music", title: "Replayed")], to: context)

        let video = try XCTUnwrap(context.fetch(FetchDescriptor<Video>()).first)
        XCTAssertEqual([failed, failedAgain, retried, replayed], [1, 0, 1, 0])
        XCTAssertEqual(video.categoryRaw, "music")
        XCTAssertEqual(video.title, "Retried")
    }

    func testResultUpsertPersistsFilmPicks() throws {
        let container = try ModelContainer(for: Video.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let video = Video(videoID: "film-1", url: URL(string: "https://example.com/1")!, bookmarkedAt: .now)
        context.insert(video)
        try context.save()

        try CloudImportResultUpserter.apply([
            CloudImportResult(
                videoID: "film-1", analysisRevision: 8, category: "film",
                films: [FilmPick(title: "Arrival", year: 2016)])
        ], to: context)

        XCTAssertEqual(video.films, [FilmPick(title: "Arrival", year: 2016)])
    }

    func testEmptySameCategoryCloudPassPreservesRicherLocalFilmPicks() throws {
        let container = try ModelContainer(for: Video.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let video = Video(videoID: "film-2", url: URL(string: "https://example.com/2")!, bookmarkedAt: .now)
        video.categoryRaw = Category.film.rawValue
        video.filmsJSON = try JSONEncoder().encode([FilmPick(title: "Heat", year: 1995)])
        context.insert(video)
        try context.save()

        try CloudImportResultUpserter.apply([
            CloudImportResult(videoID: "film-2", analysisRevision: 8, category: "film", films: [])
        ], to: context)

        XCTAssertEqual(video.films, [FilmPick(title: "Heat", year: 1995)])
    }

    func testCloudReclassificationAwayFromFilmClearsStalePicks() throws {
        let container = try ModelContainer(for: Video.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let video = Video(videoID: "film-3", url: URL(string: "https://example.com/3")!, bookmarkedAt: .now)
        video.categoryRaw = Category.film.rawValue
        video.filmsJSON = try JSONEncoder().encode([FilmPick(title: "Heat", year: 1995)])
        context.insert(video)
        try context.save()

        try CloudImportResultUpserter.apply([
            CloudImportResult(
                videoID: "film-3", analysisRevision: 8, category: "comedy",
                films: [FilmPick(title: "Wrong category", year: 2020)])
        ], to: context)

        XCTAssertEqual(video.categoryRaw, Category.comedy.rawValue)
        XCTAssertNil(video.filmsJSON)
    }

    func testWholeLibraryFitsAndOverCapIsRejectedWithoutNetwork() async throws {
        // A 900-video library must submit; over the cap is rejected before any network call.
        XCTAssertGreaterThanOrEqual(CloudImportLimits.maxVideosPerImport, 900)

        let client = makeClient { request in
            XCTFail("over-cap submit must not hit the network")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let tooMany = (0...CloudImportLimits.maxVideosPerImport).map { bookmark(id: "\($0)") }
        do {
            _ = try await client.submit(bookmarks: tooMany, clientImportID: UUID())
            XCTFail("expected tooManyVideos")
        } catch let error as CloudImportError {
            guard case .tooManyVideos = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testMissingTokenFailsWithoutNetworkCall() async throws {
        let client = makeClient(authorization: { nil }) { request in
            XCTFail("no network call should be made without a token")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        do {
            _ = try await client.status(importID: "import-1")
            XCTFail("expected missingAuthorization")
        } catch let error as CloudImportError {
            XCTAssertEqual(error, .missingAuthorization)
        }
    }

    func testTerminalHTTPErrorDoesNotRetry() async throws {
        let recorder = RequestRecorder()
        let client = makeClient { request in
            _ = recorder.record(Data())
            return (HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, Data())
        }

        do {
            _ = try await client.status(importID: "import-1")
            XCTFail("expected badResponse(422)")
        } catch let error as CloudImportError {
            XCTAssertEqual(error, .badResponse(422))
        }
        XCTAssertEqual(recorder.bodies.count, 1)
    }

    func testRetryExhaustionOn5xx() async throws {
        let recorder = RequestRecorder()
        let client = makeClient(retryDelays: [0, 0]) { request in
            _ = recorder.record(Data())
            return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }

        do {
            _ = try await client.status(importID: "import-1")
            XCTFail("expected badResponse(503)")
        } catch let error as CloudImportError {
            XCTAssertEqual(error, .badResponse(503))
        }
        XCTAssertEqual(recorder.bodies.count, 3)
    }

    func testTransportErrorRetriesUntilExhaustion() async throws {
        let recorder = RequestRecorder()
        let client = makeClient(retryDelays: [0, 0]) { _ in
            _ = recorder.record(Data())
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await client.status(importID: "import-1")
            XCTFail("expected transport error")
        } catch let error as CloudImportError {
            guard case .transport = error else { return XCTFail("expected transport, got \(error)") }
        }
        XCTAssertEqual(recorder.bodies.count, 3)
    }

    /// The app cancels the poll when it goes to the background; that is not an outage.
    func testCancellingAPollRaisesCancellationNotTransport() async throws {
        let client = makeClient { request in
            Thread.sleep(forTimeInterval: 0.5)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let poll = Task { try await client.status(importID: "import-1") }
        try await Task.sleep(nanoseconds: 100_000_000)
        poll.cancel()

        do {
            _ = try await poll.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testUpsertPreservesLocalMetadataForUnavailableAndFailedResults() throws {
        let container = try ModelContainer(for: Video.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let video = Video(
            videoID: "1",
            url: URL(string: "https://www.tiktok.com/@x/video/1")!,
            bookmarkedAt: Date(timeIntervalSince1970: 1)
        )
        video.author = "local-author"
        video.caption = "local-caption"
        video.title = "local-title"
        context.insert(video)
        try context.save()

        let firstApplied = try CloudImportResultUpserter.apply([
            CloudImportResult(videoID: "1", analysisRevision: 1, author: "cloud-author", caption: "cloud-caption", title: "cloud-title", unavailable: true),
        ], to: context)

        XCTAssertEqual(firstApplied, 1)
        XCTAssertEqual(video.author, "local-author")
        XCTAssertEqual(video.caption, "local-caption")
        XCTAssertEqual(video.title, "local-title")
        XCTAssertEqual(video.cloudAnalysisRevision, 1)
        XCTAssertTrue(video.unavailable)

        let secondApplied = try CloudImportResultUpserter.apply([
            CloudImportResult(videoID: "1", analysisRevision: 2, author: "cloud-author-2", caption: "cloud-caption-2", title: "cloud-title-2", unavailable: false, errorCode: "fetch_failed"),
        ], to: context)

        XCTAssertEqual(secondApplied, 1)
        XCTAssertEqual(video.author, "local-author")
        XCTAssertEqual(video.caption, "local-caption")
        XCTAssertEqual(video.title, "local-title")
        XCTAssertEqual(video.cloudAnalysisRevision, 2)
        XCTAssertFalse(video.unavailable)

        let states = try JSONDecoder().decode([String: StageState].self, from: video.stageStatesJSON)
        XCTAssertEqual(states["analyze"], .failed)
    }

    func testFingerprintIsOrderIndependent() {
        let a = bookmark(id: "1")
        let b = bookmark(id: "2")
        let c = bookmark(id: "3")

        XCTAssertEqual(
            CloudImportSyncState.fingerprint(of: [a, b, c]),
            CloudImportSyncState.fingerprint(of: [c, a, b])
        )
        XCTAssertNotEqual(
            CloudImportSyncState.fingerprint(of: [a, b, c]),
            CloudImportSyncState.fingerprint(of: [a, b])
        )
    }

}

private final class CloudImportURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
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

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var bodies: [Data] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func record(_ body: Data) -> Int {
        lock.lock(); defer { lock.unlock() }
        storage.append(body)
        return storage.count
    }
}

private func requestBody(from request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { throw URLError(.zeroByteResource) }
    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
        if count == 0 { break }
        body.append(buffer, count: count)
    }
    return body
}

// MARK: - Structured analysis carried by cloud results

extension CloudImportTests {
    /// Cook and Music filter on recipe/music, not on category, so a result that drops them
    /// leaves both walls empty however many saves the category holds.
    func testResultDecodesRecipeAndMusic() throws {
        let json = """
        {"videoID":"1","category":"recipe","analysisRevision":3,
         "recipe":{"name":"Focaccia","ingredients":["flour","water"],"steps":["mix","bake"]},
         "music":[{"kind":"album","title":"Blue","artist":"Joni Mitchell"},
                  {"kind":"track","title":"River","artist":""}]}
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(CloudImportResult.self, from: json)
        XCTAssertEqual(result.recipe?.name, "Focaccia")
        XCTAssertEqual(result.recipe?.ingredients, ["flour", "water"])
        XCTAssertEqual(result.music.map(\.title), ["Blue", "River"])
        XCTAssertEqual(result.music.first?.kind, .album)
    }

    func testResultWithoutStructureDecodesEmpty() throws {
        let json = #"{"videoID":"2","category":"comedy"}"#.data(using: .utf8)!
        let result = try JSONDecoder().decode(CloudImportResult.self, from: json)
        XCTAssertNil(result.recipe)
        XCTAssertTrue(result.music.isEmpty)
        XCTAssertTrue(result.films.isEmpty)
    }

    func testMalformedFilmMetadataIsCleanedWithoutFailingCloudResult() throws {
        let json = #"{"videoID":"film-4","films":[{"title":"  Arrival  ","year":"2016"},null,{"title":4},{"title":"Heat","year":"unknown"}]}"#
            .data(using: .utf8)!

        let result = try JSONDecoder().decode(CloudImportResult.self, from: json)

        XCTAssertEqual(result.films, [
            FilmPick(title: "Arrival", year: 2016),
            FilmPick(title: "Heat"),
        ])
    }

    /// A blank title is not a pick, and the array is bounded the same way the contract bounds it.
    func testMusicPicksAreFilteredAndBounded() throws {
        let picks = (0..<20).map { #"{"kind":"track","title":"t\#($0)"}"# }.joined(separator: ",")
        let json = #"{"videoID":"3","music":[{"kind":"track","title":""},\#(picks)]}"#
            .data(using: .utf8)!
        let result = try JSONDecoder().decode(CloudImportResult.self, from: json)
        XCTAssertEqual(result.music.count, MusicPick.maxPerVideo)
        XCTAssertFalse(result.music.contains { $0.title.isEmpty })
    }
}
