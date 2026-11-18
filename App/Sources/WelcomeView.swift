// WelcomeView.swift
//
// The first thing a new account sees, once and once only: what the free fifty are, what
// happens after them, and what it costs. It sits between sign-in and the shell.
//
// It exists because the alternative is worse in both directions. Without it, a new user
// spends fifty videos not knowing there is a limit and meets the paywall as a surprise —
// the shape of dark pattern Apple rejects and users resent. And a trial announced only in
// the App Store listing is a trial nobody read about.
//
// The number is the server's, not ours. `TRIAL_LIMIT` lives in cloud_import_models.py and the
// quota response carries it, so raising the trial never means shipping an app to correct a
// screen that lies about it. The one hardcoded fallback is for the frame before /v1/me
// answers, and it says "free videos" rather than a count.

import SwiftUI
import TikTokBrainKit

struct WelcomeView: View {
    /// Called when the reader dismisses it. RootView records that this account has seen it.
    let onContinue: () -> Void

    private var session = StashSession.shared

    init(onContinue: @escaping () -> Void) {
        self.onContinue = onContinue
    }

    private var count: Int? {
        guard let quota = session.quota, quota.trialLimit > 0 else { return nil }
        return quota.trialLimit
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                appTile.padding(.top, 40)

                Text(count.map { "\($0) videos on us" } ?? "Free videos on us")
                    .font(.archivo(30, .heavy))
                    .foregroundStyle(Color.stashInk)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 24)

                Text(count.map {
                    "Import your TikTok saves and Stash reads the first \($0) for free. No card, nothing to cancel."
                } ?? "Import your TikTok saves and Stash reads the first batch for free. No card, nothing to cancel.")
                    .font(.archivo(14))
                    .foregroundStyle(Color.stashInk.opacity(0.62))
                    .multilineTextAlignment(.leading)
                    .lineSpacing(4)
                    .frame(maxWidth: 310, alignment: .leading)
                    .padding(.top, 10)

                steps.padding(.top, 30)

                // Named up front rather than discovered at the end. A trial whose price only
                // appears once it runs out is the version of this screen that is a trick.
                afterCard.padding(.top, 28)

                StashPrimaryButton(title: count.map { "Start with \($0) free" } ?? "Start free",
                                   action: onContinue)
                    .padding(.top, 26)

                Text("[Terms of Use](https://stash.dmitrijs.dev/terms) · [Privacy Policy](https://stash.dmitrijs.dev/privacy)")
                    .font(.archivo(12, .semibold))
                    .foregroundStyle(Color.stashInk.opacity(0.62))
                    .tint(Color.stashInk)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.stashBackground.ignoresSafeArea())
        // The count arrives with the quota, which `restore()` fetches a beat after sign-in.
        // Asking again here costs one request and stops the headline reading "Free videos"
        // on the exact screen whose whole job is to name the number.
        .task { await session.refreshQuota() }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 16) {
            step("1", "Import your saves",
                 "Ask TikTok for your data, or share a video straight to Stash.")
            step("2", "Stash reads them",
                 "It watches and listens to each one, then writes down what was in it.")
            step("3", "Find it again",
                 "Recipes, tracks, links and products, searchable by what was said.")
        }
        .frame(maxWidth: 330, alignment: .leading)
    }

    private func step(_ number: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Color.stashInk).frame(width: 28, height: 28)
                Text(number)
                    .font(.archivo(13, .heavy))
                    .foregroundStyle(Color.stashOnInk)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.archivo(15, .bold))
                    .foregroundStyle(Color.stashInk)
                Text(body)
                    .font(.archivo(13))
                    .foregroundStyle(Color.stashInk.opacity(0.62))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// What happens at zero, said now. The price comes from StoreKit for the same reason the
    /// paywall's does: a hardcoded one disagrees with what Apple charges in every storefront
    /// but ours, and that disagreement is a rejection.
    private var afterCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Subscription.shared.displayPrice.isEmpty
                 ? "After that, Stash Pro keeps it going, monthly, cancel any time."
                 : "After that, Stash Pro keeps it going: \(Subscription.shared.displayPrice) a month, cancel any time.")
                .font(.archivo(13, .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.75))
                .multilineTextAlignment(.leading)
                .lineSpacing(3)
            Text("Your saves stay readable either way.")
                .font(.archivo(12))
                .foregroundStyle(Color.stashInk.opacity(0.62))
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.stashInk.opacity(0.18), lineWidth: 1.5)
        )
    }

    private var appTile: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.stashInk)
            .frame(width: 76, height: 76)
            .overlay(
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.stashOnInk)
            )
            .shadow(color: Color.stashDeepInk.opacity(0.22), radius: 15, y: 8)
    }
}

#Preview {
    WelcomeView {}
}
