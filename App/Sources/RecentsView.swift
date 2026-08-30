// RecentsView.swift
//
// The Recents tab (replaces TodayView's placeholder rotation): the latest saves under an
// honest window label, saves that arrived together grouped as threads, and one older save
// resurfaced at the bottom. The window/thread/resurface rules live in RecentsSelector;
// this file only draws the board.

import SwiftUI
import SwiftData
import TikTokBrainKit

struct RecentsView: View {
    @Query(sort: \Video.bookmarkedAt, order: .reverse) private var videos: [Video]

    private var pool: [Video] { videos.filter { !$0.needsLook } }

    private var board: RecentsSelector.Board? {
        RecentsSelector.board(pool.map {
            .init(id: $0.videoID, date: $0.bookmarkedAt, topics: $0.topics)
        })
    }

    private var byID: [String: Video] {
        Dictionary(uniqueKeysWithValues: pool.map { ($0.videoID, $0) })
    }

    var body: some View {
        NavigationStack {
            StashScrollView(tab: .today) {
                VStack(alignment: .leading, spacing: 0) {
                    if let board {
                        header(board)
                        content(board)
                    } else {
                        header(nil)
                        emptyState.padding(.top, 60)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, stashTabBarClearance)
            }
            .background(Color.stashBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Sections

    private func header(_ board: RecentsSelector.Board?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Micro(text: "STASH", size: 11, tracking: 3.4, color: .stashInk)
                Spacer()
                Micro(text: Date().formatted(.dateTime.weekday(.abbreviated)) + " · " + Date().formatted(.dateTime.month(.wide).day()), size: 11, tracking: 1.4, color: .stashInk.opacity(0.5))
            }
            Text(board.map { "Since \($0.windowStart.formatted(.dateTime.month(.abbreviated).day()))." } ?? "Recents.")
                .font(.archivo(33, .heavy))
                .foregroundStyle(Color.stashInk)
                .padding(.top, 2)
            Text(board.map { "\($0.saveCount == 1 ? "1 save" : "\($0.saveCount) saves"). Newest first, no feed." } ?? "")
                .font(.archivo(13, .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.55))
        }
        .padding(.top, 8)
    }

    private func content(_ board: RecentsSelector.Board) -> some View {
        VStack(spacing: 12) {
            if let hero = board.heroID.flatMap({ byID[$0] }) {
                NavigationLink { VideoDetailView(video: hero) } label: { heroCard(hero) }
                    .buttonStyle(.plain)
            }
            ForEach(board.threads, id: \.theme) { thread in
                let members = thread.saveIDs.compactMap { byID[$0] }
                NavigationLink { ThreadListView(theme: thread.theme, videos: members) } label: {
                    threadRow(thread.theme, members)
                }
                .buttonStyle(.plain)
            }
            ForEach(board.looseIDs.compactMap { byID[$0] }, id: \.videoID) { video in
                NavigationLink { VideoDetailView(video: video) } label: { row(video) }
                    .buttonStyle(.plain)
            }
            if let resurface = board.resurfaceID.flatMap({ byID[$0] }) {
                NavigationLink { VideoDetailView(video: resurface) } label: { resurfaceCard(resurface) }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
            }
            Micro(text: "Older lives in the library", size: 10, tracking: 1.6, color: .stashInk.opacity(0.4))
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .padding(.top, 18)
    }

    // MARK: - Cards

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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .stashCard(fill: tint)
    }

    /// A thread reads as one row: overlapping member thumbnails, the shared theme, and the
    /// days the binge covered.
    private func threadRow(_ theme: String, _ members: [Video]) -> some View {
        HStack(spacing: 13) {
            HStack(spacing: -9) {
                ForEach(members.prefix(3), id: \.videoID) { member in
                    Thumbnail(url: member.thumbnailURL, category: member.category, size: 34)
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.stashBackground, lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.prefix(1).uppercased() + theme.dropFirst())
                    .font(.archivo(16, .bold))
                    .foregroundStyle(Color.stashInk)
                    .lineLimit(1)
                Text("\(members.count) saves · \(dayRange(of: members))")
                    .font(.archivo(12.5))
                    .foregroundStyle(Color.stashInk.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Micro(text: "Thread", size: 9.5, tracking: 1.4, color: members.first?.category?.color ?? .stashInk)
        }
        .stashOutlineCard()
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

    private func resurfaceCard(_ video: Video) -> some View {
        let tint = video.category?.color ?? .categoryOther
        return VStack(alignment: .leading, spacing: 0) {
            Micro(text: "Worth returning to · saved \(video.bookmarkedAt.formatted(.relative(presentation: .named)))", size: 9.5, tracking: 1.6, color: .stashOnAccent.opacity(0.7))
            Text(video.rowTitle)
                .font(.archivo(17, .heavy))
                .foregroundStyle(Color.stashOnAccent)
                .multilineTextAlignment(.leading)
                .padding(.top, 8)
            Text(video.rowMeta)
                .font(.archivo(12.5, .semibold))
                .foregroundStyle(Color.stashOnAccent.opacity(0.8))
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .stashCard(fill: tint)
    }

    /// "Jul 8–9", "Jun 29 – Jul 2", or just "Jul 8" for a single-day thread.
    private func dayRange(of members: [Video]) -> String {
        let dates = members.map(\.bookmarkedAt)
        guard let newest = dates.max(), let oldest = dates.min() else { return "" }
        let fmt = Date.FormatStyle().month(.abbreviated).day()
        if Calendar.current.isDate(oldest, inSameDayAs: newest) { return oldest.formatted(fmt) }
        if Calendar.current.isDate(oldest, equalTo: newest, toGranularity: .month) {
            return "\(oldest.formatted(fmt))–\(newest.formatted(.dateTime.day()))"
        }
        return "\(oldest.formatted(fmt)) – \(newest.formatted(fmt))"
    }

    private var emptyState: some View {
        StashEmptyState(
            symbol: "clock.arrow.circlepath",
            title: "Nothing recent yet",
            message: "Import your TikTok favorites and your latest saves gather here, threads and all."
        )
    }
}

/// A thread, unfolded: the member saves as plain rows, newest first.
struct ThreadListView: View {
    let theme: String
    let videos: [Video]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Micro(text: "Thread · \(videos.count) saves", size: 11, tracking: 1.8, color: .stashInk.opacity(0.5))
                    .padding(.top, 6)
                Text(theme.prefix(1).uppercased() + theme.dropFirst())
                    .font(.archivo(29, .heavy))
                    .foregroundStyle(Color.stashInk)
                ForEach(videos, id: \.videoID) { video in
                    NavigationLink { VideoDetailView(video: video) } label: {
                        HStack(spacing: 13) {
                            Thumbnail(url: video.thumbnailURL, category: video.category, size: 46)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(video.rowTitle)
                                    .font(.archivo(16, .bold))
                                    .foregroundStyle(Color.stashInk)
                                    .lineLimit(2)
                                Text(video.rowMeta)
                                    .font(.archivo(12.5))
                                    .foregroundStyle(Color.stashInk.opacity(0.55))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .stashOutlineCard()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, stashTabBarClearance)
        }
        .background(Color.stashBackground.ignoresSafeArea())
    }
}

#Preview {
    RecentsView()
        .modelContainer(SampleData.previewContainer)
}
