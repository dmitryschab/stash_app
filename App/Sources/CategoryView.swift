// CategoryView.swift
//
// The plain section: one category's saves as dated rows, for every category without a
// screen of its own (Cook, Music, Code and Films keep theirs). Any of these can hold a slot
// on the pill — chosen in Settings, or by the focus picker after the first import — and
// Library hands the category over while the tab is on (`libraryShelves(visible:)`).
//
// While an import is sorting, the rows that have not landed yet are drawn as skeletons in
// the category's tint: as many as the map expects, minus what is already here.

import SwiftUI
import SwiftData
import TikTokBrainKit

struct CategoryView: View {
    let tab: StashTab

    @Query(sort: \Video.bookmarkedAt, order: .reverse) private var videos: [Video]
    private var center = PipelineCenter.shared

    init(tab: StashTab) { self.tab = tab }

    private var category: Category { tab.ownedCategory ?? .other }

    /// Rows an analysis has written. A guessed row is a skeleton, not a row: it has no title,
    /// no thumbnail and no summary to show.
    private var analysed: [Video] {
        videos.filter { $0.category == category && !$0.isGuessed && !$0.needsLook }
    }

    /// Guessed rows count as skeletons only while the import that guessed them is running;
    /// afterwards they are failures the archive retries, not placeholders.
    private var guessed: Int {
        guard center.isShapingLibrary else { return 0 }
        return videos.filter { $0.category == category && $0.isGuessed && !$0.unavailable }.count
    }

    private var sorting: Int { guessed + center.expected(category) }

    private var runs: [MonthRun<Video>] { monthRuns(analysed) { $0.bookmarkedAt } }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                StashScrollView(tab: tab) {
                    VStack(alignment: .leading, spacing: 0) {
                        StashHeader(title: category.displayName, trailing: "\(analysed.count) saves")
                            .padding(.top, 8)
                        if analysed.isEmpty && sorting == 0 {
                            emptyState.padding(.top, 48)
                        } else {
                            list.padding(.top, 4)
                        }
                        SkeletonShelf(count: sorting, tint: category.color, symbol: category.symbol)
                            .padding(.top, analysed.isEmpty ? 8 : 0)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, stashTabBarClearance)
                }
                .background(Color.stashBackground.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .overlay(alignment: .trailing) {
                    let entries = timeRailEntries(for: runs)
                    if entries.count >= 2 {
                        TimeRail(entries: entries, proxy: proxy)
                    }
                }
            }
        }
    }

    private var list: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(runs) { run in
                Micro(text: run.title, size: 10, tracking: 2.2, color: .stashInk.opacity(0.62))
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                    .id(run.id)
                ForEach(run.items, id: \.videoID) { video in
                    NavigationLink { VideoDetailView(video: video) } label: {
                        LibraryRow(video: video, tint: category.color)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Color.stashInk.opacity(0.12))
                }
            }
        }
    }

    private var emptyState: some View {
        Text("Nothing filed under \(category.displayName.lowercased()) yet.")
            .font(.archivo(14, .semibold))
            .foregroundStyle(Color.stashInk.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
