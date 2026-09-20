// LatelyEvidenceView.swift
//
// What a Lately card is standing on. Every card makes a claim about the user's library, so
// every card has a destination where that claim can be checked: the saves behind it, dated,
// in the order the rule counted them.
//
// This is deliberately not a Library filter. Its membership is the snapshot's evidence — the
// exact saves the claim was computed from — not everything currently matching the topic. If it
// re-queried, the screen would quietly stop agreeing with the card that opened it.
//
// It does read saves live, so a title or thumbnail that improves shows through, and a save
// deleted while this is open drops out rather than lingering as a dead row. When enough of the
// evidence goes that the story no longer holds, the screen says so instead of presenting a
// smaller claim as if it were the original one.
// Spec: docs/superpowers/specs/2026-09-18-lately-technical-spec.md §8.

import SwiftUI
import SwiftData
import TikTokBrainKit

struct LatelyEvidenceView: View {
    let card: LatelySelector.Card
    /// The library as the card saw it. Kept for the rare save that leaves the live query
    /// (archived mid-read) so its row can still say what happened to it.
    let videos: [String: Video]

    @Query private var live: [Video]

    private var byID: [String: Video] {
        Dictionary(live.map { ($0.videoID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The evidence that still exists, in the snapshot's order.
    private func resolve(_ ids: [String]) -> [Video] {
        ids.compactMap { byID[$0] }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch card {
                case let .currentInterest(interest): interestBody(interest)
                case let .connection(connection): connectionBody(connection)
                case let .returningInterest(returning): returningBody(returning)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, stashTabBarClearance)
        }
        .background(Color.stashBackground.ignoresSafeArea())
    }

    // MARK: - Kinds

    @ViewBuilder
    private func interestBody(_ interest: LatelySelector.CurrentInterest) -> some View {
        let saves = resolve(interest.evidenceIDs)
        heading(kicker: "\(saves.count == 1 ? "1 save" : "\(saves.count) saves")",
                title: interest.displayTheme)
        if saves.count >= LatelySelector.Rules.minCurrentSaves {
            // Recounted from what is actually here, so the sentence stays true even if a save
            // was deleted while this screen was open.
            explanation("\(saves.count) saves mention \(interest.displayTheme), "
                + "between \(dates(saves)).")
            rows(saves)
        } else {
            gone("This interest no longer has enough saves behind it.")
        }
    }

    @ViewBuilder
    private func connectionBody(_ connection: LatelySelector.Connection) -> some View {
        let recent = byID[connection.recentID]
        let older = byID[connection.olderID]
        heading(kicker: "A connection", title: shared(connection))
        if let recent, let older {
            explanation("Both saves mention these topics. That is the whole of the claim — "
                + "Lately is not saying one answers the other.")
            section("The recent save", [recent])
            section("The older save", [older])
        } else {
            gone("One of these two saves is no longer in your library.")
        }
    }

    @ViewBuilder
    private func returningBody(_ returning: LatelySelector.ReturningInterest) -> some View {
        let recent = resolve(returning.recentIDs)
        let history = resolve(returning.historicalIDs)
        heading(kicker: "Returning interest", title: returning.displayTheme)
        if recent.count >= LatelySelector.Rules.minReturningRecent,
           history.count >= LatelySelector.Rules.minReturningHistorical {
            explanation("\(recent.count) saves on this topic after \(returning.gapDays) days "
                + "with none. The gap is in your saving, not in what you were thinking about.")
            section("Recent saves", recent)
            section("Before the break", history)
        } else {
            gone("There is no longer enough on either side of the gap to show a return.")
        }
    }

    // MARK: - Parts

    private func heading(kicker: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Micro(text: kicker.uppercased(), size: 11, tracking: 1.8,
                  color: .stashInk.opacity(0.5))
            Text(title)
                .font(.archivo(27, .heavy))
                .foregroundStyle(Color.stashInk)
                .multilineTextAlignment(.leading)
        }
        .padding(.top, 6)
    }

    private func explanation(_ text: String) -> some View {
        Text(text)
            .font(.archivo(13.5, .semibold))
            .foregroundStyle(Color.stashInk.opacity(0.62))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func section(_ title: String, _ saves: [Video]) -> some View {
        if !saves.isEmpty {
            Micro(text: title.uppercased(), size: 10, tracking: 1.6,
                  color: .stashInk.opacity(0.45))
                .padding(.top, 8)
            rows(saves)
        }
    }

    private func rows(_ saves: [Video]) -> some View {
        ForEach(saves, id: \.videoID) { video in
            NavigationLink { VideoDetailView(video: video) } label: { row(video) }
                .buttonStyle(.plain)
        }
    }

    private func row(_ video: Video) -> some View {
        HStack(spacing: 13) {
            Thumbnail(url: video.thumbnailURL, category: video.category, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(video.rowTitle)
                    .font(.archivo(16, .bold))
                    .foregroundStyle(Color.stashInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(video.bookmarkedAt.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.archivo(12.5))
                    .foregroundStyle(Color.stashInk.opacity(0.55))
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(video.category?.color ?? .categoryOther)
        }
        .stashOutlineCard()
        .accessibilityElement(children: .combine)
    }

    /// The story stopped being true while the user was looking at it. Saying so is better than
    /// showing a thinner version of the claim that brought them here.
    private func gone(_ message: String) -> some View {
        StashEmptyState(symbol: "questionmark.circle", title: "This connection has changed",
                        message: message, offersImport: false)
            .padding(.top, 40)
    }

    private func shared(_ connection: LatelySelector.Connection) -> String {
        let topics = connection.sharedTopics
        guard topics.count >= 2 else {
            return "Both mention \(topics.first ?? "the same topic")"
        }
        return "Both mention \(topics[0]) and \(topics[1])"
    }

    /// The interval the evidence actually covers, recomputed from live saves.
    private func dates(_ saves: [Video]) -> String {
        let dates = saves.map(\.bookmarkedAt)
        guard let first = dates.min(), let last = dates.max() else { return "" }
        let style = Date.FormatStyle().month(.abbreviated).day()
        if Calendar.current.isDate(first, inSameDayAs: last) { return first.formatted(style) }
        return "\(first.formatted(style)) and \(last.formatted(style))"
    }
}
