// StashSession.swift
//
// The single owner of who the user is. Sign in with Apple hands us an identity token, the
// server verifies it against Apple's JWKS and returns a Stash JWT plus an opaque refresh
// token; both live in ONE Keychain item (never UserDefaults, never a compiled-in bearer)
// so refresh-token rotation is atomic — two items can be torn by a crash mid-rotation and
// leave the app holding a revoked token it cannot rotate away from.
//
// `kSecAttrAccessibleAfterFirstUnlock`, deliberately not `WhenUnlocked`: the BGProcessingTask
// registered in TikTokBrainApp.init fires while the device is locked and must still read the
// token. Not synchronizable — a session belongs to this device.
//
// Everything else in the app reaches auth through `StashSession.authProvider`, the three
// closures the Kit's networking funnel needs (see StashAuth.swift).

import AuthenticationServices
import Foundation
import Observation
import TikTokBrainKit

// MARK: - Errors

enum StashSessionError: Error, LocalizedError, Equatable {
    /// A code was supplied on first sign-in and the server refused it: 403. Sign-up itself is
    /// open, so this never fires for a buyer who left the field alone.
    case codeRejected
    case invalidAppleToken
    case notSignedIn
    case server(Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .codeRejected: "That code was not accepted."
        case .invalidAppleToken: "Apple could not verify that sign-in. Try again."
        case .notSignedIn: "You are signed out."
        case .server(let status): "The Stash server refused the request (HTTP \(status))."
        case .transport(let message): "Could not reach Stash: \(message)"
        }
    }
}

// MARK: - Session

@MainActor
@Observable
final class StashSession {
    static let shared = StashSession()

    enum State: Equatable {
        case unknown          // Keychain not read yet — show a splash, not the sign-in gate
        case signedOut
        case signedIn(userID: String)
    }

    private(set) var state: State = .unknown
    /// The live budget, refreshed from every quota-carrying response and from GET /v1/me.
    private(set) var quota: Quota?
    /// This account was created from a `--demo` invite (App Review). RootView seeds the
    /// sample library off it. Kept in the Keychain blob alongside the tokens so it is known
    /// the instant `state` flips, rather than one /v1/me round trip later.
    private(set) var isDemoAccount = false
    /// Whether the server will let this account spend money — a live subscription, a
    /// grandfathered 1.0 purchase, or a demo account. Cached in the Keychain alongside the
    /// tokens so a returning subscriber does not get a frame of paywall on every cold launch;
    /// `Subscription` re-posts the real StoreKit state moments later and corrects it.
    ///
    /// Advisory on this side. The server re-checks on every metered route, so nothing is
    /// unlocked by lying to this property — the app just gets 402s instead of a paywall.
    private(set) var isEntitled = false

    /// The account is running on its free fifty and has some left. Read from the quota the
    /// server reports, never cached in the Keychain — unlike `isEntitled` this one is spent
    /// by using the app, so a stale copy is a copy that is wrong within a session.
    ///
    /// `quota == nil` means "not asked yet", which reads as false here. Callers that must not
    /// act on an unknown check `quota != nil` as well (see `RootView.paidShell`).
    var isOnTrial: Bool { quota?.isOnTrial ?? false }
    var lastAuthError: String?

    var isSignedIn: Bool { if case .signedIn = state { return true }; return false }
    var userID: String? { if case .signedIn(let id) = state { return id }; return nil }

    /// Refresh this long before `expiresAt` rather than waiting for a 401 mid-drain.
    private static let refreshWindow: TimeInterval = 24 * 60 * 60
    private var stored: StoredSession?
    private var refreshTask: Task<String?, Never>?

    private init() {}

    // MARK: Kit wiring

    /// The seam every network client gets. `nonisolated` so it can be built from anywhere;
    /// the closures hop back to the main actor themselves.
    nonisolated static var authProvider: StashAuthProvider {
        StashAuthProvider(
            token: { await StashSession.shared.bearerToken() },
            refresh: { await StashSession.shared.refreshNow() },
            quotaChanged: { quota in Task { @MainActor in StashSession.shared.quota = quota } }
        )
    }

    // MARK: Lifecycle

    /// Reads the Keychain and asks Apple whether the credential is still ours. Called once
    /// from RootView; leaves `state` at `.signedOut` when there is nothing to restore.
    func restore() async {
        // Only ever resolves the `.unknown` launch state; a signed-in session is not re-read.
        guard case .unknown = state else { return }
        #if DEBUG
        // The seeded simulator smoke run has no server and no Apple ID — let it through.
        if Self.isSmokeRun {
            // No server, no App Store, no receipts — screenshot and XCUITest runs need the
            // shell, not a checkout they cannot complete.
            isEntitled = true
            state = .signedIn(userID: "simulator")
            return
        }
        #endif
        guard let stored = StashKeychain.load() else {
            state = .signedOut
            return
        }
        // The user can revoke us in Settings → Apple ID → Sign in with Apple, outside the app.
        // Checked before the state flips, so a revoked account never gets a frame of the shell
        // or the burst of authenticated work that follows it.
        let credential = try? await ASAuthorizationAppleIDProvider()
            .credentialState(forUserID: stored.appleUserID)
        if credential == .revoked || credential == .notFound {
            signOut()
            return
        }
        self.stored = stored
        isDemoAccount = stored.demo == true
        isEntitled = stored.entitled == true
        state = .signedIn(userID: stored.userID)
        await refreshQuota()
    }

    /// Exchanges an Apple identity token for a Stash session. The invite code is only sent
    /// when the caller has one; the server demands it on a first-time `sub`. The one-time
    /// authorization code is what the server trades for the Apple refresh token it needs to
    /// revoke the grant on account deletion — sign-in still succeeds without it.
    func signIn(identityToken: String, appleUserID: String,
                authorizationCode: String?, inviteCode: String?) async throws {
        let response: AuthResponse = try await post(
            path: "auth/apple",
            body: AppleSignInRequest(identityToken: identityToken,
                                     authorizationCode: authorizationCode,
                                     inviteCode: inviteCode),
            mapping: { status in
                switch status {
                case 401: StashSessionError.invalidAppleToken
                case 403: StashSessionError.codeRejected
                default: StashSessionError.server(status)
                }
            })
        guard let userID = response.userID else {
            throw StashSessionError.transport("sign-in response carried no userID")
        }
        apply(response, appleUserID: appleUserID, userID: userID)
        lastAuthError = nil
    }

    /// Drops the session everywhere: Keychain first, so a crash mid-sign-out cannot leave a
    /// token on disk that no screen is showing.
    func signOut() {
        StashKeychain.clear()
        stored = nil
        quota = nil
        isDemoAccount = false
        // Not carried across accounts: the next Apple ID to sign in on this device has its
        // own subscription, or none, and inheriting this one would hand it the app for free.
        isEntitled = false
        state = .signedOut
    }

    // MARK: Tokens

    /// The only token accessor the rest of the app uses. Refreshes ahead of expiry so a long
    /// background drain does not start every request with a doomed round trip.
    func bearerToken() async -> String? {
        guard let stored else { return nil }
        guard stored.expiresAt.timeIntervalSinceNow > Self.refreshWindow else {
            if let refreshed = await refreshNow() { return refreshed }
            return self.stored?.token   // re-read: a failed refresh may have signed us out
        }
        return stored.token
    }

    /// Single-flight refresh. A drain can 401 on several requests at once, and each response
    /// would otherwise POST the same refresh token — the first rotation revokes it and every
    /// other call would sign the user out. The stored task is the lock; main-actor isolation
    /// makes the check-and-set atomic.
    @discardableResult
    func refreshNow() async -> String? {
        if let refreshTask { return await refreshTask.value }
        let task = Task<String?, Never> { [weak self] in
            await self?.performRefresh() ?? nil
        }
        refreshTask = task
        let token = await task.value
        refreshTask = nil
        return token
    }

    private func performRefresh() async -> String? {
        guard let stored else { return nil }
        do {
            let response: AuthResponse = try await post(
                path: "auth/refresh",
                body: RefreshRequest(refreshToken: stored.refreshToken),
                mapping: { StashSessionError.server($0) })
            apply(response, appleUserID: stored.appleUserID, userID: stored.userID)
            return response.token
        } catch StashSessionError.server(401) {
            // The refresh token is gone or already rotated — nothing left to recover with.
            signOut()
            lastAuthError = StashSessionError.notSignedIn.localizedDescription
            return nil
        } catch {
            // Offline or a server hiccup: keep the session, the old token may still work.
            lastAuthError = error.localizedDescription
            return nil
        }
    }

    private func apply(_ response: AuthResponse, appleUserID: String, userID: String) {
        // Both /auth routes report `demo`; `??` only covers a server older than build 14.
        isDemoAccount = response.demo ?? isDemoAccount
        isEntitled = response.entitled ?? isEntitled
        let session = StoredSession(
            appleUserID: appleUserID,
            userID: userID,
            token: response.token,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(response.expiresAt)),
            refreshToken: response.refreshToken,
            demo: isDemoAccount,
            entitled: isEntitled)
        StashKeychain.save(session)
        stored = session
        state = .signedIn(userID: userID)
        if let quota = response.quota { self.quota = quota }
    }

    // MARK: Account (App Store guideline 5.1.1(v))

    func refreshQuota() async {
        guard isSignedIn else { return }
        do {
            let me: MeResponse = try await authorized(path: "me", method: "GET")
            quota = me.quota
            // /v1/me is the only place a reinstall can learn this: the Keychain went with
            // the old install, so the restored session may not carry the flag yet.
            if let demo = me.demo { isDemoAccount = demo }
            if let entitled = me.entitled { setEntitled(entitled) }
        } catch {
            // A stale counter is not worth a visible error; the next quota-carrying call fixes it.
            NSLog("StashSession: quota refresh failed: %@", String(describing: error))
        }
    }

    // MARK: Entitlement

    /// Hand the box whatever StoreKit signed and take its answer as the truth.
    ///
    /// Called on launch, after a purchase and after a restore. Both blobs are optional and
    /// sending neither is a legitimate outcome — it means this Apple ID has nothing, which
    /// is precisely what the server should record. Verification happens there, against
    /// Apple's root CA; nothing this method sends is trusted on the strength of having been
    /// sent by us.
    @discardableResult
    func syncEntitlement(signedTransaction: String?, signedAppTransaction: String?) async -> Bool {
        guard isSignedIn else { return isEntitled }
        do {
            let response: SubscriptionResponse = try await authorized(
                path: "me/subscription", method: "POST",
                body: SubscriptionRequest(signedTransaction: signedTransaction,
                                          signedAppTransaction: signedAppTransaction))
            setEntitled(response.entitled)
        } catch {
            // Offline on launch must not lock a paying subscriber out of their own library:
            // keep the cached answer and let the next launch, or the next 402, settle it.
            NSLog("StashSession: entitlement sync failed: %@", String(describing: error))
        }
        return isEntitled
    }

    /// The server said 402 on a metered route. Drop the cached yes so the paywall appears
    /// without waiting for a relaunch.
    func entitlementRefused() {
        setEntitled(false)
    }

    private func setEntitled(_ value: Bool) {
        isEntitled = value
        // Re-save so the next cold launch opens on the library rather than the paywall.
        guard let stored, stored.entitled != value else { return }
        let updated = StoredSession(
            appleUserID: stored.appleUserID, userID: stored.userID, token: stored.token,
            expiresAt: stored.expiresAt, refreshToken: stored.refreshToken,
            demo: stored.demo, entitled: value)
        StashKeychain.save(updated)
        self.stored = updated
    }

    /// Deletes every server-side item for this user, then wipes the local session. The caller
    /// is responsible for the on-device library (see SettingsView).
    func deleteAccount() async throws {
        _ = try await authorizedData(path: "me", method: "DELETE")
        SampleData.forgetDemoSeed()
        signOut()
    }

    /// Everything Stash holds server-side, as the raw JSON the box streamed. Handed back
    /// undecoded: SettingsView merges it with the on-device library, which the box has never
    /// seen, and re-encoding here would be one more chance to drop a field the user is owed.
    func serverExport() async throws -> Data {
        try await authorizedData(path: "me/export", method: "GET")
    }

    // MARK: Requests

    private static var baseURL: URL? {
        URL(string: UserDefaults.standard.string(forKey: "boxBaseURL") ?? BoxDefaults.baseURL)
    }

    /// Unauthenticated POST (the /v1/auth/* pair). `mapping` names the failure statuses that
    /// mean something specific to the caller.
    private func post<T: Decodable>(
        path: String,
        body: some Encodable,
        mapping: (Int) -> StashSessionError
    ) async throws -> T {
        guard let base = Self.baseURL else { throw StashSessionError.transport("bad base URL") }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw StashSessionError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw StashSessionError.transport("invalid HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else { throw mapping(http.statusCode) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw StashSessionError.transport("invalid response: \(error.localizedDescription)")
        }
    }

    /// Authenticated call through the shared funnel, so /v1/me inherits the same one-shot
    /// 401 refresh as every other route.
    private func authorizedData(path: String, method: String,
                                body: (some Encodable)? = Optional<Never>.none) async throws -> Data {
        guard let base = Self.baseURL else { throw StashSessionError.transport("bad base URL") }
        guard isSignedIn else { throw StashSessionError.notSignedIn }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await StashHTTP.send(
                request, on: .shared, auth: Self.authProvider)
        } catch StashError.unauthenticated {
            throw StashSessionError.notSignedIn
        } catch {
            throw StashSessionError.transport(error.localizedDescription)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw StashSessionError.server(http.statusCode)
        }
        return data
    }

    private func authorized<T: Decodable>(
        path: String, method: String,
        body: (some Encodable)? = Optional<Never>.none
    ) async throws -> T {
        let data = try await authorizedData(path: path, method: method, body: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw StashSessionError.transport("invalid response: \(error.localizedDescription)")
        }
    }

    // MARK: Wire types

    private struct AppleSignInRequest: Encodable {
        let identityToken: String
        let authorizationCode: String?   // omitted when nil, as is `inviteCode`
        let inviteCode: String?
    }

    private struct RefreshRequest: Encodable {
        let refreshToken: String
    }

    /// Shared by /v1/auth/apple and /v1/auth/refresh; only the former carries `userID`.
    private struct AuthResponse: Decodable {
        let token: String
        let expiresAt: Int        // unix seconds, not ISO-8601
        let refreshToken: String
        let userID: String?
        let quota: Quota?
        let demo: Bool?
        let entitled: Bool?
    }

    private struct MeResponse: Decodable {
        let userID: String
        let quota: Quota?
        let demo: Bool?
        let entitled: Bool?
    }

    private struct SubscriptionRequest: Encodable {
        let signedTransaction: String?
        let signedAppTransaction: String?
    }

    private struct SubscriptionResponse: Decodable {
        let entitled: Bool
    }

    #if DEBUG
    /// `-seedSample` / `-seedFile` runs render the shell against seeded data, no server.
    private static var isSmokeRun: Bool {
        CommandLine.arguments.contains("-seedSample")
            || CommandLine.arguments.contains("-seedFile")
    }

    /// Lets SwiftUI previews render the tab shell instead of the gate.
    static func signInForPreview() {
        shared.isEntitled = true
        shared.state = .signedIn(userID: "preview")
    }
    #endif
}

// MARK: - Keychain

/// One `kSecClassGenericPassword` item holding the whole session as JSON.
private enum StashKeychain {
    private static let service = "dev.dmitryschab.Stash"
    private static let account = "stashSession"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func load() -> StoredSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    static func save(_ session: StoredSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var insert = baseQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

private struct StoredSession: Codable {
    /// Apple's stable `sub` for this app — the only id `getCredentialState` accepts.
    let appleUserID: String
    /// The server's opaque id, used for display and as the Dynamo partition key.
    let userID: String
    let token: String
    let expiresAt: Date
    let refreshToken: String
    /// Optional so a blob written by build ≤13 still decodes — a non-optional `Bool` would
    /// fail the whole item and sign every upgrading user out.
    let demo: Bool?
    /// Same reasoning, one release later: blobs written by build ≤24 predate the paywall.
    /// `nil` reads as "not entitled", which fails closed — the worst case is one paywall
    /// frame before `Subscription` posts the real receipt.
    let entitled: Bool?
}
