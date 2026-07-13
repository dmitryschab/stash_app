import Foundation
import SwiftData

public enum CloudImportState: String, Codable, Sendable {
    case accepted
    case fastPass = "fast_pass"
    case completed
    case cancelled

    fileprivate var rank: Int {
        switch self {
        case .accepted: 0
        case .fastPass: 1
        case .completed, .cancelled: 2
        }
    }
}

public struct CloudImportProgress: Codable, Equatable, Sendable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

public struct CloudImportSubmission: Codable, Equatable, Sendable {
    public var importID: String
    public var state: CloudImportState
    public var accepted: Int
    public var duplicates: Int

    public init(importID: String, state: CloudImportState, accepted: Int, duplicates: Int) {
        self.importID = importID
        self.state = state
        self.accepted = accepted
        self.duplicates = duplicates
    }
}

public struct CloudImportStatus: Codable, Equatable, Sendable {
    public var importID: String
    public var state: CloudImportState
    public var fastPass: CloudImportProgress
    public var unavailable: Int
    public var partialFailures: Int
    public var estimatedCostUSD: Double
    public var updatedAt: Date

    public init(
        importID: String,
        state: CloudImportState,
        fastPass: CloudImportProgress,
        unavailable: Int,
        partialFailures: Int,
        estimatedCostUSD: Double,
        updatedAt: Date
    ) {
        self.importID = importID
        self.state = state
        self.fastPass = fastPass
        self.unavailable = unavailable
        self.partialFailures = partialFailures
        self.estimatedCostUSD = estimatedCostUSD
        self.updatedAt = updatedAt
    }
}

public struct CloudImportResult: Codable, Equatable, Sendable {
    public var videoID: String
    public var analysisRevision: Int
    public var author: String?
    public var caption: String?
    public var hashtags: [String]
    public var thumbnailURL: String?
    public var duration: Double?
    public var category: String?
    public var title: String?
    public var summary: String?
    public var topics: [String]
    public var unavailable: Bool
    public var errorCode: String?

    public init(
        videoID: String,
        analysisRevision: Int = 1,
        author: String? = nil,
        caption: String? = nil,
        hashtags: [String] = [],
        thumbnailURL: String? = nil,
        duration: Double? = nil,
        category: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        topics: [String] = [],
        unavailable: Bool = false,
        errorCode: String? = nil
    ) {
        self.videoID = videoID
        self.analysisRevision = analysisRevision
        self.author = author
        self.caption = caption
        self.hashtags = hashtags
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.category = category
        self.title = title
        self.summary = summary
        self.topics = topics
        self.unavailable = unavailable
        self.errorCode = errorCode
    }

    private enum CodingKeys: String, CodingKey {
        case videoID, analysisRevision, author, caption, hashtags, thumbnailURL, duration
        case category, title, summary, topics, unavailable, errorCode
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        videoID = try values.decode(String.self, forKey: .videoID)
        analysisRevision = try values.decodeIfPresent(Int.self, forKey: .analysisRevision) ?? 1
        author = try values.decodeIfPresent(String.self, forKey: .author)
        caption = try values.decodeIfPresent(String.self, forKey: .caption)
        hashtags = try values.decodeIfPresent([String].self, forKey: .hashtags) ?? []
        thumbnailURL = try values.decodeIfPresent(String.self, forKey: .thumbnailURL)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration)
        category = try values.decodeIfPresent(String.self, forKey: .category)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        topics = try values.decodeIfPresent([String].self, forKey: .topics) ?? []
        unavailable = try values.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
        errorCode = try values.decodeIfPresent(String.self, forKey: .errorCode)
    }
}

public struct CloudImportSyncState: Codable, Equatable, Sendable {
    public var importID: String?
    public var clientImportID: UUID?
    public var status: CloudImportStatus?
    public var nextResultsCursor: String?
    public var videoIDsFingerprint: String?

    public init(importID: String? = nil, clientImportID: UUID? = nil, videoIDsFingerprint: String? = nil) {
        self.importID = importID
        self.clientImportID = clientImportID
        self.status = nil
        self.nextResultsCursor = nil
        self.videoIDsFingerprint = videoIDsFingerprint
    }

    public var isActive: Bool {
        guard let state = status?.state else { return importID != nil }
        return state != .completed && state != .cancelled
    }

    public static func fingerprint(of bookmarks: [Bookmark]) -> String {
        bookmarks.map(\.id).sorted().joined(separator: ",")
    }

    public mutating func apply(status incoming: CloudImportStatus) {
        guard importID == nil || importID == incoming.importID else { return }
        importID = incoming.importID
        guard let current = status else {
            status = incoming
            return
        }
        guard incoming.state.rank >= current.state.rank else { return }

        status = CloudImportStatus(
            importID: incoming.importID,
            state: incoming.state,
            fastPass: CloudImportProgress(
                done: max(current.fastPass.done, incoming.fastPass.done),
                total: max(current.fastPass.total, incoming.fastPass.total)),
            unavailable: max(current.unavailable, incoming.unavailable),
            partialFailures: max(current.partialFailures, incoming.partialFailures),
            estimatedCostUSD: max(current.estimatedCostUSD, incoming.estimatedCostUSD),
            updatedAt: max(current.updatedAt, incoming.updatedAt)
        )
    }
}

public enum CloudImportFeatureFlag {
    public static let defaultsKey = "developer.cloudImportEnabled"

    public static func isEnabled(debugBuild: Bool, defaults: UserDefaults = .standard) -> Bool {
        debugBuild && defaults.bool(forKey: defaultsKey)
    }
}

public enum CloudImportError: Error, Equatable, LocalizedError {
    case missingAuthorization
    case invalidBaseURL
    case badResponse(Int)
    case transport(String)
    case malformedPayload(String)
    case tooManyVideos(Int)

    public var errorDescription: String? {
        switch self {
        case .missingAuthorization: "Developer cloud-import token is not configured."
        case .invalidBaseURL: "The cloud-import base URL is invalid."
        case .badResponse(let status): "Cloud import returned HTTP \(status)."
        case .transport(let message): "Cloud import is unreachable: \(message)"
        case .malformedPayload(let message): "Cloud import returned an invalid response: \(message)"
        case .tooManyVideos(let count): "Cloud imports currently support at most 50 videos (received \(count))."
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .badResponse(let status): status == 408 || status == 429 || status >= 500
        case .transport: true
        default: false
        }
    }
}

public struct CloudImportClient: Sendable {
    private let baseURL: URL
    private let authorization: @Sendable () -> String?
    private let session: URLSession
    private let retryDelays: [UInt64]

    public init(
        baseURL: URL,
        authorization: @escaping @Sendable () -> String?,
        session: URLSession = .shared,
        retryDelays: [UInt64] = [250, 1_000]
    ) {
        self.baseURL = baseURL
        self.authorization = authorization
        self.session = session
        self.retryDelays = retryDelays
    }

    public func submit(bookmarks: [Bookmark], clientImportID: UUID) async throws -> CloudImportSubmission {
        guard bookmarks.count <= 50 else { throw CloudImportError.tooManyVideos(bookmarks.count) }
        let payload = CreateImportRequest(
            clientImportID: clientImportID,
            videos: bookmarks.map {
                BookmarkRequest(videoID: $0.id, url: $0.url.absoluteString, bookmarkedAt: $0.date)
            })
        var request = try makeRequest(path: "imports", method: "POST")
        request.httpBody = try Self.encoder.encode(payload)
        return try await send(request, as: CloudImportSubmission.self)
    }

    public func status(importID: String) async throws -> CloudImportStatus {
        let request = try makeRequest(path: "imports/\(importID)", method: "GET")
        return try await send(request, as: CloudImportStatus.self)
    }

    public func results(importID: String, cursor: String? = nil) async throws -> (results: [CloudImportResult], nextCursor: String?) {
        guard var components = URLComponents(url: try makeURL(path: "imports/\(importID)/results"), resolvingAgainstBaseURL: false) else {
            throw CloudImportError.invalidBaseURL
        }
        if let cursor { components.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
        guard let url = components.url else { throw CloudImportError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try addAuthorization(to: &request)
        let page = try await send(request, as: ResultPage.self)
        return (page.results, page.nextCursor)
    }

    public func allResults(importID: String) async throws -> [CloudImportResult] {
        var cursor: String?
        var seenCursors = Set<String>()
        var all: [CloudImportResult] = []
        repeat {
            let page = try await results(importID: importID, cursor: cursor)
            all.append(contentsOf: page.results)
            guard let next = page.nextCursor else { break }
            guard seenCursors.insert(next).inserted else {
                throw CloudImportError.malformedPayload("result cursor repeated")
            }
            cursor = next
        } while true
        return all
    }

    private func makeURL(path: String) throws -> URL {
        guard baseURL.scheme != nil, baseURL.host != nil else { throw CloudImportError.invalidBaseURL }
        let url = baseURL.appendingPathComponent(path)
        guard url.scheme != nil, url.host != nil else {
            throw CloudImportError.invalidBaseURL
        }
        return url
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        var request = URLRequest(url: try makeURL(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try addAuthorization(to: &request)
        return request
    }

    private func addAuthorization(to request: inout URLRequest) throws {
        guard let token = authorization(), !token.isEmpty else {
            throw CloudImportError.missingAuthorization
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw CloudImportError.transport("invalid HTTP response")
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw CloudImportError.badResponse(http.statusCode)
                }
                do {
                    return try Self.decoder.decode(type, from: data)
                } catch {
                    throw CloudImportError.malformedPayload(error.localizedDescription)
                }
            } catch let error as CloudImportError {
                guard shouldRetry(error), attempt < retryDelays.count else { throw error }
                try? await Task.sleep(nanoseconds: retryDelays[attempt] * 1_000_000)
            } catch {
                let mapped = CloudImportError.transport(error.localizedDescription)
                guard attempt < retryDelays.count else { throw mapped }
                try? await Task.sleep(nanoseconds: retryDelays[attempt] * 1_000_000)
            }
            attempt += 1
        }
    }

    private func shouldRetry(_ error: CloudImportError) -> Bool {
        error.isRetryable
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private struct BookmarkRequest: Encodable {
    let videoID: String
    let url: String
    let bookmarkedAt: Date
}

private struct CreateImportRequest: Encodable {
    let clientImportID: UUID
    let videos: [BookmarkRequest]
}

private struct ResultPage: Decodable {
    let results: [CloudImportResult]
    let nextCursor: String?
}

public enum CloudImportResultUpserter {
    @discardableResult
    public static func apply(_ results: [CloudImportResult], to context: ModelContext) throws -> Int {
        let videos = try context.fetch(FetchDescriptor<Video>())
        let byID = Dictionary(uniqueKeysWithValues: videos.map { ($0.videoID, $0) })
        var applied = 0

        for result in results {
            guard let video = byID[result.videoID], result.analysisRevision > video.cloudAnalysisRevision else { continue }
            if !result.unavailable, result.errorCode == nil {
                if let author = result.author { video.author = author }
                if let caption = result.caption { video.caption = caption }
                video.hashtags = result.hashtags
                if let thumbnailURL = result.thumbnailURL, let url = URL(string: thumbnailURL) {
                    video.thumbnailURL = url
                }
                if let category = result.category { video.categoryRaw = category }
                if let title = result.title { video.title = title }
                if let summary = result.summary { video.summary = summary }
                video.topics = result.topics
            }
            video.unavailable = result.unavailable
            video.cloudAnalysisRevision = result.analysisRevision
            video.stageStatesJSON = stageStates(for: result)
            applied += 1
        }

        if applied > 0 { try context.save() }
        return applied
    }

    private static func stageStates(for result: CloudImportResult) -> Data {
        let primary: StageState = result.unavailable ? .skipped : (result.errorCode != nil ? .failed : .done)
        let states: [String: StageState] = [
            "enrich": primary,
            "media": .skipped,
            "transcribe": .skipped,
            "ocr": .skipped,
            "analyze": primary,
        ]
        return (try? JSONEncoder().encode(states)) ?? Data()
    }
}
