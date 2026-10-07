// TikTokConnect.swift
//
// The box's half of "Connect TikTok" in Settings. The TikTok SDK runs in the app and ends in an
// authorization code; this client hands that code and its PKCE verifier to
// POST {base}/tiktok/connect, where the box trades them for tokens — the client secret never
// reaches the phone. DELETE on the same path revokes the grant and forgets the tokens.
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

    public init(displayName: String, connectedAt: Int) {
        self.displayName = displayName
        self.connectedAt = connectedAt
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

    public init(config: BoxConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func connect(code: String, codeVerifier: String) async throws -> TikTokConnection {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("tiktok/connect"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code, "codeVerifier": codeVerifier])
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
