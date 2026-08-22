// SearchView.swift
//
// Search has no tab. Hold the pill, push right, and the pill itself becomes the field
// (StashTabBar); what opens above it is `SearchOverlay`: one list over everything the pipeline
// extracted — titles, captions, summaries, transcripts, OCR text, topics — with a per-result
// match strength and the field that matched. Meaning, not just keywords (the transcript is in
// the index). `SearchGrip` is the gesture arithmetic, kept out of the view so it can be checked.

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
                    } else if results.isEmpty {
                        Text("No saves matched.")
                            .font(.archivo(14, .semibold))
                            .foregroundStyle(Color.stashInk.opacity(0.55))
                            .padding(.top, 24)
                    } else {
                        resultRows.padding(.top, 8)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, stashTabBarClearance)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.stashBackground.opacity(0.96).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Matching

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Hit: Identifiable {
        let video: Video
        let percent: Int
        let matchedIn: String
        var id: String { video.videoID }
    }

    /// Token-overlap scoring across the extracted fields, weighted by field quality.
    // ponytail: naive token matching stands in for the future embedding search.
    private var results: [Hit] {
        let tokens = trimmedQuery.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }

        return videos.compactMap { video in
            // (field label, text, weight) — title matches count double.
            let fields: [(String, String, Double)] = [
                ("title", video.rowTitle, 2),
                ("topics", video.topics.joined(separator: " "), 1.5),
                ("caption", video.caption, 1),
                ("summary", video.summary, 1),
                ("transcript", video.transcript ?? "", 1),
                ("on-screen text", video.ocrText ?? "", 1),
            ]
            var score = 0.0
            var matchedIn: String?
            for (label, text, weight) in fields {
                let lower = text.lowercased()
                let hits = tokens.filter { lower.contains($0) }
                if !hits.isEmpty {
                    score += Double(hits.count) * weight
                    if matchedIn == nil { matchedIn = label }
                }
            }
            guard let matchedIn, score > 0 else { return nil }
            let percent = min(98, Int(score / (Double(tokens.count) * 2) * 98))
            return Hit(video: video, percent: max(percent, 20), matchedIn: matchedIn)
        }
        .sorted { $0.percent > $1.percent }
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

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Micro(text: "Try asking", size: 10, tracking: 1.8)
            FlowChips(
                chips: ["Songs like Midnight City", "Dinner under 20 min", "That Swift trick"],
                onTap: { query = $0 }
            )
        }
    }

    private var resultRows: some View {
        VStack(spacing: 0) {
            ForEach(results) { hit in
                NavigationLink { VideoDetailView(video: hit.video) } label: { resultRow(hit) }
                    .buttonStyle(.plain)
                Divider().overlay(Color.stashInk.opacity(0.12))
            }
        }
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
            Micro(text: "\(hit.percent)%", size: 9, tracking: 1.1, color: strong ? (hit.video.category?.color ?? .stashInk) : .stashInk.opacity(0.55))
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
