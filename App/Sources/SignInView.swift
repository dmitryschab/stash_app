// SignInView.swift
//
// The gate. Nothing else in the app renders until StashSession holds a server-verified
// session, so this is also the only screen that ever talks to Apple.
//
// Sign in with Apple is the sole method — no email/password, no anonymous mode — and the
// request asks for NO scopes: the contract only needs the identity token's `sub`, and asking
// for .email/.fullName would add data types to PrivacyInfo.xcprivacy and to the App Store
// privacy answers for nothing. The button is Apple's own `SignInWithAppleButton`; custom-drawn
// lookalikes get rejected.
//
// The invite field stays hidden until the server answers 403 "invite required", so returning
// users are never asked for a code they do not have.
//
// This is also where the two disclosures live, because it is the last screen before any data
// moves: who processes the saves (Groq, AWS Bedrock — guideline 5.1.2(i)) and what pressing
// the button agrees to (guideline 5.1.1(i)). Consent is by continuation, not a checkbox, so
// the "By continuing…" line sits directly above the Apple button with both documents linked.

import AuthenticationServices
import SwiftUI
import TikTokBrainKit

struct SignInView: View {
    private var session = StashSession.shared

    @State private var inviteCode = ""
    @State private var needsInvite = false
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            appTile
            HStack(spacing: 8) {
                ForEach(librarySegments, id: \.self) { category in
                    Circle().fill(category.color).frame(width: 9, height: 9)
                }
            }
            .padding(.top, 16)

            Text("Your saves, sorted")
                .font(.archivo(27, .heavy))
                .foregroundStyle(Color.stashInk)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
            Text("Stash turns the videos you bookmark on TikTok into a searchable library. Sign in to keep it yours.")
                .font(.archivo(14))
                .foregroundStyle(Color.stashInk.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 300)
                .padding(.top, 10)

            if needsInvite { inviteField.padding(.top, 24) }
            if let error { errorLine(error).padding(.top, 18) }

            Spacer()

            InfoChip(text: "Apple shares only an anonymous ID", systemImage: "lock.fill")
                .padding(.bottom, 16)

            cloudNote
            consentLine.padding(.top, 12).padding(.bottom, 16)

            SignInWithAppleButton(.signIn, onRequest: { request in
                request.requestedScopes = []
            }, onCompletion: handle)
            .signInWithAppleButtonStyle(.black)
            .frame(height: 52)
            .clipShape(Capsule())
            .disabled(isWorking)
            .opacity(isWorking ? 0.5 : 1)
            .overlay {
                if isWorking { ProgressView().tint(.stashOnInk) }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.stashBackground.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: needsInvite)
    }

    /// Guideline 5.1.2(i): the two third parties that see the user's saves, named before the
    /// account exists rather than in a policy page nobody opens. Deliberately the same two names
    /// the privacy policy lists as sub-processors — Groq gets the audio, Bedrock gets the text.
    private var cloudNote: some View {
        Text("To sort your saves, Stash sends their audio to Groq for speech-to-text and their text to AWS Bedrock for analysis.")
            .font(.archivo(12))
            .foregroundStyle(Color.stashInk.opacity(0.55))
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .frame(maxWidth: 320)
    }

    /// Consent is by continuation — there is no checkbox anywhere — so the agreement has to be
    /// stated on the button the user is about to press, with both documents one tap away.
    private var consentLine: some View {
        Text("By continuing you agree to the [Terms](https://stash.dmitrijs.dev/terms) and [Privacy Policy](https://stash.dmitrijs.dev/privacy).")
            .font(.archivo(12, .semibold))
            .foregroundStyle(Color.stashInk.opacity(0.55))
            .tint(Color.stashInk)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
    }

    /// The ink app tile with the cream bookmark mark (same mark as the connect flow).
    private var appTile: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.stashInk)
            .frame(width: 88, height: 88)
            .overlay(
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Color.stashOnInk)
            )
            .shadow(color: .black.opacity(0.22), radius: 15, y: 8)
    }

    private var inviteField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Micro(text: "Invite code", size: 10, tracking: 1.8)
            TextField("", text: $inviteCode)
                .font(.archivo(17, .semibold))
                .foregroundStyle(Color.stashInk)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(Color.stashSurface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.stashInk.opacity(0.3), lineWidth: 1.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorLine(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .bold))
            Text(message)
                .font(.archivo(13, .semibold))
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(Color.categoryRecipe)
    }

    // MARK: - Apple

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let failure):
            // A user-cancelled sheet is not an error worth shouting about.
            guard (failure as? ASAuthorizationError)?.code != .canceled else { return }
            error = failure.localizedDescription
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken else {
                error = "Apple did not return an identity token. Try again."
                return
            }
            // The authorization code is one-time and only present on a fresh authorization. It
            // is the only way the server can get the Apple refresh token that DELETE /v1/me
            // revokes with (guideline 5.1.1(v)), so it must be sent here, not at deletion time.
            // ponytail: accounts created before this shipped have no stored Apple token and
            // stay unrevocable until they sign out and back in — not worth a forced re-auth.
            signIn(identityToken: String(decoding: tokenData, as: UTF8.self),
                   appleUserID: credential.user,
                   authorizationCode: credential.authorizationCode
                       .map { String(decoding: $0, as: UTF8.self) })
        }
    }

    private func signIn(identityToken: String, appleUserID: String, authorizationCode: String?) {
        isWorking = true
        error = nil
        Task {
            let code = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try await session.signIn(identityToken: identityToken,
                                         appleUserID: appleUserID,
                                         authorizationCode: authorizationCode,
                                         inviteCode: code.isEmpty ? nil : code)
            } catch StashSessionError.inviteRequired {
                error = code.isEmpty
                    ? StashSessionError.inviteRequired.localizedDescription
                    : "That invite code was not accepted."
                needsInvite = true
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}

#Preview {
    SignInView()
}
