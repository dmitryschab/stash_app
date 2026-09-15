// PaywallView.swift
//
// The second gate. SignInView establishes who you are; this one establishes that the account
// can spend money. It renders between the two, so everything past it is a paying account, a
// grandfathered 1.0 buyer, or App Review.
//
// Guideline 3.1.2 has a checklist for auto-renewable subscriptions and every item on it is
// here on purpose, not as decoration: the product's name, the period, the price *as StoreKit
// prints it in the viewer's own storefront* (never a hardcoded "€2.99" — a hardcoded price
// that disagrees with the one Apple charges is a rejection), the renewal terms in plain
// words, links to the Terms and the Privacy Policy, and Restore.
//
// The two quiet links at the bottom are not decoration either. A user who signs in, declines
// to subscribe and finds no way out has no route to account deletion, which is 5.1.1(v) —
// so sign-out and delete both live on this screen as well as in Settings.

import SwiftUI
import SwiftData
import TikTokBrainKit

struct PaywallView: View {
    /// Off when Settings presents this as a sheet: sign-out and delete are already one row
    /// away there, and offering them twice on stacked screens is its own kind of confusing.
    /// The gate keeps them, because on the gate they are the only exit that exists.
    let showsAccountLinks: Bool

    // Spelled out because the private stored properties below make the synthesized memberwise
    // initializer private, and SettingsView is in another file.
    init(showsAccountLinks: Bool = true) {
        self.showsAccountLinks = showsAccountLinks
    }

    private var store = Subscription.shared
    private var session = StashSession.shared

    @State private var error: String?
    @State private var confirmingDelete = false
    @Environment(\.modelContext) private var context

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                appTile.padding(.top, 28)

                Text("Stash Pro")
                    .font(.archivo(27, .heavy))
                    .foregroundStyle(Color.stashInk)
                    .padding(.top, 20)
                Text("Everything you save, read back as recipes, track lists and summaries you can search.")
                    .font(.archivo(14))
                    .foregroundStyle(Color.stashInk.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 300)
                    .padding(.top, 10)

                benefits.padding(.top, 26)

                if let error { errorLine(error).padding(.top, 18) }

                priceLine.padding(.top, 26)
                subscribeButton.padding(.top, 14)
                restoreButton.padding(.top, 10)

                renewalTerms.padding(.top, 20)
                legalLine.padding(.top, 12)
                if showsAccountLinks {
                    accountLinks.padding(.top, 26).padding(.bottom, 28)
                } else {
                    Spacer(minLength: 28)
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.stashBackground.ignoresSafeArea())
        .task { await store.load() }
        .confirmationDialog("Delete your Stash account?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { delete() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("This removes your account and everything Stash has stored for it. It cannot be undone.")
        }
    }

    // MARK: Pieces

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 14) {
            benefit("text.book.closed", "Recipes with ingredients and steps")
            benefit("music.note.list", "Every track named and listed")
            benefit("magnifyingglass", "Search what was said, not just the caption")
            benefit("square.grid.2x2", "Your saves sorted by what they are")
        }
        .frame(maxWidth: 320, alignment: .leading)
    }

    private func benefit(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.stashInk)
                .frame(width: 22)
            Text(text)
                .font(.archivo(14, .medium))
                .foregroundStyle(Color.stashInk.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// The period and the price, from StoreKit rather than from us.
    private var priceLine: some View {
        Group {
            if store.loadFailed && store.displayPrice.isEmpty {
                Text("The App Store is not answering right now. Check your connection and try again.")
                    .font(.archivo(13))
                    .foregroundStyle(Color.stashInk.opacity(0.6))
                    .multilineTextAlignment(.center)
            } else if store.displayPrice.isEmpty {
                ProgressView().tint(.stashInk)
            } else {
                VStack(spacing: 4) {
                    Text("\(store.displayPrice) per month")
                        .font(.archivo(20, .heavy))
                        .foregroundStyle(Color.stashInk)
                    Micro(text: "Cancel any time", size: 10, tracking: 1.8,
                          color: .stashInk.opacity(0.5))
                }
            }
        }
        .frame(height: 48)
    }

    private var subscribeButton: some View {
        Button {
            error = nil
            Task { error = await store.purchase() }
        } label: {
            ZStack {
                Capsule().fill(Color.stashInk)
                if store.isWorking {
                    ProgressView().tint(.stashOnInk)
                } else {
                    Text("Subscribe")
                        .font(.archivo(17, .heavy))
                        .foregroundStyle(Color.stashOnInk)
                }
            }
            .frame(height: 52)
        }
        .buttonStyle(.plain)
        .disabled(!canBuy || store.isWorking)
        .opacity(!canBuy || store.isWorking ? 0.5 : 1)
    }

    /// True whenever there is something to buy. `-showPaywall` counts: that path exists to be
    /// screenshotted, and a greyed-out button is not what the screen looks like in a real
    /// store. DEBUG-only, so a Release build can only ever enable this with a real product.
    private var canBuy: Bool {
        #if DEBUG
        if CommandLine.arguments.contains("-showPaywall") { return true }
        #endif
        return store.product != nil
    }

    /// Guideline 3.1.1: reachable without a fresh purchase, and it has to actually restore.
    private var restoreButton: some View {
        Button {
            error = nil
            Task { error = await store.restore() }
        } label: {
            Micro(text: "Restore purchases", size: 10, tracking: 1.8,
                  color: .stashInk.opacity(0.55))
        }
        .buttonStyle(.plain)
        .disabled(store.isWorking)
    }

    /// The renewal disclosure Apple requires in the binary, not only in the listing.
    private var renewalTerms: some View {
        Text("Payment is charged to your Apple ID at confirmation of purchase. The subscription renews each month unless you cancel at least 24 hours before the period ends. Manage or cancel it in your App Store account settings.")
            .font(.archivo(11))
            .foregroundStyle(Color.stashInk.opacity(0.5))
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .frame(maxWidth: 320)
    }

    private var legalLine: some View {
        Text("[Terms of Use](https://stash.dmitrijs.dev/terms) · [Privacy Policy](https://stash.dmitrijs.dev/privacy)")
            .font(.archivo(12, .semibold))
            .foregroundStyle(Color.stashInk.opacity(0.55))
            .tint(Color.stashInk)
            .multilineTextAlignment(.center)
    }

    /// Without these, an account that declines to subscribe is an account with no exit and no
    /// way to delete itself — which is a 5.1.1(v) rejection, not a UX opinion.
    private var accountLinks: some View {
        HStack(spacing: 18) {
            Button { session.signOut() } label: {
                Micro(text: "Sign out", size: 10, tracking: 1.8, color: .stashInk.opacity(0.45))
            }
            .buttonStyle(.plain)
            Text("·").foregroundStyle(Color.stashInk.opacity(0.3))
            Button { confirmingDelete = true } label: {
                Micro(text: "Delete account", size: 10, tracking: 1.8,
                      color: .stashInk.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
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
            .shadow(color: .black.opacity(0.22), radius: 15, y: 8)
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
        .frame(maxWidth: 320)
    }

    private func delete() {
        Task {
            do {
                try await session.deleteAccount()
                try context.delete(model: Video.self)
                try context.save()
                try? FileManager.default.removeItem(at: ThumbnailStore.directory)
                try? FileManager.default.removeItem(at: AlbumStore.cacheURL)
                try? FileManager.default.removeItem(at: OfferStore.cacheURL)
                DeliveryAddress.forget()
                PipelineCenter.shared.forgetCloudState()
            } catch { self.error = error.localizedDescription }
        }
    }
}

#Preview {
    PaywallView()
}
