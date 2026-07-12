import XCTest
@testable import TikTokBrainKit

// MARK: - URLProtocol stub (task-namespaced to avoid symbol clashes with other test files)

/// A `URLProtocol` subclass that returns canned responses / errors and records the outgoing
/// request body. Registered on an ephemeral `URLSessionConfiguration` so no real network happens.
final class BoxStubURLProtocol: URLProtocol {
    struct Stub {
        var statusCode: Int = 200
        var data: Data? = nil
        var error: Error? = nil
        var headers: [String: String] = ["Content-Type": "application/json"]
    }

    nonisolated(unsafe) static var stub = Stub()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastRequestBody: Data?

    static func reset() {
        stub = Stub()
        lastRequest = nil
        lastRequestBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        BoxStubURLProtocol.lastRequest = request
        BoxStubURLProtocol.lastRequestBody = BoxStubURLProtocol.readBody(from: request)

        let stub = BoxStubURLProtocol.stub
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = stub.data {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession converts a request's `httpBody` into an `httpBodyStream` before handing it to
    /// the protocol, so read from whichever is present.
    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Tests

final class BoxClientsTests: XCTestCase {

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoxStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func boxConfig() -> BoxConfig {
        BoxConfig(baseURL: URL(string: "http://localhost:9/v1")!,
                  chatModel: "test-chat",
                  whisperModel: "test-whisper")
    }

    private func makeTempAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("box-client-test-\(UUID().uuidString).m4a")
        try Data([0x00, 0x01, 0x02, 0x03, 0x04]).write(to: url)
        return url
    }

    override func setUp() {
        super.setUp()
        BoxStubURLProtocol.reset()
    }

    override func tearDown() {
        BoxStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Analyzer

    func testAnalyzerDecodesRecipe() async throws {
        let analysisJSON = """
        {"category":"recipe","title":"Miso Ramen","summary":"A quick miso ramen.",\
        "topics":["ramen","noodles"],\
        "recipe":{"name":"Miso Ramen","ingredients":["miso paste","noodles"],"steps":["boil water","serve"]}}
        """
        // The model wraps its JSON in a Markdown code fence — the client must strip it.
        let fencedContent = "```json\n\(analysisJSON)\n```"
        let chatBody: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": fencedContent]]]
        ]
        BoxStubURLProtocol.stub = .init(
            statusCode: 200,
            data: try JSONSerialization.data(withJSONObject: chatBody)
        )

        let client = AnalyzerClient(config: boxConfig(), session: makeSession())
        let analysis = try await client.analyze(
            meta: VideoMeta(caption: "POV miso ramen #recipe", hashtags: ["recipe"]),
            transcript: "boil the noodles",
            ocrText: "miso"
        )

        XCTAssertEqual(analysis.category, .recipe)
        XCTAssertEqual(analysis.title, "Miso Ramen")
        XCTAssertEqual(analysis.recipe?.name, "Miso Ramen")
        XCTAssertEqual(analysis.recipe?.ingredients, ["miso paste", "noodles"])
        XCTAssertEqual(analysis.recipe?.steps, ["boil water", "serve"])
        XCTAssertNil(analysis.track)

        // Analyzer posts to /chat/completions with a JSON object response_format.
        let sentBody = try XCTUnwrap(BoxStubURLProtocol.lastRequestBody)
        let sent = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: sentBody) as? [String: Any]
        )
        XCTAssertEqual(BoxStubURLProtocol.lastRequest?.url?.absoluteString,
                       "http://localhost:9/v1/chat/completions")
        XCTAssertEqual(sent["model"] as? String, "test-chat")
        let responseFormat = sent["response_format"] as? [String: Any]
        XCTAssertEqual(responseFormat?["type"] as? String, "json_object")
    }

    func testAnalyzerUnreachableMapsToBoxError() async {
        BoxStubURLProtocol.stub = .init(error: URLError(.cannotConnectToHost))
        let client = AnalyzerClient(config: boxConfig(), session: makeSession())
        do {
            _ = try await client.analyze(meta: VideoMeta(), transcript: nil, ocrText: nil)
            XCTFail("Expected the client to throw")
        } catch let error as BoxError {
            guard case .unreachable(let message) = error else {
                return XCTFail("Expected .unreachable, got \(error)")
            }
            XCTAssertTrue(message.contains("Tailscale"),
                          "Unreachable message should mention Tailscale, got: \(message)")
        } catch {
            XCTFail("Expected BoxError, got \(error)")
        }
    }

    // MARK: Transcriber

    func testTranscriberParsesText() async throws {
        BoxStubURLProtocol.stub = .init(
            statusCode: 200,
            data: try JSONSerialization.data(withJSONObject: ["text": "hello from whisper"])
        )
        let audioURL = try makeTempAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let client = TranscriberClient(config: boxConfig(), session: makeSession())
        let text = try await client.transcribe(audioFileURL: audioURL)

        XCTAssertEqual(text, "hello from whisper")
        XCTAssertEqual(BoxStubURLProtocol.lastRequest?.url?.absoluteString,
                       "http://localhost:9/v1/audio/transcriptions")
    }

    func testTranscriberSendsMultipart() async throws {
        BoxStubURLProtocol.stub = .init(
            statusCode: 200,
            data: try JSONSerialization.data(withJSONObject: ["text": "ok"])
        )
        let audioURL = try makeTempAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let client = TranscriberClient(config: boxConfig(), session: makeSession())
        _ = try await client.transcribe(audioFileURL: audioURL)

        let contentType = BoxStubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type")
        XCTAssertEqual(contentType?.hasPrefix("multipart/form-data; boundary="), true)

        let body = try XCTUnwrap(BoxStubURLProtocol.lastRequestBody)
        let bodyString = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyString.contains("filename="),
                      "multipart body should carry the file part filename")
        XCTAssertTrue(bodyString.contains("name=\"model\""),
                      "multipart body should contain the model field")
        XCTAssertTrue(bodyString.contains("test-whisper"),
                      "multipart body should send the configured whisper model")
        XCTAssertTrue(bodyString.contains("name=\"language\""),
                      "multipart body should contain the language field")
        XCTAssertTrue(bodyString.contains("name=\"response_format\""),
                      "multipart body should contain the response_format field")
    }

    func testTranscriberBadResponseMapsToBoxError() async throws {
        BoxStubURLProtocol.stub = .init(statusCode: 500, data: Data("boom".utf8))
        let audioURL = try makeTempAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let client = TranscriberClient(config: boxConfig(), session: makeSession())
        do {
            _ = try await client.transcribe(audioFileURL: audioURL)
            XCTFail("Expected the client to throw")
        } catch let error as BoxError {
            XCTAssertEqual(error, .badResponse(500))
        } catch {
            XCTFail("Expected BoxError, got \(error)")
        }
    }
}
