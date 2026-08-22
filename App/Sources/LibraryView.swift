// LibraryView.swift
//
// The Library tab, Set List style: STASH header, category filter pills, a featured card for
// the segment's latest save, list rows on the cream sheet, and the shared "needs a look"
// pile. Import/pipeline lives behind the header's import button, Settings — account deletion,
// data export, legal — behind its gear.

import SwiftUI
import SwiftData
import TikTokBrainKit

struct LibraryView: View {
    @Query(sort: \Video.bookmarkedAt, order: .reverse) private var videos: [Video]
    // Simulator smoke runs can open a specific segment: `-initialSegment music|coding|other`.
    @State private var segment: Category = {
        switch UserDefaults.standard.string(forKey: "initialSegment") {
        case "music": .music
        case "coding": .coding
        case "other": .other
        default: .recipe
        }
    }()
    @State private var selectedTopic: String?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                StashScrollView(tab: .library) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        pills.padding(.top, 14)
                        if !topicChips.isEmpty {
                            chips.padding(.top, 10)
                        }

                        if let featured = filtered.first {
                            NavigationLink { VideoDetailView(video: featured) } label: { featuredCard(featured) }
                                .buttonStyle(.plain)
                                .padding(.top, 14)
                        }

                        if filtered.isEmpty {
                            emptyState.padding(.top, 48)
                        } else {
                            sectionedRows
                        }

                        needsLookSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, stashTabBarClearance)
                }
                .background(Color.stashBackground.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $showSettings) { SettingsView() }
                .overlay(alignment: .trailing) {
                    let entries = timeRailEntries(for: sections)
                    if entries.count >= 2 {
                        TimeRail(entries: entries, proxy: proxy)
                    }
                }
            }
        }
        .onChange(of: segment) { _, _ in selectedTopic = nil }
    }

    // MARK: - Data

    private var inSegment: [Video] {
        videos.filter { !$0.needsLook && $0.category == segment }
    }

    /// Segment narrowed by the selected topic chip (nil = all).
    private var filtered: [Video] {
        guard let topic = selectedTopic else { return inSegment }
        return inSegment.filter { $0.topics.contains(topic) }
    }

    private var needsLook: [Video] {
        videos.filter(\.needsLook)
    }

    /// Top topics within the segment, by save count. Computed over the whole
    /// segment (not the filtered list) so chips don't vanish once selected.
    private var topicChips: [String] {
        var counts: [String: Int] = [:]
        for video in inSegment {
            for topic in video.topics { counts[topic, default: 0] += 1 }
        }
        return counts
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(6)
            .map(\.key)
    }

    /// Rows after the featured card, grouped into month runs.
    private var sections: [MonthRun<Video>] {
        monthRuns(Array(filtered.dropFirst())) { $0.bookmarkedAt }
    }

    // MARK: - Header + pills

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Micro(text: "STASH", size: 11, tracking: 3.4, color: .stashInk)
                Spacer()
                Micro(text: "\(videos.count) saves", size: 11, tracking: 1.4, color: .stashInk.opacity(0.5))
            }
            HStack(alignment: .center) {
                Text("Library")
                    .font(.archivo(40, .heavy))
                    .foregroundStyle(Color.stashInk)
                Spacer()
                HStack(spacing: 10) {
                    NavigationLink { ImportView() } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.stashInk)
                            .frame(width: 38, height: 38)
                            .background(Circle().strokeBorder(Color.stashInk, lineWidth: 1.5))
                    }
                    .accessibilityLabel("Import")
                    // Mind map lives here rather than in the tab bar — it is a view of this library.
                    NavigationLink { MindMapView() } label: {
                        Image(systemName: "circle.hexagongrid.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.stashInk)
                            .frame(width: 38, height: 38)
                            .background(Circle().strokeBorder(Color.stashInk, lineWidth: 1.5))
                    }
                    .accessibilityLabel("Mind map")
                    // Delete account and Export my data live in Settings, and guideline
                    // 5.1.1(v) asks for a deletion path the user can actually find. Behind
                    // the Import screen's gear it was two unlabelled icons deep, on a screen
                    // called "Import" — present, but not findable. This is the only top-level
                    // entry point; the Import one stays where the box config already is.
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.stashInk)
                            .frame(width: 38, height: 38)
                            .background(Circle().strokeBorder(Color.stashInk, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                }
            }
        }
        .padding(.top, 8)
    }

    private var pills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(librarySegments, id: \.self) { category in
                    Button { segment = category } label: {
                        Micro(
                            text: category.displayName,
                            size: 11,
                            tracking: 0.9,
                            color: segment == category ? .stashOnAccent : .stashInk
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background {
                            if segment == category {
                                Capsule().fill(category.color)
                            } else {
                                Capsule().strokeBorder(Color.stashInk, lineWidth: 1.5)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Featured + rows

    private func featuredCard(_ video: Video) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Micro(text: "Latest save", size: 10, tracking: 2.2, color: .stashOnAccent.opacity(0.65))
                Spacer()
                Micro(text: video.bookmarkedAt.formatted(.relative(presentation: .named)), size: 10, tracking: 2, color: .stashOnAccent.opacity(0.65))
            }
            Text(video.rowTitle)
                .font(.archivo(24, .heavy))
                .foregroundStyle(Color.stashOnAccent)
                .multilineTextAlignment(.leading)
                .padding(.top, 10)
            Text(video.rowMeta)
                .font(.archivo(14, .semibold))
                .foregroundStyle(Color.stashOnAccent.opacity(0.8))
                .padding(.top, 4)
            HStack {
                if let topic = video.topics.first {
                    Micro(text: topic, size: 9.5, tracking: 1.4, color: .stashOnAccent)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().strokeBorder(Color.stashOnAccent.opacity(0.5), lineWidth: 1.2))
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.stashOnAccent)
                    .frame(width: 32, height: 32)
                    .background(Circle().strokeBorder(Color.stashOnAccent.opacity(0.6), lineWidth: 1.5))
            }
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .stashCard(fill: segment.color)
    }

    /// Topic chip row: "all" + the segment's top topics.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("all", isOn: selectedTopic == nil) { selectedTopic = nil }
                ForEach(topicChips, id: \.self) { topic in
                    chip(topic, isOn: selectedTopic == topic) {
                        selectedTopic = selectedTopic == topic ? nil : topic
                    }
                }
            }
        }
    }

    private func chip(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Micro(text: label, size: 9.5, tracking: 0.8, color: isOn ? .stashOnAccent : .stashInk.opacity(0.65))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background {
                    if isOn {
                        Capsule().fill(Color.stashInk)
                    } else {
                        Capsule().strokeBorder(Color.stashInk.opacity(0.28), lineWidth: 1.2)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    /// Month-sectioned rows, lazily rendered — hundreds of rows per segment.
    private var sectionedRows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(sections, id: \.id) { section in
                Micro(text: section.title, size: 10, tracking: 2.2, color: .stashInk.opacity(0.45))
                    .padding(.top, 18)
                    .padding(.bottom, 4)
                    .id(section.id)
                ForEach(section.items, id: \.videoID) { video in
                    NavigationLink { VideoDetailView(video: video) } label: { LibraryRow(video: video) }
                        .buttonStyle(.plain)
                    Divider().overlay(Color.stashInk.opacity(0.12))
                }
            }
        }
    }

    @ViewBuilder
    private var needsLookSection: some View {
        if !needsLook.isEmpty {
            Micro(text: "Needs a look", size: 10, tracking: 1.8, color: .categoryOther)
                .padding(.top, 24)
            VStack(spacing: 0) {
                ForEach(needsLook, id: \.videoID) { video in
                    NavigationLink { VideoDetailView(video: video) } label: {
                        HStack(spacing: 12) {
                            Thumbnail(url: video.thumbnailURL, category: nil, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(video.rowTitle)
                                    .font(.archivo(16, .bold))
                                    .foregroundStyle(Color.stashInk)
                                    .lineLimit(1)
                                Text(video.unavailable ? "Unavailable — kept the original link" : "Not classified yet")
                                    .font(.archivo(12.5))
                                    .foregroundStyle(Color.categoryOther)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.stashInk.opacity(0.4))
                        }
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Color.stashInk.opacity(0.12))
                }
            }
        }
    }

    /// Two different emptinesses: a library with nothing in it at all (the first run — say so
    /// plainly and offer Import), versus one shelf that simply has no saves in it yet.
    private var emptyState: some View {
        StashEmptyState(
            symbol: videos.isEmpty ? "tray" : segment.symbol,
            tint: videos.isEmpty ? .stashInk.opacity(0.35) : segment.color,
            title: videos.isEmpty ? "Your library is empty" : "Nothing in \(segment.displayName.lowercased()) yet",
            message: videos.isEmpty
                ? "Import your TikTok favorites and Stash sorts them onto these shelves."
                : "Saves land on this shelf once they are analyzed as \(segment.displayName.lowercased()).",
            offersImport: false   // the header's import button is already one tap away
        )
    }
}

// MARK: - Row

/// Compact row: 36 pt thumb, tight padding — the Library carries hundreds of rows.
private struct LibraryRow: View {
    let video: Video

    var body: some View {
        HStack(spacing: 11) {
            Thumbnail(url: video.thumbnailURL, category: video.category, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(video.rowTitle)
                    .font(.archivo(15, .bold))
                    .foregroundStyle(Color.stashInk)
                    .lineLimit(1)
                Text(video.rowMeta)
                    .font(.archivo(12))
                    .foregroundStyle(Color.stashInk.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let link = video.soleMusicPick?.link {
                Link(destination: link) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.categoryMusic)
                }
                .accessibilityLabel("Open in your music app")
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.stashInk.opacity(0.4))
            }
        }
        .padding(.vertical, 9)
    }
}

#Preview {
    LibraryView()
        .modelContainer(SampleData.previewContainer)
}
