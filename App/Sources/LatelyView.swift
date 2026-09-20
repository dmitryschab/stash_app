// LatelyView.swift
//
// The Lately tab (replaces RecentsView): zero to three cards, each naming a relationship the
// user's own saves already contain, and then an ending. Not a feed — there is nothing below
// the last card, nothing to pull for more, and no reason to come back twice in an hour.
//
// The rules are in the Kit and the timing is in LatelyStore; this file only draws. What it is
// responsible for is honesty of presentation: every card states why it is here in words, every
// number it shows is the count behind it, and the past tense appears whenever the library has
// not been touched in a month. A card that cannot say what it is doing on screen does not
// belong on it. Spec: docs/superpowers/specs/2026-09-18-lately-technical-spec.md §8–9.

import SwiftUI
import SwiftData
import TikTokBrainKit

/// A topic is one word as often as not, and at accessibility text sizes a long one has nowhere
/// to wrap — "sourdough" breaks to "sourdoug / h", which reads as a rendering fault. Shrinking
/// inside a three-line budget keeps the word whole; the floor is high enough that the result is
/// still far larger than the default size.
private struct TopicHeadline: ViewModifier {
    func body(content: Content) -> some View {
        content.lineLimit(3).minimumScaleFactor(0.55)
    }
}

struct LatelyView: View {
    @Query(sort: \Video.bookmarkedAt, order: .reverse) private var videos: [Video]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The app owns the store's account lifecycle (`TikTokBrainApp`), so it is already
    /// pointed at the right user — and at nobody during sign-out — before this view exists.
    private var store = LatelyStore.shared

    /// Saves that can support a claim: analyzed, not archived, categorised, and carrying at
    /// least one topic. Everything else is pipeline state, not evidence.
    private var eligible: [Video] {
        videos.filter { !$0.needsLook && !$0.isArchived && $0.category != nil
            && !$0.videoID.isEmpty && !$0.topics.isEmpty }
    }

    private var byID: [String: Video] {
        Dictionary(videos.map { ($0.videoID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var snapshot: LatelyDigestState.Snapshot? { store.snapshot }

    var body: some View {
        NavigationStack {
            StashScrollView(tab: .today) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if let snapshot, !snapshot.cards.isEmpty {
                        cards(snapshot)
                    } else {
                        emptyState.padding(.top, 60)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, stashTabBarClearance)
            }
            .background(Color.stashBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear { store.isVisible = true }
        .onDisappear { store.isVisible = false }
        .onChange(of: eligible.map(\.videoID)) { _, _ in send() }
        .onChange(of: eligible.map(\.bookmarkedAt)) { _, _ in send() }
        .task { send() }
    }

    private func send() {
        store.observe(eligible.map {
            .init(id: $0.videoID, date: $0.bookmarkedAt, topics: $0.topics)
        })
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Micro(text: "STASH", size: 11, tracking: 3.4, color: .stashInk)
                Spacer()
                Micro(text: period, size: 11, tracking: 1.4, color: .stashInk.opacity(0.5))
            }
            Text("Lately.")
                .font(.archivo(33, .heavy))
                .foregroundStyle(Color.stashInk)
                .padding(.top, 2)
            Text("A few connections in your saves.")
                .font(.archivo(13, .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.55))
            if store.hasProposal { refreshControl }
        }
        .padding(.top, 8)
    }

    /// Today's date normally. A library nobody has added to in over a month says so instead,
    /// because "Thu · Sep 18" over three-month-old saves would read as activity today.
    private var period: String {
        guard let snapshot else { return Date().formatted(.dateTime.month(.wide).day()) }
        guard snapshot.isHistorical(at: Date()) else {
            return Date().formatted(.dateTime.weekday(.abbreviated)) + " · "
                + Date().formatted(.dateTime.month(.wide).day())
        }
        let style = Date.FormatStyle().month(.abbreviated).day()
        return "FROM YOUR SAVES · \(snapshot.recentStart.formatted(style))–"
            + snapshot.anchor.formatted(style)
    }

    /// New stories are offered, never imposed: the screen the user is reading does not
    /// rearrange itself because an import finished.
    private var refreshControl: some View {
        Button { store.acceptProposal() } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .bold))
                Text("New connections")
                    .font(.archivo(12.5, .bold))
            }
            .foregroundStyle(Color.stashOnInk)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Color.stashInk, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
        .accessibilityHint("Replaces the cards below with a newer set")
    }

    // MARK: - Cards

    private func cards(_ snapshot: LatelyDigestState.Snapshot) -> some View {
        VStack(spacing: 14) {
            ForEach(snapshot.cards, id: \.signature) { card in
                view(for: card, historical: snapshot.isHistorical(at: Date()))
            }
            if let undoable = store.undoable { undoBar(undoable) }
            Micro(text: "You're caught up", size: 10, tracking: 1.6,
                  color: .stashInk.opacity(0.4))
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .accessibilityLabel("You're caught up. That's the whole digest.")
        }
        .padding(.top, 18)
        // Cards appearing, leaving on Hide, and reordering on refresh are the only movement
        // here. Reduce Motion takes all of it: the new set simply is the set.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: snapshot.signatures)
    }

    @ViewBuilder
    private func view(for card: LatelySelector.Card, historical: Bool) -> some View {
        switch card {
        case let .currentInterest(interest):
            interestCard(interest, card: card, historical: historical)
        case let .connection(connection):
            connectionCard(connection, card: card)
        case let .returningInterest(returning):
            returningCard(returning, card: card, historical: historical)
        }
    }

    /// The plum card. Its title is the topic itself — not a summary of what the videos teach,
    /// which nothing here knows.
    private func interestCard(_ interest: LatelySelector.CurrentInterest,
                              card: LatelySelector.Card, historical: Bool) -> some View {
        let evidence = interest.evidenceIDs.compactMap { byID[$0] }
        return VStack(alignment: .leading, spacing: 0) {
            cardHeader(historical ? "YOU WERE EXPLORING" : "YOUR CURRENT RABBIT HOLE",
                       card: card, on: .stashOnAccent)
            NavigationLink {
                LatelyEvidenceView(card: card, videos: byID)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(interest.displayTheme)
                        .font(.archivo(27, .heavy))
                        .foregroundStyle(Color.stashOnAccent)
                        .multilineTextAlignment(.leading)
                        .modifier(TopicHeadline())
                        .padding(.top, 9)
                    Text(explanation(interest))
                        .font(.archivo(13, .semibold))
                        .foregroundStyle(Color.stashOnAccent.opacity(0.82))
                        .multilineTextAlignment(.leading)
                        .padding(.top, 4)
                    thumbnails(evidence.prefix(3), border: .stashLatelyNow)
                        .padding(.top, 14)
                    cta("Explore the thread", on: .stashOnAccent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .stashCard(fill: .stashLatelyNow)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(historical ? "You were exploring" : "Current interest"): "
            + "\(interest.displayTheme). \(explanation(interest))")
    }

    /// The outlined card. It says the two saves mention the same things — never that one
    /// answers, solves or pairs with the other, which no rule here can tell.
    private func connectionCard(_ connection: LatelySelector.Connection,
                                card: LatelySelector.Card) -> some View {
        let recent = byID[connection.recentID]
        let older = byID[connection.olderID]
        return VStack(alignment: .leading, spacing: 0) {
            cardHeader("A CONNECTION", card: card, on: .stashInk)
            NavigationLink {
                LatelyEvidenceView(card: card, videos: byID)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(shared(connection))
                        .font(.archivo(19, .heavy))
                        .foregroundStyle(Color.stashInk)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 9)
                    VStack(alignment: .leading, spacing: 9) {
                        source(recent, dated: connection.recentDate)
                        source(older, dated: connection.olderDate)
                    }
                    .padding(.top, 13)
                    cta("See the connection", on: .stashInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .stashOutlineCard(padding: 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("A connection. \(shared(connection)). "
            + "\(recent?.rowTitle ?? "A save") and \(older?.rowTitle ?? "an older save").")
    }

    /// The sage card. It reports a gap in saving, which is all the dates support — never that
    /// the user lost interest, which would be putting words in their mouth.
    private func returningCard(_ returning: LatelySelector.ReturningInterest,
                               card: LatelySelector.Card, historical: Bool) -> some View {
        let evidence = returning.recentIDs.compactMap { byID[$0] }
        return VStack(alignment: .leading, spacing: 0) {
            cardHeader(historical ? "YOU RETURNED TO" : "BACK TO", card: card, on: .stashOnAccent)
            NavigationLink {
                LatelyEvidenceView(card: card, videos: byID)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(returning.displayTheme)
                        .font(.archivo(27, .heavy))
                        .foregroundStyle(Color.stashOnAccent)
                        .multilineTextAlignment(.leading)
                        .modifier(TopicHeadline())
                        .padding(.top, 9)
                    Text(explanation(returning))
                        .font(.archivo(13, .semibold))
                        .foregroundStyle(Color.stashOnAccent.opacity(0.82))
                        .multilineTextAlignment(.leading)
                        .padding(.top, 4)
                    thumbnails(evidence.prefix(3), border: .stashLatelyBack)
                        .padding(.top, 14)
                    cta("See what came back", on: .stashOnAccent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .stashCard(fill: .stashLatelyBack)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Returning interest: \(returning.displayTheme). "
            + explanation(returning))
    }

    // MARK: - Card parts

    /// The kind label and the Hide menu. The menu sits outside the card's NavigationLink on
    /// purpose: nesting a menu inside a link gives two overlapping targets and the wrong one
    /// wins about half the time.
    private func cardHeader(_ label: String, card: LatelySelector.Card,
                            on tint: Color) -> some View {
        HStack(spacing: 8) {
            Micro(text: label, size: 9.5, tracking: 1.6, color: tint.opacity(0.75))
            Spacer(minLength: 0)
            Menu {
                Button("Hide this connection", systemImage: "eye.slash") {
                    store.hide(card)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint.opacity(0.75))
                    .frame(width: 44, height: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Card options")
        }
        .frame(minHeight: 44)
    }

    private func thumbnails(_ videos: some Collection<Video>, border: Color) -> some View {
        HStack(spacing: -10) {
            ForEach(Array(videos), id: \.videoID) { video in
                Thumbnail(url: video.thumbnailURL, category: video.category, size: 44)
                    .overlay(RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(border, lineWidth: 2))
            }
        }
        // One decorative strip. VoiceOver reads the card's own explanation instead of
        // announcing three unlabelled images.
        .accessibilityHidden(true)
    }

    private func source(_ video: Video?, dated: Date) -> some View {
        HStack(spacing: 11) {
            Thumbnail(url: video?.thumbnailURL, category: video?.category, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(video?.rowTitle ?? "Save no longer available")
                    .font(.archivo(14, .bold))
                    .foregroundStyle(Color.stashInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(dated.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.archivo(11.5))
                    .foregroundStyle(Color.stashInk.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
    }

    private func cta(_ title: String, on tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.archivo(12.5, .bold))
            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(tint.opacity(0.9))
        .padding(.top, 14)
    }

    private func undoBar(_ card: LatelySelector.Card) -> some View {
        HStack(spacing: 12) {
            Text("Card hidden")
                .font(.archivo(13, .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.7))
            Spacer(minLength: 0)
            Button("Undo") { store.undoHide() }
                .font(.archivo(13, .bold))
                .foregroundStyle(Color.stashInk)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 16)
        .background(Color.stashSurface, in: RoundedRectangle(cornerRadius: 14))
        .task(id: card.signature) {
            try? await Task.sleep(for: .seconds(6))
            store.clearUndo()
        }
    }

    // MARK: - Copy

    /// Only what the counts and dates support. "5 saves about AI agents · Sep 6–18" is a fact
    /// about the library; anything richer would be a claim about the videos.
    private func explanation(_ interest: LatelySelector.CurrentInterest) -> String {
        "\(count(interest.saveCount)) about \(interest.displayTheme) · "
            + range(interest.firstDate, interest.lastDate)
    }

    private func explanation(_ returning: LatelySelector.ReturningInterest) -> String {
        "\(count(returning.recentCount)) after \(returning.gapDays) days "
            + "without a save on this topic"
    }

    private func shared(_ connection: LatelySelector.Connection) -> String {
        let topics = connection.sharedTopics
        guard topics.count >= 2 else {
            return "Both mention \(topics.first ?? "the same topic")."
        }
        return "Both mention \(topics[0]) and \(topics[1])."
    }

    private func count(_ value: Int) -> String {
        value == 1 ? "1 save" : "\(value) saves"
    }

    private func range(_ first: Date, _ last: Date) -> String {
        let style = Date.FormatStyle().month(.abbreviated).day()
        if Calendar.current.isDate(first, inSameDayAs: last) { return first.formatted(style) }
        if Calendar.current.isDate(first, equalTo: last, toGranularity: .month) {
            return "\(first.formatted(style))–\(last.formatted(.dateTime.day()))"
        }
        return "\(first.formatted(style)) – \(last.formatted(style))"
    }

    // MARK: - Empty states

    /// Five different nothings, and they are not interchangeable: a user waiting on analysis
    /// needs to know it is running, and a user whose saves all failed needs to know it is not.
    @ViewBuilder
    private var emptyState: some View {
        if videos.isEmpty {
            StashEmptyState(symbol: "sparkle.magnifyingglass",
                            title: "Your connections start here",
                            message: "Import your TikTok favorites and Lately starts finding "
                                + "the threads running through them.")
        } else if eligible.isEmpty && videos.allSatisfy(\.isArchived) {
            StashEmptyState(symbol: "exclamationmark.triangle",
                            title: "No analyzed saves yet",
                            message: "Every save so far failed to process. Settings › Archive "
                                + "can retry them.",
                            offersImport: false)
        } else if eligible.isEmpty {
            StashEmptyState(symbol: "hourglass",
                            title: "Your saves are still being organized",
                            message: "Lately needs analyzed saves to find connections. The "
                                + "Library shows what is still processing.",
                            offersImport: false)
        } else if store.snapshot != nil {
            // A digest exists and is empty: either nothing qualified, or the user cleared it.
            StashEmptyState(symbol: "checkmark.circle",
                            title: latelyEmptyTitle,
                            message: "New connections will appear as you save.",
                            offersImport: false)
        } else {
            StashEmptyState(symbol: "hourglass", title: "Looking for connections",
                            message: "One moment while Lately reads your saves.",
                            offersImport: false)
        }
    }

    /// "Caught up" is only honest when the user emptied the screen themselves. Otherwise the
    /// truth is that the rules found nothing strong enough, which is a different sentence.
    private var latelyEmptyTitle: String {
        store.undoable != nil ? "You're caught up" : "No strong connections yet"
    }
}

#Preview {
    LatelyView()
        .modelContainer(SampleData.latelyPreviewContainer)
}
