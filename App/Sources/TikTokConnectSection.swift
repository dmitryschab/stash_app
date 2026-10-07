// TikTokConnectSection.swift
//
// Settings → TikTok: real TikTok sign-in, part one of the integration
// (docs/superpowers/specs/2026-09-13-tiktok-oauth-p1-design.md). The SDK opens the TikTok app,
// or its own in-app browser when TikTok is not installed, and ends in an authorization code; the
// box trades that code and the PKCE verifier for tokens (`TikTokConnectClient`), so the client
// secret never reaches the phone.
//
// Part two syncs Favorite Videos through the connection (`PipelineCenter.syncTikTok`), but only
// once the build asks for the portability scopes (`TIKTOK_SCOPES`), which the sandbox credentials
// do not have — so nothing comes in yet, and the section is only offered in Debug and TestFlight
// builds (`isOffered`).

import SwiftUI
import StoreKit
import TikTokBrainKit
import TikTokOpenAuthSDK

struct TikTokConnectSection: View {
    private var session = StashSession.shared
    private var center = PipelineCenter.shared
    /// The sign-in in flight. The SDK only keeps a weak reference to it, so a request nobody
    /// holds is gone before TikTok answers and the answer lands nowhere.
    @State private var request: TikTokAuthRequest?
    /// Connecting or disconnecting; either way the button waits.
    @State private var isWorking = false
    @State private var failure: String?

    /// Registered on the TikTok developer portal and claimed by the app as a universal link.
    static let redirectURI = "https://stash.dmitrijs.dev/tiktok/callback"

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
            } else {
                Button { connect() } label: {
                    if isWorking { Text("Connecting…") } else { Text("Connect TikTok") }
                }
                .disabled(isWorking)
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

    /// `TIKTOK_SCOPES` in project.yml, comma-separated: `user.info.basic` alone until the build
    /// switches to production credentials, which add the two portability scopes.
    private static var scopes: Set<String> {
        let list = Bundle.main.object(forInfoDictionaryKey: "TikTokScopes") as? String ?? ""
        return Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// Debug and TestFlight builds only, until part two imports something: in an App Store build
    /// a connect row that brings nothing in risks guideline 2.2. TestFlight and Xcode builds sign
    /// a sandbox AppTransaction; one that cannot be fetched or verified hides the row.
    static func isOffered() async -> Bool {
        #if DEBUG
        return true
        #else
        guard case .verified(let app)? = try? await AppTransaction.shared else { return false }
        return app.environment != .production
        #endif
    }

    private func connect() {
        failure = nil
        let request = TikTokAuthRequest(scopes: Self.scopes, redirectURI: Self.redirectURI)
        // Read now and captured by value: capturing the request in its own completion would
        // keep it alive for good, still registered for every TikTok URL that comes in later.
        let verifier = request.pkce.codeVerifier
        self.request = request
        isWorking = true
        let sent = request.send { response in
            Task { @MainActor in await finish(response as? TikTokAuthResponse, verifier: verifier) }
        }
        if !sent { Task { await finish(nil, verifier: verifier) } }
    }

    private func finish(_ response: TikTokAuthResponse?, verifier: String) async {
        defer {
            request = nil
            isWorking = false
        }
        switch response?.errorCode {
        case .noError?:
            guard let code = response?.authCode, !code.isEmpty else { break }
            do {
                session.tiktok = try await TikTokConnectClient(config: PipelineCenter.currentConfig())
                    .connect(code: code, codeVerifier: verifier)
            } catch {
                failure = error.localizedDescription
            }
            return
        case .cancelled?, .denied?:
            return   // the user's own no — closing the sheet or declining in TikTok says nothing
        default:
            break
        }
        // The SDK's own words are for whoever is debugging a sandbox setup, not for the row.
        NSLog("TikTok sign-in failed (%@): %@", "\(response?.errorCode.rawValue ?? 0)",
              response?.errorDescription ?? "no response")
        failure = TikTokConnectError.unreachable.localizedDescription
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
