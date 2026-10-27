// SearchView.swift
//
// Search has no tab. The magnifier on every section's STASH row (StashWordmarkRow) opens it, and
// holding the pill and pushing right is the accelerator; either way the pill itself becomes the
// field (StashTabBar). What opens above it is `SearchOverlay`: one list of the saves that match by
// what they are about — `Video.about`, what the video says and shows — each row showing that
// line so it is plain why the save is there.
//
// The ranking is the Kit's `SearchIndex`. Four hundred milliseconds after the typing stops the
// query goes to the box for an embedding; once that lands, fails, or runs out of time, the
// query is ranked once and that list is final. Nothing re-sorts under the reader's thumb: while
// the next query settles, the last final list stays where it is under one "Searching…" line.
//
// `SearchGrip` is the gesture arithmetic and `SearchSuggestions` is what an empty field offers
// — this library's own most-used topics, under the queries that already went somewhere. Both
// are kept out of the view so they can be checked.

import SwiftUI
import SwiftData
import TikTokBrainKit

/// The hold-and-push numbers. Progress drives the pill's morph (0 = tabs, 1 = field);
/// `commits` decides what a release does.
enum SearchGrip {
    /// Hold this long before the push is honoured — a tap must stay a tap, because the pill is
    /// also the reselect target.
    static let holdDuration: TimeInterval = 0.35
    /// How far right the finger travels for the morph to complete.
    static let travel: CGFloat = 140
    /// Where a release commits instead of springing back.
    static let commitTravel: CGFloat = 70
    /// A held pill already shows the magnifier peeking in at the left edge.
    static let heldProgress: CGFloat = 0.1

    /// Morph progress for a horizontal drag of `dx` points. Leftward travel does nothing.
    static func progress(dx: CGFloat) -> CGFloat {
        min(1, heldProgress + max(0, dx) / travel)
    }

    static func commits(dx: CGFloat) -> Bool {
        dx >= commitTravel
    }

    static func selfTest() -> Bool {
        progress(dx: 0) == heldProgress
            && progress(dx: -20) == heldProgress
            && progress(dx: travel) == 1
            && progress(dx: 400) == 1
            && progress(dx: 35) > heldProgress && progress(dx: 35) < 1
            && !commits(dx: commitTravel - 1) && commits(dx: commitTravel)
    }
}

/// What the grip opens: results (or the prompts) on a cream sheet over the current tab. The
/// field itself lives in the pill — this only reads the query.
struct SearchOverlay: View {
    @Binding var query: String
    @Query(sort: \Video.bookmarkedAt, order: .reverse) private var videos: [Video]

    /// The current query's vector, or nil while it is being typed, being fetched, or unavailable.
    /// Nil is not an error state — it is the word-only mode the whole screen degrades to.
    @State private var queryEmbedding: [Float]?
    /// The query whose embedding attempt has finished — succeeded, failed, come back empty or
    /// run out of time. Ranking waits for this stamp to match the field.
    /// A plain in-flight Bool raced: a cancelled run resumes after its replacement has already
    /// started, and clears the flag the new run just set. A query stamp cannot, because only
    /// the run that owns the query writes it.
    @State private var embeddedQuery: String?

    /// The queries this field has sent somewhere, newest first, up to five. One `\n`-joined
    /// string because `@AppStorage` has no array of strings and five queries do not want a file.
    @AppStorage("recentSearches") private var recentSearchesRaw = ""

    /// The library flattened for ranking, and the last final ranking over it. Both are filled off
    /// the main thread; a render only maps ids back onto rows. `finalMatches` and `finalQuery`
    /// are only ever written together, so the rows on screen are always one query's whole answer.
    @Environment(\.modelContext) private var context
    @State private var index: [SearchEntry] = []
    @State private var indexRevision = 0
    @State private var finalMatches: [SearchMatch] = []
    @State private var finalQuery = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    StashHeader(title: "Search", trailing: "\(videos.count) saves")
                        .padding(.top, 8)

                    Micro(text: "By what's said and shown", size: 10, tracking: 1.8)
                        .padding(.top, 14)

                    if videos.isEmpty {
                        emptyLibrary.padding(.top, 44)
                    } else if trimmedQuery.isEmpty {
                        suggestions.padding(.top, 22)
                    } else {
                        // Rows are only ever a final answer. While the field is ahead of it,
                        // the last answer stays put under one "Searching…" line rather than
                        // being re-sorted or blanked; a first query has nothing to keep. The
                        // line is always laid out and only fades, so the rows under it never
                        // move down when it appears or up when it goes.
                        searchingRow
                            .opacity(isSettled ? 0 : 1)
                            .accessibilityHidden(isSettled)
                            .padding(.top, 14)
                        if isSettled, results.isEmpty {
                            Text("No saves matched.")
                                .font(.archivo(14, .semibold))
                                .foregroundStyle(Color.stashInk.opacity(0.62))
                                .padding(.top, 24)
                        } else {
                            resultRows.padding(.top, 8)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, stashTabBarClearance)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.stashBackground.opacity(0.96).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task(id: trimmedQuery) { await embedQuery() }
            .task(id: videos.count) { await rebuildIndex() }
            .task(id: RankKey(query: trimmedQuery, settled: embeddedQuery == trimmedQuery,
                              index: indexRevision)) {
                await rank()
            }
        }
    }

    // MARK: - The meaning half

    /// Fetches one vector for the query, four hundred milliseconds after the last keystroke —
    /// `.task(id:)` cancels and restarts this on every change, which is the whole debounce.
    ///
    /// Every failure path ends in `queryEmbedding == nil` and nothing else: offline, box down,
    /// session expired, budget spent. Search then answers on words alone and says nothing about
    /// it. A search field that apologises is worse than one that just answers.
    private func embedQuery() async {
        let text = trimmedQuery
        queryEmbedding = nil
        embeddedQuery = nil
        guard !text.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }

        let client = BoxEmbeddingClient(config: PipelineCenter.currentConfig())
        // The Kit gives this request 30 seconds (`boxRequestTimeout`), plus a 401 refresh
        // retry on top — far too long to hold a list back for. The deadline stamps the query
        // settled with no vector, which ranks it on words alone and makes that answer final.
        // ponytail: a fixed 6 s, not a measured p95 of the box. It is the number that keeps
        // "Searching…" short on a hung box without giving up on a slow working one.
        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            embeddedQuery = text
        }
        defer { deadline.cancel() }

        let vectors = try? await client.embed([text])
        guard !Task.isCancelled else { return }
        // Too late: the deadline already settled this query and its word-only list is on
        // screen as final. Ranking it again with the vector would re-sort it under the reader.
        guard embeddedQuery != text else { return }
        queryEmbedding = vectors?.first
        // Settled either way: a nil vector is the word-only answer, not a pending one.
        embeddedQuery = text
    }

    // MARK: - Matching

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The rows on screen are this query's answer rather than the last one's.
    private var isSettled: Bool { finalQuery == trimmedQuery }

    /// What a ranking run is keyed on: the query, whether its embedding attempt is over, and
    /// which build of the index. The vector is not in it: it is written in the same step as the
    /// stamp, and never after.
    private struct RankKey: Equatable {
        let query: String
        let settled: Bool
        let index: Int
    }

    /// Flattens the library once, on its own context off the main thread. Per keystroke this
    /// used to run on the main thread, twice per render: six lowercased fields, two JSON
    /// decodes and an unpacked vector for every save — ~100 ms on an 855-save library, which
    /// is the lag this replaces.
    /// ponytail: rebuilt when the count moves, the one signal that is free to read per render;
    /// a save re-analyzed while the overlay is open keeps its old text until it is reopened, and
    /// a list already on screen is not re-ranked for a new build — the next query sees it.
    private func rebuildIndex() async {
        let container = context.container
        let built = await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let all = (try? context.fetch(FetchDescriptor<Video>(
                sortBy: [SortDescriptor(\.bookmarkedAt, order: .reverse)]))) ?? []
            return SearchIndex.build(all)
        }.value
        guard !Task.isCancelled else { return }
        index = built
        indexRevision += 1
    }

    /// Ranks the index off the main thread, once per query and only once the query has settled:
    /// its embedding attempt is over and the index has been built. That one ranking is the list,
    /// and nothing ranks the same query again while it is on screen — which is what keeps rows
    /// from jumping. `.task(id:)` cancels a run whose query moved on, and its result is dropped
    /// rather than shown late.
    private func rank() async {
        let query = trimmedQuery
        guard !query.isEmpty else {
            // An empty field ends the search: the next query is a first one again, shown as
            // "Searching…" alone rather than over an older query's rows.
            finalMatches = []
            finalQuery = ""
            return
        }
        guard embeddedQuery == query, indexRevision > 0, finalQuery != query else { return }
        let entries = index, embedding = queryEmbedding
        let result = await Task.detached(priority: .userInitiated) {
            SearchIndex.rank(entries, query: query, embedding: embedding)
        }.value
        guard !Task.isCancelled else { return }
        finalMatches = result
        finalQuery = query
    }

    /// The ranked ids back onto the live rows. A save deleted since it was ranked drops out.
    private var results: [Video] {
        let byID = Dictionary(videos.map { ($0.videoID, $0) }, uniquingKeysWith: { first, _ in first })
        return finalMatches.compactMap { byID[$0.videoID] }
    }

    // MARK: - Pieces

    /// Search over nothing is worse than a blank screen: the canned "try asking" chips promise
    /// results that cannot exist. Say the index is empty and offer the one thing that fills it.
    private var emptyLibrary: some View {
        StashEmptyState(
            symbol: "magnifyingglass",
            title: "Nothing to search yet",
            message: "Import your favorites and Stash reads what each video says and shows."
        )
    }

    /// The one line the screen shows while a query settles. No number, no stage name — any
    /// rows under it are the last query's answer, held still until this one's is ready.
    private var searchingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
                .tint(.stashInk.opacity(0.62))
            Micro(text: "Searching…", size: 10, tracking: 1.4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Searching")
    }

    /// What an empty field offers: the queries that went somewhere, then the words this library
    /// actually uses. The three canned chips this replaces promised results that could only
    /// exist in someone else's library.
    private var suggestions: some View {
        let recents = self.recents
        let topics = SearchSuggestions.topTopics(in: videos, limit: 5)
        return VStack(alignment: .leading, spacing: 10) {
            if !recents.isEmpty {
                Micro(text: "Recent", size: 10, tracking: 1.8)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(recents, id: \.self) { recent in
                        Button { query = recent } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.stashInk.opacity(0.5))
                                Text(recent)
                                    .font(.archivo(14, .semibold))
                                    .foregroundStyle(Color.stashInk)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(height: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !topics.isEmpty {
                Micro(text: "From your saves", size: 10, tracking: 1.8)
                    .padding(.top, recents.isEmpty ? 0 : 10)
                FlowChips(chips: topics.map(\.topic), onTap: { query = $0 })
            }
            if recents.isEmpty, topics.isEmpty {
                // A library with saves but no topics yet — say what the field reaches rather
                // than leaving the screen blank under its own title.
                Micro(text: "Search what your saves say and show", size: 10, tracking: 1.2)
            }
        }
    }

    private var resultRows: some View {
        VStack(spacing: 0) {
            ForEach(results, id: \.videoID) { video in
                NavigationLink { VideoDetailView(video: video) } label: { resultRow(video) }
                    .buttonStyle(.plain)
                    // A query is worth keeping once it led somewhere — the query these rows
                    // answer, which while "Searching…" shows is not the one in the field.
                    // Simultaneous rather than `onTapGesture`, which would eat the link's own tap.
                    // The field is in the pill, outside this stack, so the push alone would
                    // leave the keyboard up over the save's page.
                    .simultaneousGesture(TapGesture().onEnded {
                        recordSearch(finalQuery)
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                        to: nil, from: nil, for: nil)
                    })
                Divider().overlay(Color.stashInk.opacity(0.12))
            }
        }
    }

    // MARK: - Recents

    private var recents: [String] {
        recentSearchesRaw.split(separator: "\n").map(String.init)
    }

    /// Newest first, no case-insensitive duplicate, five deep.
    private func recordSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The separator is the one character a stored query may not contain.
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return }
        var kept = recents.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        kept.insert(trimmed, at: 0)
        recentSearchesRaw = kept.prefix(5).joined(separator: "\n")
    }

    private func resultRow(_ video: Video) -> some View {
        HStack(spacing: 12) {
            Thumbnail(url: video.thumbnailURL, category: video.category, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(video.rowTitle)
                    .font(.archivo(16, .bold))
                    .foregroundStyle(Color.stashInk)
                    .lineLimit(1)
                // What the save is about, so it is plain why it is here. A save still waiting
                // for its about-text shows its title alone.
                if let about = video.about, !about.isEmpty {
                    Text(about)
                        .font(.archivo(12.5))
                        .foregroundStyle(Color.stashInk.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
    }
}

/// What an empty search field offers, taken from the library rather than from a copywriter.
enum SearchSuggestions {
    /// The library's most-used topics, largest first. Counted case-insensitively — the analysis
    /// writes "Sourdough" and "sourdough" for the same thing — and shown in the first spelling
    /// the list offers, which for a library read newest-first is the most recent one. Equal
    /// counts fall back to the name, so the chips do not reshuffle between two identical reads.
    static func topTopics(in topicLists: [[String]], limit: Int = 5) -> [(topic: String, count: Int)] {
        var counts: [String: Int] = [:]      // folded topic -> how many saves carry it
        var spelling: [String: String] = [:] // folded topic -> the spelling to show
        for topics in topicLists {
            for topic in topics {
                let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let folded = trimmed.lowercased()
                counts[folded, default: 0] += 1
                if spelling[folded] == nil { spelling[folded] = trimmed }
            }
        }
        // Spelled out rather than chained: a map-then-sort over a dictionary of labelled
        // tuples is one of the shapes the type checker gives up on.
        var ranked: [(topic: String, count: Int)] = []
        ranked.reserveCapacity(counts.count)
        for (folded, count) in counts {
            ranked.append((topic: spelling[folded] ?? folded, count: count))
        }
        ranked.sort { first, second in
            if first.count != second.count { return first.count > second.count }
            return first.topic.lowercased() < second.topic.lowercased()
        }
        return Array(ranked.prefix(max(0, limit)))
    }

    /// The live-library door. Reading `topics` is the only thing this needs a `Video` for.
    static func topTopics(in videos: [Video], limit: Int = 5) -> [(topic: String, count: Int)] {
        topTopics(in: videos.map(\.topics), limit: limit)
    }

    #if DEBUG
    /// Counting is the whole feature, so it gets the same launch-time check as the scorer.
    static func selfTest() -> Bool {
        let empty: [[String]] = []
        let blanks: [[String]] = [[], [" "]]
        let library = [["Bread", "pasta"], ["bread", "Pasta", "coffee"], ["BREAD"]]
        let top = topTopics(in: library, limit: 2)
        let tied = topTopics(in: [["Zebra"], ["apple"]], limit: 5)
        return topTopics(in: empty, limit: 5).isEmpty
            && topTopics(in: blanks, limit: 5).isEmpty
            && top.count == 2                                   // limit is honoured
            && top[0].topic == "Bread" && top[0].count == 3     // three spellings, one topic
            && top[1].topic == "pasta" && top[1].count == 2     // and the first spelling wins
            && tied.map(\.topic) == ["apple", "Zebra"]          // equal counts sort by name
            && topTopics(in: library, limit: 0).isEmpty
    }
    #endif
}

/// Outlined uppercase chips that wrap onto multiple lines.
struct FlowChips: View {
    let chips: [String]
    let onTap: (String) -> Void

    var body: some View {
        FlexibleWrap(spacing: 8) {
            ForEach(chips, id: \.self) { chip in
                Button { onTap(chip) } label: {
                    Micro(text: chip, size: 11, tracking: 0.7, color: .stashInk)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().strokeBorder(Color.stashInk, lineWidth: 1.5))
                        // The pill draws ~31 pt tall; the thumb gets 44. `FlexibleWrap`
                        // measures the grown size, so the rows space themselves.
                        .minTapTarget()
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Minimal wrapping layout for chips.
struct FlexibleWrap: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in arrange(proposal: proposal, subviews: subviews).points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (points, CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight))
    }
}

#Preview {
    SearchOverlay(query: .constant("bread"))
        .modelContainer(SampleData.previewContainer)
}
