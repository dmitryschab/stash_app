// SearchView.swift
//
// Search has no tab. Hold the pill, push right, and the pill itself becomes the field
// (StashTabBar); what opens above it is `SearchOverlay`: one list over everything the pipeline
// extracted — titles, captions, summaries, transcripts, OCR text, topics — with a per-result
// match strength and the field that matched.
//
// Meaning, not just keywords, and now literally: every keystroke runs the lexical scorer, and
// four hundred milliseconds after the typing stops the query goes to the box for an embedding
// and the two are blended (`SearchBlend`). The lexical half is never switched off — it is what
// answers offline, what answers while the box is thinking, and what answers for a save the
// embedding backfill has not reached yet.
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
    /// Nil is not an error state — it is the lexical-only mode the whole screen degrades to.
    @State private var queryEmbedding: [Float]?
    /// The query whose embedding attempt has finished — succeeded, failed or come back empty.
    /// A plain in-flight Bool raced: a cancelled run resumes after its replacement has already
    /// started, and clears the flag the new run just set. A query stamp cannot, because only
    /// the run that owns the query writes it.
    @State private var embeddedQuery: String?

    /// The queries this field has sent somewhere, newest first, up to five. One `\n`-joined
    /// string because `@AppStorage` has no array of strings and five queries do not want a file.
    @AppStorage("recentSearches") private var recentSearchesRaw = ""

    /// The library flattened for scoring, and the last scoring over it. Both are filled off the
    /// main thread; a render only maps ids back onto rows.
    @Environment(\.modelContext) private var context
    @State private var index: [SearchEntry] = []
    @State private var indexRevision = 0
    @State private var scored: [SearchMatch] = []
    @State private var scoredQuery = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    StashHeader(title: "Search", trailing: "\(videos.count) saves")
                        .padding(.top, 8)

                    Micro(text: "Meaning, not just keywords", size: 10, tracking: 1.8)
                        .padding(.top, 14)

                    if videos.isEmpty {
                        emptyLibrary.padding(.top, 44)
                    } else if trimmedQuery.isEmpty {
                        suggestions.padding(.top, 22)
                    } else {
                        // The answer is only final once the scorer has caught up with the
                        // field, the index exists, and the meaning half has landed. Until
                        // then the rows below are a first pass, and the line above says so.
                        if isSettling { settlingRow.padding(.top, 14) }
                        if results.isEmpty, scoredQuery == trimmedQuery, !index.isEmpty {
                            Text("No saves matched.")
                                .font(.archivo(14, .semibold))
                                .foregroundStyle(Color.stashInk.opacity(0.62))
                                .padding(.top, isSettling ? 10 : 24)
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
            .task(id: ScoreKey(query: trimmedQuery, embedding: queryEmbedding, index: indexRevision)) {
                await rescore()
            }
        }
    }

    // MARK: - The meaning half

    /// Fetches one vector for the query, four hundred milliseconds after the last keystroke —
    /// `.task(id:)` cancels and restarts this on every change, which is the whole debounce.
    ///
    /// Every failure path ends in `queryEmbedding == nil` and nothing else: offline, box down,
    /// session expired, budget spent. Search then answers exactly as it did before this existed.
    /// A search field that apologises is worse than one that just answers.
    private func embedQuery() async {
        let text = trimmedQuery
        queryEmbedding = nil
        embeddedQuery = nil
        guard !text.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }

        let client = BoxEmbeddingClient(config: PipelineCenter.currentConfig())
        let vectors = try? await client.embed([text])
        guard !Task.isCancelled else { return }
        queryEmbedding = vectors?.first
        // Settled either way: a nil vector is the lexical-only answer, not a pending one.
        embeddedQuery = text
    }

    // MARK: - Matching

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the rows on screen are still provisional: the scorer has not caught up with the
    /// field, the index has not been built yet, or the query's vector is still in the air.
    ///
    /// All three used to read as "No saves matched." — an answer, and a wrong one, for the
    /// second or so an index build plus a 400 ms debounce plus a round trip takes.
    private var isSettling: Bool {
        !trimmedQuery.isEmpty
            && (scoredQuery != trimmedQuery || index.isEmpty || embeddedQuery != trimmedQuery)
    }

    private struct Hit: Identifiable {
        let video: Video
        let score: Double
        let matchedIn: String
        var id: String { video.videoID }
        /// The badge. Same arithmetic the lexical-only scorer always used, so a keystroke result
        /// still reads exactly as it did; 20 is the floor because "3%" reads as a bug.
        var percent: Int { max(20, min(98, Int(score * 98))) }
    }

    /// What a scoring run is keyed on: the query, its vector, and which build of the index.
    private struct ScoreKey: Equatable {
        let query: String
        let embedding: [Float]?
        let index: Int
    }

    /// Flattens the library once, on its own context off the main thread. Per keystroke this
    /// used to run on the main thread, twice per render: six lowercased fields, two JSON
    /// decodes and an unpacked vector for every save — ~100 ms on an 855-save library, which
    /// is the lag this replaces.
    /// ponytail: rebuilt when the count moves, the one signal that is free to read per render;
    /// a save re-analyzed while the overlay is open keeps its old text until it is reopened.
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

    /// Scores the index off the main thread. `.task(id:)` cancels the previous keystroke's
    /// run, and a result that lands after cancellation is dropped rather than shown late.
    private func rescore() async {
        let entries = index, query = trimmedQuery, embedding = queryEmbedding
        guard !query.isEmpty, !entries.isEmpty else {
            scored = []
            scoredQuery = query
            return
        }
        let result = await Task.detached(priority: .userInitiated) {
            SearchIndex.score(entries, query: query, embedding: embedding)
        }.value
        guard !Task.isCancelled else { return }
        scored = result
        scoredQuery = query
    }

    /// The scored ids back onto the live rows. A save deleted since it was scored drops out.
    private var results: [Hit] {
        let byID = Dictionary(videos.map { ($0.videoID, $0) }, uniquingKeysWith: { first, _ in first })
        return scored.compactMap { match in
            byID[match.videoID].map { Hit(video: $0, score: match.score, matchedIn: match.matchedIn) }
        }
    }

    // MARK: - Pieces

    /// Search over nothing is worse than a blank screen: the canned "try asking" chips promise
    /// results that cannot exist. Say the index is empty and offer the one thing that fills it.
    private var emptyLibrary: some View {
        StashEmptyState(
            symbol: "magnifyingglass",
            title: "Nothing to search yet",
            message: "Import your favorites and Stash indexes every caption, transcript and on-screen word."
        )
    }

    /// The one line the screen shows while it is still working. No percentage, no stage name —
    /// the results underneath are already usable, this only says more may arrive.
    private var settlingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
                .tint(.stashInk.opacity(0.62))
            Micro(text: "Also checking by meaning…", size: 10, tracking: 1.4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Also checking by meaning")
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
                Micro(text: "Search titles, captions, transcripts and on-screen words",
                      size: 10, tracking: 1.2)
            }
        }
    }

    private var resultRows: some View {
        VStack(spacing: 0) {
            ForEach(results) { hit in
                NavigationLink { VideoDetailView(video: hit.video) } label: { resultRow(hit) }
                    .buttonStyle(.plain)
                    // A query is worth keeping once it led somewhere. Simultaneous rather than
                    // `onTapGesture`, which would eat the link's own tap.
                    .simultaneousGesture(TapGesture().onEnded { recordSearch(trimmedQuery) })
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

    private func resultRow(_ hit: Hit) -> some View {
        let strong = hit.percent >= 80
        return HStack(spacing: 12) {
            Thumbnail(url: hit.video.thumbnailURL, category: hit.video.category, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.video.rowTitle)
                    .font(.archivo(16, .bold))
                    .foregroundStyle(Color.stashInk)
                    .lineLimit(1)
                Text("matched: \(hit.matchedIn)")
                    .font(.archivo(12.5))
                    .foregroundStyle(Color.stashInk.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Micro(text: "\(hit.percent)%", size: 9.5, tracking: 1.1, color: strong ? (hit.video.category?.color ?? .stashInk) : .stashInk.opacity(0.62))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().strokeBorder(
                        strong ? (hit.video.category?.color ?? .stashInk) : Color.stashInk.opacity(0.35),
                        lineWidth: 1.2
                    )
                )
        }
        .padding(.vertical, 13)
    }
}

/// One save flattened for scoring off the main thread: every lexical field already lowercased,
/// the vector already unpacked, the row title already decided.
struct SearchEntry: Sendable {
    let videoID: String
    let bookmarkedAt: Date
    /// (field label, lowercased text, weight) — title matches count double.
    let fields: [(label: String, text: String, weight: Double)]
    let embedding: [Float]?
}

struct SearchMatch: Sendable {
    let videoID: String
    let score: Double
    let matchedIn: String
}

/// The scorer, as a pure function over `SearchEntry` so it can run anywhere and be checked.
enum SearchIndex {
    /// Caller's context: the model objects are read here and nowhere else.
    static func build(_ videos: [Video]) -> [SearchEntry] {
        videos.map { video in
            SearchEntry(
                videoID: video.videoID,
                bookmarkedAt: video.bookmarkedAt,
                fields: [
                    ("title", video.rowTitle.lowercased(), 2),
                    ("topics", video.topics.joined(separator: " ").lowercased(), 1.5),
                    ("caption", video.caption.lowercased(), 1),
                    ("summary", video.summary.lowercased(), 1),
                    ("transcript", (video.transcript ?? "").lowercased(), 1),
                    ("on-screen text", (video.ocrText ?? "").lowercased(), 1),
                ],
                embedding: video.embedding.map(EmbeddingVector.unpack).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// Token overlap across the extracted fields, weighted by field quality, blended with cosine
    /// distance to the query's embedding once there is one.
    ///
    /// The lexical half is unchanged and unconditional: it is what runs per keystroke, what runs
    /// offline, and what runs for a save the embedding backfill has not reached — a library
    /// mid-backfill has to stay searchable, not half-searchable. Only a save that has a vector
    /// gets the blend, which is why one without keeps its lexical-only score rather than being
    /// pushed down by a semantic term it cannot score. `entries` are newest first.
    static func score(_ entries: [SearchEntry], query: String, embedding: [Float]?) -> [SearchMatch] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let oldest = entries.last?.bookmarkedAt ?? .distantPast
        let newest = entries.first?.bookmarkedAt ?? .distantPast

        return entries.compactMap { entry in
            var raw = 0.0
            var matchedIn: String?
            for field in entry.fields {
                let hits = tokens.filter { field.text.contains($0) }
                if !hits.isEmpty {
                    raw += Double(hits.count) * field.weight
                    if matchedIn == nil { matchedIn = field.label }
                }
            }
            // The normalization the percent badge always applied, named because the blend
            // needs it as a 0...1 term rather than as a badge.
            let lexical = min(1, raw / (Double(tokens.count) * 2))

            guard let embedding, let stored = entry.embedding else {
                guard let matchedIn else { return nil }
                return SearchMatch(videoID: entry.videoID, score: lexical, matchedIn: matchedIn)
            }

            let cosine = EmbeddingVector.cosine(embedding, stored)
            let meaning = cosine >= SearchBlend.meaningFloor
            // A save has to have matched a word or come close enough in meaning; otherwise the
            // blend's recency term alone would return the entire library for every query.
            guard matchedIn != nil || meaning else { return nil }
            let reason: String
            switch (matchedIn, meaning) {
            case (let field?, true): reason = "meaning and \(field)"
            case (let field?, false): reason = field
            case (nil, _): reason = "meaning"
            }
            return SearchMatch(
                videoID: entry.videoID,
                score: SearchBlend.score(cosine: cosine, lexical: lexical,
                                         recency: recency(of: entry.bookmarkedAt, oldest: oldest, newest: newest)),
                matchedIn: reason)
        }
        .sorted { $0.score > $1.score }
    }

    /// Recency as 0...1 across the library's own span: the oldest save scores 0, the newest 1.
    /// Relative rather than absolute, so a library imported last month and one imported three
    /// years ago both get a usable tie-breaker out of the blend's smallest term.
    private static func recency(of date: Date, oldest: Date, newest: Date) -> Double {
        let span = newest.timeIntervalSince(oldest)
        guard span > 0 else { return 1 }
        return min(1, max(0, date.timeIntervalSince(oldest) / span))
    }

    #if DEBUG
    /// The ranking is no longer something a keystroke can be watched doing, so it gets the same
    /// launch-time check as the grip arithmetic.
    static func selfTest() -> Bool {
        func entry(_ id: String, title: String, caption: String = "", embedding: [Float]? = nil,
                   at: TimeInterval) -> SearchEntry {
            SearchEntry(videoID: id, bookmarkedAt: Date(timeIntervalSince1970: at),
                        fields: [("title", title, 2), ("caption", caption, 1)], embedding: embedding)
        }
        let entries = [
            entry("caption", title: "weekend plans", caption: "sourdough bread", at: 300),
            entry("title", title: "sourdough bread", at: 200),
            entry("meaning", title: "levain", embedding: [1, 0], at: 100),
            entry("far", title: "tax return", embedding: [0, 1], at: 0),
        ]
        let lexical = score(entries, query: "Bread", embedding: nil)
        let blended = score(entries, query: "bread", embedding: [1, 0])
        let ids = blended.map(\.videoID)
        return score(entries, query: "", embedding: nil).isEmpty
            && score(entries, query: "zzz", embedding: nil).isEmpty
            && lexical.map(\.videoID) == ["title", "caption"]           // a title hit outranks a caption hit
            && lexical.first?.matchedIn == "title"
            && ids == ["title", "meaning", "caption"]                     // close in meaning, no word in common
            && blended[1].matchedIn == "meaning"
            && zip(blended, blended.dropFirst()).allSatisfy { $0.score >= $1.score }
    }
    #endif
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
