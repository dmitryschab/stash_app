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
        updatedAt: Date = Date(timeIntervalSince1970: 10)
    ) -> CloudImportStatus {
        CloudImportStatus(
            importID: "import-1",
            state: state,
            fastPass: CloudImportProgress(done: done, total: total),
            unavailable: unavailable,
            partialFailures: partialFailures,
            estimatedCostUSD: 0.25,
            updatedAt: updatedAt
        )
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
