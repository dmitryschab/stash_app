// TikTokConnect.swift
//
// The box's half of "Connect TikTok" in Settings. The TikTok SDK runs in the app and ends in an
// authorization code; this client hands that code and its PKCE verifier to
// POST {base}/tiktok/connect, where the box trades them for tokens — the client secret never
// reaches the phone. DELETE on the same path revokes the grant and forgets the tokens.
// POST {base}/tiktok/sync is part two: the daily Favorite Videos sync
// (docs/superpowers/specs/2026-10-07-tiktok-portability-p2-design.md).
//
// The Kit does not import the TikTok SDK: everything here is plain /v1 JSON through
// `StashHTTP.send`, so the bearer, the one 401 refresh and the session errors are the same as
// every other route's.

import Foundation

/// The TikTok account linked to this Stash account, as the connect route and /v1/me report it.
public struct TikTokConnection: Codable, Equatable, Sendable {
    /// TikTok's display name. Empty when the box connected but could not read the profile.
    public var displayName: String
    /// Unix seconds, the wire contract's shape (as `Quota.monthResetAt`).
    public var connectedAt: Int
    /// When the last archive's favourites were handed over, in unix seconds, and how many it
    /// held. Null until the first sync and absent from a box older than P2; both decode as nil.
    public var lastSyncAt: Int?
    public var lastSyncCount: Int?

    public init(displayName: String, connectedAt: Int, lastSyncAt: Int? = nil, lastSyncCount: Int? = nil) {
        self.displayName = displayName
        self.connectedAt = connectedAt
        self.lastSyncAt = lastSyncAt
        self.lastSyncCount = lastSyncCount
    }
}

/// What one POST /v1/tiktok/sync answered. The box asks TikTok for the data archive at most
/// once a day and answers every other call from what it already knows.
public enum TikTokSyncResult: Equatable, Sendable {
    /// No TikTok linked any more: revoked on TikTok's side, or disconnected elsewhere.
    case notConnected
    /// Linked without the portability scopes — every sandbox connection.
    case notEnabled
    /// A request is with TikTok, which has not built the archive yet.
    case pending
    /// This call sent the request.
    case requested
    /// Nothing to ask TikTok for before `nextSyncAt`, unix seconds.
    case idle(nextSyncAt: Int)
    /// Every favourite in the archive TikTok built, not only the new ones.
    case ready([Bookmark])

    /// The part of a ready archive to submit. The archive repeats every favourite, and the box
    /// charges for every video submitted with no ledger of what it already sorted — so only
    /// favourites the library has never stored go, newest first, as many as `budget` covers.
    /// The rest stay out of the library as well, so a later archive offers them again.
    public static func toSubmit(_ favorites: [Bookmark], libraryIDs: Set<String>, budget: Int) -> [Bookmark] {
        Array(favorites.filter { !libraryIDs.contains($0.id) }
            .sorted { $0.date > $1.date }
            .prefix(max(budget, 0)))
    }
}

public enum TikTokConnectError: Error, Equatable, LocalizedError {
    /// The box said why, in FastAPI's `{"detail": "…"}`: a code TikTok did not accept, TikTok
    /// down, or sign-in not configured on the box. Its words are the ones the row shows.
    case refused(String)
    /// No answer worth repeating: a transport failure, or a status with no readable reason.
    case unreachable

    public var errorDescription: String? {
        switch self {
        case .refused(let detail): detail
        case .unreachable: "Couldn't reach TikTok"
        }
    }
}

/// Fifth of the box clients, same shape as `HaulOffersClient`: base URL and per-request JWT
/// from `BoxConfig`, 401/402 handled inside StashHTTP.
public struct TikTokConnectClient: Sendable {
    private let config: BoxConfig
    private let session: URLSession

    /// The App Store storefronts TikTok sync is offered in: the EU27, the rest of the EEA, and
    /// the UK, as the approved Data Portability application declares. ISO 3166-1 alpha-3, the
    /// form `Storefront.countryCode` reports. The box refuses a connect from anywhere else, from
    /// its own copy (`ALLOWED_STOREFRONTS` in services/webhook/tiktok_connect.py); change both
    /// together.
    public static let allowedStorefronts: Set<String> = [
        "AUT", "BEL", "BGR", "HRV", "CYP", "CZE", "DNK", "EST", "FIN", "FRA", "DEU", "GRC", "HUN",
        "IRL", "ITA", "LVA", "LTU", "LUX", "MLT", "NLD", "POL", "PRT", "ROU", "SVK", "SVN", "ESP",
        "SWE",
        "ISL", "LIE", "NOR",
        "GBR",
    ]

    public init(config: BoxConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// `storefront` is the App Store storefront's alpha-3 code, which the box checks against
    /// its own copy of `allowedStorefronts` before it calls TikTok.
    public func connect(code: String, codeVerifier: String, storefront: String) async throws -> TikTokConnection {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("tiktok/connect"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ["code": code, "codeVerifier": codeVerifier, "storefront": storefront])
        let data = try await send(request)
        guard let connection = try? JSONDecoder().decode(TikTokConnection.self, from: data) else {
            throw TikTokConnectError.unreachable
        }
        return connection
    }

    /// Idempotent on the box: 204 whether or not there was a connection to end.
    public func disconnect() async throws {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("tiktok/connect"))
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    public func sync() async throws -> TikTokSyncResult {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("tiktok/sync"))
        request.httpMethod = "POST"
        return try Self.decodeSync(try await send(request))
    }

    /// Split from the request so the decode tests dry, as `HaulOffersClient.decodeOffers`. The
    /// favourites go through the export's own mapping: id from the link, newest date on a
    /// duplicate. A state this build does not know reads as no answer.
    static func decodeSync(_ data: Data) throws -> TikTokSyncResult {
        struct Favorite: Decodable { let date: String; let link: String }
        struct Body: Decodable { let state: String; let nextSyncAt: Int?; let favorites: [Favorite]? }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
            throw TikTokConnectError.unreachable
        }
        switch body.state {
        case "not_connected": return .notConnected
        case "not_enabled": return .notEnabled
        case "pending": return .pending
        case "requested": return .requested
        case "idle":
            guard let next = body.nextSyncAt else { throw TikTokConnectError.unreachable }
            return .idle(nextSyncAt: next)
        case "ready":
            let items: [[String: Any]] = (body.favorites ?? []).map { ["date": $0.date, "link": $0.link] }
            return .ready(ExportParser().bookmarks(from: items))
        default:
            throw TikTokConnectError.unreachable
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await StashHTTP.send(request, on: session, auth: config.auth)
        } catch let error as StashError {
            throw error   // a signed-out session stays typed, as in BoxHTTP
        } catch {
            throw TikTokConnectError.unreachable
        }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(fromBody: data) }
        return data
    }

    /// FastAPI's error body. A `detail` that is not a string (a 422's list) or is missing
    /// (a proxy's HTML page) has nothing a person should read, so it falls back to unreachable.
    static func error(fromBody data: Data) -> TikTokConnectError {
        struct Detail: Decodable { let detail: String }
        guard let detail = try? JSONDecoder().decode(Detail.self, from: data).detail,
              !detail.isEmpty else { return .unreachable }
        return .refused(detail)
    }
}
