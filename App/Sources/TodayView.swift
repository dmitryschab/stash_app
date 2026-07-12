// TodayView.swift
//
// The Today tab: three saves chosen for today — a hero card on the pick's category color
// plus two outlined rows — and nothing else. No feed, by design.

import SwiftUI
import SwiftData
import TikTokBrainKit

struct TodayView: View {
    @Query(sort: \Video.bookmarkedAt, order: .reverse) private var videos: [Video]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if picks.isEmpty {
                        emptyState.padding(.top, 60)
                    } else {
                        cards
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, stashTabBarClearance)
            }
            .background(Color.stashBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Picks

    /// Three library items, rotated daily so the shelf feels alive without a feed.
    // ponytail: day-of-year offset into the sorted list; a "never opened" model can replace it later.
    private var picks: [Video] {
        let pool = videos.filter { !$0.needsLook }
        guard !pool.isEmpty else { return [] }
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        let offset = day % pool.count
        return (0..<min(3, pool.count)).map { pool[(offset + $0) % pool.count] }
    }

    /// A second save sharing the hero's category, for the RELATED footer line.
    private func related(to video: Video) -> Video? {
        videos.first { $0.videoID != video.videoID && !$0.needsLook && $0.category == video.category }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Micro(text: "STASH", size: 11, tracking: 3.4, color: .stashInk)
                Spacer()
                Micro(text: Date().formatted(.dateTime.weekday(.abbreviated)) + " · " + Date().formatted(.dateTime.month(.wide).day()), size: 11, tracking: 1.4, color: .stashInk.opacity(0.5))
            }
            Text("Worth returning to.")
                .font(.archivo(33, .heavy))
                .foregroundStyle(Color.stashInk)
                .padding(.top, 2)
            Text("Three saves chosen for today. No feed.")
                .font(.archivo(13, .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.55))
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var cards: some View {
        VStack(spacing: 12) {
            if let hero = picks.first {
                NavigationLink { VideoDetailView(video: hero) } label: { heroCard(hero) }
                    .buttonStyle(.plain)
            }
            ForEach(picks.dropFirst(), id: \.videoID) { video in
                NavigationLink { VideoDetailView(video: video) } label: { row(video) }
                    .buttonStyle(.plain)
            }
            Micro(text: "That is all for today", size: 10, tracking: 1.6, color: .stashInk.opacity(0.4))
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .padding(.top, 18)
    }

    private func heroCard(_ video: Video) -> some View {
        let tint = video.category?.color ?? .categoryOther
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Micro(text: "Saved \(video.bookmarkedAt.formatted(.relative(presentation: .named)))", size: 9.5, tracking: 1.6, color: .stashOnAccent.opacity(0.7))
                Spacer()
                Micro(text: video.category?.singular ?? "Save", size: 9.5, tracking: 1.6, color: .stashOnAccent.opacity(0.7))
            }
            Text(video.rowTitle)
                .font(.archivo(23, .heavy))
                .foregroundStyle(Color.stashOnAccent)
                .multilineTextAlignment(.leading)
                .padding(.top, 9)
            Text(video.rowMeta)
                .font(.archivo(13, .semibold))
                .foregroundStyle(Color.stashOnAccent.opacity(0.8))
                .padding(.top, 4)
            if let other = related(to: video) {
                Divider().overlay(Color.stashOnAccent.opacity(0.3)).padding(.top, 14)
                HStack(spacing: 8) {
                    Micro(text: "Related", size: 9.5, tracking: 1.4, color: .stashOnAccent.opacity(0.7))
                    Text(other.rowTitle)
                        .font(.archivo(12, .semibold))
                        .foregroundStyle(Color.stashOnAccent)
                        .lineLimit(1)
                }
                .padding(.top, 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .stashCard(fill: tint)
    }

    private func row(_ video: Video) -> some View {
        let tint = video.category?.color ?? .categoryOther
        return HStack(spacing: 13) {
            Thumbnail(url: video.thumbnailURL, category: video.category, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(video.rowTitle)
                    .font(.archivo(16, .bold))
                    .foregroundStyle(Color.stashInk)
                    .lineLimit(1)
                Text(video.rowMeta)
                    .font(.archivo(12.5))
                    .foregroundStyle(Color.stashInk.opacity(0.55))
                    .lineLimit(1)
                if let topic = video.topics.first {
                    Micro(text: topic, size: 10, tracking: 1.2, color: tint)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
        }
        .stashOutlineCard()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sun.max")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.35))
            Text("Nothing to surface yet")
                .font(.archivo(17, .bold))
                .foregroundStyle(Color.stashInk)
            Text("Import your TikTok favorites and Stash will pick three saves worth returning to each day.")
                .font(.archivo(13))
                .foregroundStyle(Color.stashInk.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    TodayView()
        .modelContainer(SampleData.previewContainer)
}
