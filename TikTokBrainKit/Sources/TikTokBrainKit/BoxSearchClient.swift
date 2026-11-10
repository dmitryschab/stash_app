// BoxSearchClient.swift
//
// The reading half of search: POST {base}/search ({query, candidates} → the ids that answer it,
// best first). The box hands the candidates to Claude Haiku, which reads each save's about-text
// against the request — what cosine cannot do for "something quick and vegetarian for tonight".
//
// The candidates are `SearchIndex.rank`'s own top, so the phone still finds the pool and the box
// only judges it. Shaped exactly like the other `BoxClients`: same JWT funnel, same timeout, same
// "box unreachable" mapping. A failure of any kind means the caller keeps its own ranking.

import Foundation

public struct BoxSearchClient: Sendable {
    /// The server's cap, mirrored so the caller trims to it instead of discovering it as a 422.
    public static let maxCandidates = 60
    /// Characters of one save's text that go up. The server takes 2000 bytes; 600 characters
    /// stays under it in any script, and an about-text is 2-4 sentences.
    public static let maxAboutCharacters = 600

    public struct Candidate: Encodable, Sendable, Equatable {
        public let id: String
        public let about: String

        public init(id: String, about: String) {
            self.id = id
            self.about = String(about.prefix(BoxSearchClient.maxAboutCharacters))
        }
    }

    private let config: BoxConfig
    private let session: URLSession

    public init(config: BoxConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// The candidates' ids that answer `query`, best first; empty when none does.
    public func pick(query: String, candidates: [Candidate]) async throws -> [String] {
        guard !candidates.isEmpty else { return [] }
        let url = config.baseURL.appendingPathComponent("search")
        var request = URLRequest(url: url, timeoutInterval: boxRequestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SearchRequest(
            query: query, candidates: Array(candidates.prefix(Self.maxCandidates))))

        let data = try await BoxHTTP.send(request, on: session, auth: config.auth)
        do {
            return try JSONDecoder().decode(SearchResponse.self, from: data).ids
        } catch {
            throw BoxError.malformedPayload("search response: \(error.localizedDescription)")
        }
    }

    private struct SearchRequest: Encodable {
        let query: String
        let candidates: [Candidate]
    }

    private struct SearchResponse: Decodable {
        let ids: [String]
    }
}
