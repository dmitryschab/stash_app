// StashAuth.swift
//
// The one place per-user auth crosses into the networking layer. Every /v1 request — box
// clients, cloud import, the OCR video fetch — goes through `StashHTTP.send`, which attaches
// the Stash JWT, refreshes it exactly once on a 401 and retries, and turns a 402 into a typed
// `StashError.quotaExhausted` carrying the server's current `Quota`. Keeping those two rules
// in a single funnel is the point: scattered per-client retries were how the old compiled-in
// bearer survived so long, and a refresh race would rotate the refresh token out from under
// the other in-flight requests.
//
// The Kit deliberately knows nothing about Keychain, Sign in with Apple, or how long a session
// lives: the app injects `StashAuthProvider`, three closures over its `StashSession`.

import Foundation

// MARK: - Quota

/// What the server says this user may still spend. The initial import budget drains first;
/// only once it is empty does the monthly allowance move.
///
/// `monthResetAt` is a unix timestamp (the wire contract's shape), deliberately decoded as an
/// `Int` rather than a `Date`: `CloudImportClient` decodes every payload with the `.iso8601`
/// date strategy, and an int date there would fail the whole response.
public struct Quota: Codable, Equatable, Sendable {
    public var initialRemaining: Int
    public var monthRemaining: Int
    public var monthResetAt: Int
    public var initialLimit: Int
    public var monthLimit: Int

    public init(initialRemaining: Int, monthRemaining: Int, monthResetAt: Int,
                initialLimit: Int, monthLimit: Int) {
        self.initialRemaining = initialRemaining
        self.monthRemaining = monthRemaining
        self.monthResetAt = monthResetAt
        self.initialLimit = initialLimit
        self.monthLimit = monthLimit
    }

    /// Videos this user can still submit right now, across both budgets.
    public var remaining: Int { initialRemaining + monthRemaining }

    public var monthResetDate: Date { Date(timeIntervalSince1970: TimeInterval(monthResetAt)) }
}

// MARK: - Errors

/// The two failures every /v1 caller has to understand. Everything else stays each client's
/// own error type (`BoxError`, `CloudImportError`).
/// ponytail: one shared error rather than a quota case duplicated into both — the UI only
/// ever needs "who are you" and "you're out of budget".
public enum StashError: Error, Equatable, LocalizedError {
    /// No session, or the refresh token was rejected. The session owner has already signed out.
    case unauthenticated
    case quotaExhausted(Quota)

    public var errorDescription: String? {
        switch self {
        case .unauthenticated:
            "Your Stash session has expired — sign in again."
        case .quotaExhausted(let quota):
            "Import budget used up. \(quota.monthLimit) more videos on "
                + quota.monthResetDate.formatted(date: .abbreviated, time: .omitted) + "."
        }
    }
}

// MARK: - Provider

/// The app's session, reduced to what the networking layer needs.
public struct StashAuthProvider: Sendable {
    /// The current bearer, refreshed by the owner when it is close to expiring. nil = signed out.
    public var token: @Sendable () async -> String?
    /// Forces one refresh after a 401 and returns the new bearer, or nil to give up (the owner
    /// signs the user out). MUST be single-flight: several requests can 401 at the same moment.
    public var refresh: @Sendable () async -> String?
    /// Receives the quota carried by any response that reports one, so the in-app counter stays
    /// fresh without an extra round trip.
    public var quotaChanged: @Sendable (Quota) -> Void

    public init(
        token: @escaping @Sendable () async -> String?,
        refresh: @escaping @Sendable () async -> String?,
        quotaChanged: @escaping @Sendable (Quota) -> Void
    ) {
        self.token = token
        self.refresh = refresh
        self.quotaChanged = quotaChanged
    }

    /// A fixed token with no refresh and nowhere to publish quota — local-box development
    /// and tests, never the shipping path.
    public static func fixed(_ token: @escaping @Sendable () -> String?) -> StashAuthProvider {
        StashAuthProvider(token: token, refresh: { nil }, quotaChanged: { _ in })
    }
}

// MARK: - Transport

public enum StashHTTP {
    /// Quota rides in a header on routes whose body is not JSON (the mp4 download).
    public static let quotaHeader = "X-Stash-Quota"

    /// Sends an authorized request. Refreshes once on 401, decodes 402 into
    /// `StashError.quotaExhausted`, publishes any quota it sees, and hands every other status
    /// back to the caller to validate with its own rules. Transport errors are rethrown raw so
    /// callers can keep mapping them (e.g. `BoxError.unreachable`).
    public static func send(
        _ request: URLRequest,
        on session: URLSession,
        auth: StashAuthProvider
    ) async throws -> (Data, HTTPURLResponse) {
        guard let token = await auth.token() else { throw StashError.unauthenticated }
        var (data, http) = try await perform(request, bearer: token, on: session)

        if http.statusCode == 401 {
            guard let refreshed = await auth.refresh() else { throw StashError.unauthenticated }
            (data, http) = try await perform(request, bearer: refreshed, on: session)
            if http.statusCode == 401 { throw StashError.unauthenticated }
        }

        if http.statusCode == 402, let quota = quota(fromBody: data) {
            auth.quotaChanged(quota)
            throw StashError.quotaExhausted(quota)
        }
        if let header = http.value(forHTTPHeaderField: quotaHeader),
           let quota = quota(fromHeader: header) {
            auth.quotaChanged(quota)
        }
        return (data, http)
    }

    private static func perform(
        _ request: URLRequest,
        bearer: String,
        on session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        var authorized = request
        authorized.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: authorized)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// `{"detail": "quota exhausted", "quota": {…}}` — nil when the 402 body is something else,
    /// in which case the caller's normal non-2xx handling applies.
    ///
    /// Also accepts the same object nested under `detail`: FastAPI's HTTPException handler
    /// wraps whatever it is given one level deeper, and a quota the client cannot read is a
    /// quota the counter cannot show.
    public static func quota(fromBody data: Data) -> Quota? {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(QuotaEnvelope.self, from: data) { return envelope.quota }
        return try? decoder.decode(NestedQuotaEnvelope.self, from: data).detail.quota
    }

    public static func quota(fromHeader value: String) -> Quota? {
        try? JSONDecoder().decode(Quota.self, from: Data(value.utf8))
    }

    private struct QuotaEnvelope: Decodable { let quota: Quota }
    private struct NestedQuotaEnvelope: Decodable { let detail: QuotaEnvelope }
}
