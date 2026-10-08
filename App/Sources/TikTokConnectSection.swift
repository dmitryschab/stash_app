// TikTokConnectSection.swift
//
// Settings → TikTok: real TikTok sign-in, part one of the integration
// (docs/superpowers/specs/2026-09-13-tiktok-oauth-p1-design.md). `TikTokLogin` runs the SDK and
// the box trades its code for tokens (`TikTokConnectClient`). The sign-in screen's "Continue with
// TikTok" runs the same `TikTokLogin` and lands on POST /v1/auth/tiktok instead.
//
// Part two syncs Favorite Videos through the connection (`PipelineCenter.syncTikTok`), but only
// once the build asks for the portability scopes (`TIKTOK_SCOPES`), which the sandbox credentials
// do not have — so nothing comes in yet, and the section is only offered in Debug and TestFlight
// builds (`isOffered`).
//
// The approved Data Portability application covers the EEA and the UK only, told apart by the
// App Store storefront (`regionStorefront`). Anywhere else the section says so instead of
// offering to connect; an account already connected keeps its row and can still disconnect.

import SwiftUI
import StoreKit
import TikTokBrainKit
import TikTokOpenAuthSDK

struct TikTokConnectSection: View {
    private var session = StashSession.shared
    private var center = PipelineCenter.shared
    /// Connecting or disconnecting; either way the button waits.
    @State private var isWorking = false
    @State private var failure: String?
    /// The storefront a connect sends, from `regionStorefront`; nil offers no connect button.
    let storefront: String?

    init(storefront: String?) {
        self.storefront = storefront
    }

    var body: some View {
        Section("TikTok") {
            if let connection = session.tiktok {
                // `user.info.basic` carries the display name, not the @handle. The box leaves it
                // empty when TikTok's profile call failed, and the row then just says connected.
                LabeledContent(connection.displayName.isEmpty ? "Connected" : "Connected as") {
                    Text(connection.displayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let note = syncNote(connection) {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
                Button { disconnect() } label: {
                    if isWorking { Text("Disconnecting…") } else { Text("Disconnect") }
                }
                .disabled(isWorking)
            } else if let storefront {
                Button { connect(storefront: storefront) } label: {
                    if isWorking { Text("Connecting…") } else { Text("Connect TikTok") }
                }
                .disabled(isWorking)
            } else {
                Text("TikTok sync is available in the EEA and the UK.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(Color.categoryRecipe)
            }
        }
    }

    /// "Waiting for TikTok…" while a data request is out, else when the last archive came in.
    /// Nothing before the first sync, which is all a sandbox connection ever has.
    private func syncNote(_ connection: TikTokConnection) -> String? {
        if center.tiktokSyncWaiting { return "Waiting for TikTok…" }
        guard let syncedAt = connection.lastSyncAt else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(syncedAt))
        return "Synced \(date.formatted(.relative(presentation: .named)))"
    }

    /// Debug and TestFlight builds only, until part two imports something: in an App Store build
    /// a connect row that brings nothing in risks guideline 2.2. TestFlight and Xcode builds sign
    /// a sandbox AppTransaction; one that cannot be fetched or verified hides the row.
    static func isOffered() async -> Bool {
        #if DEBUG
        return true
        #else
        // Someone who signed in with TikTok must be able to disconnect it.
        if TikTokLogin.signInEnabled { return true }
        guard case .verified(let app)? = try? await AppTransaction.shared else { return false }
        return app.environment != .production
        #endif
    }

    /// The App Store storefront's alpha-3 code when it is one of
    /// `TikTokConnectClient.allowedStorefronts`; nil anywhere else and when StoreKit cannot say,
    /// both of which the box would refuse anyway.
    static func regionStorefront() async -> String? {
        guard let code = await Storefront.current?.countryCode.uppercased(),
              TikTokConnectClient.allowedStorefronts.contains(code) else { return nil }
        return code
    }

    private func connect(storefront: String) {
        failure = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                guard let grant = try await TikTokLogin.authorize() else { return }
                session.tiktok = try await TikTokConnectClient(config: PipelineCenter.currentConfig())
                    .connect(code: grant.code, codeVerifier: grant.verifier, storefront: storefront)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func disconnect() {
        failure = nil
        isWorking = true
        Task {
            do {
                try await TikTokConnectClient(config: PipelineCenter.currentConfig()).disconnect()
                session.tiktok = nil
            } catch {
                failure = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// One TikTok Login Kit round trip, for Settings → Connect TikTok and for the sign-in screen. The
/// SDK opens the TikTok app, or its own in-app browser when TikTok is not installed, and ends in
/// an authorization code; the box trades it with the PKCE verifier, so the client secret never
/// reaches the phone.
@MainActor
enum TikTokLogin {
    /// Registered on the TikTok developer portal and claimed by the app as a universal link.
    static let redirectURI = "https://stash.dmitrijs.dev/tiktok/callback"

    /// The request in flight. The SDK only keeps a weak reference to it, so a request nobody
    /// holds is gone before TikTok answers and the answer lands nowhere.
    private static var inFlight: TikTokAuthRequest?

    /// "Continue with TikTok" on the sign-in screen: `TIKTOK_SIGN_IN` in project.yml, and always
    /// in Debug so the sandbox flow can be tried before TikTok approves Login Kit.
    static var signInEnabled: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.object(forInfoDictionaryKey: "TikTokSignIn") as? String == "YES"
        #endif
    }

    /// The code and its verifier, or nil when the user closed the sheet or declined in TikTok —
    /// their own no, which says nothing worth showing. Throws `TikTokConnectError.unreachable`
    /// for every other failure.
    static func authorize() async throws -> (code: String, verifier: String)? {
        let request = TikTokAuthRequest(scopes: scopes, redirectURI: redirectURI)
        // Read now: capturing the request in its own completion would keep it alive for good,
        // still registered for every TikTok URL that comes in later.
        let verifier = request.pkce.codeVerifier
        inFlight = request
        defer { inFlight = nil }
        let response: TikTokAuthResponse? = await withCheckedContinuation { continuation in
            var answered = false   // the SDK calls back on every response URL; resume only once
            let sent = request.send { response in
                guard !answered else { return }
                answered = true
                continuation.resume(returning: response as? TikTokAuthResponse)
            }
            // A request that was not sent never calls back.
            if !sent { continuation.resume(returning: nil) }
        }
        switch response?.errorCode {
        case .noError?:
            if let code = response?.authCode, !code.isEmpty { return (code, verifier) }
        case .cancelled?, .denied?:
            return nil
        default:
            break
        }
        // The SDK's own words are for whoever is debugging a sandbox setup, not for the screen.
        NSLog("TikTok sign-in failed (%@): %@", "\(response?.errorCode.rawValue ?? 0)",
              response?.errorDescription ?? "no response")
        throw TikTokConnectError.unreachable
    }

    /// `TIKTOK_SCOPES` in project.yml, comma-separated: `user.info.basic` alone until the build
    /// switches to production credentials, which add the two portability scopes.
    private static var scopes: Set<String> {
        let list = Bundle.main.object(forInfoDictionaryKey: "TikTokScopes") as? String ?? ""
        return Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }
}
