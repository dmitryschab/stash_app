// CodeView.swift
//
// The Code tab: every coding save, links first. Coding saves are screencasts and talking
// heads, so Cook's photo wall would say nothing here — rows carry the tech tag and the link
// count instead, and the up-right arrow marks the saves that actually lead somewhere. Built
// on Cook's bones: StashHeader, tag chips (TopicChip / TopicPicker over CodeData.techTags),
// a featured card for the newest save, month runs with the TimeRail.

import SwiftUI
import SwiftData
import TikTokBrainKit

struct CodeView: View {
    @Query(sort: \Video.bookmarkedAt, order: .reverse) private var videos: [Video]
    @State private var focus: String?   // selected tech tag; nil = all
    @State private var browsingTags = false

    private var saves: [Video] {
        videos.filter { !$0.needsLook && $0.category == .coding }
    }

    private func matches(_ video: Video) -> Bool {
        guard let focus else { return true }
        return video.codeNote?.techTags.contains(focus) ?? false
    }

    /// A chosen tag removes the rest rather than dimming them (see CookView.shown).
    private var shown: [Video] {
        saves.filter(matches)
    }

    /// Every tech tag across the shelf with how many saves carry it, most-used first.
    private var tags: [TopicCount] {
        var counts: [String: Int] = [:]
        for video in saves {
            for tag in video.codeNote?.techTags ?? [] { counts[tag, default: 0] += 1 }
        }
        return counts
            .map { TopicCount(name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    /// The five most-used tags — plus whatever is in focus, which the picker may have set to
    /// something far down the tail (see CookView.rowTopics).
    private var rowTags: [TopicCount] {
        let head = Array(tags.filter { $0.count >= TopicPicker.browseFloor }.prefix(5))
        guard let focus, !head.contains(where: { $0.name == focus }) else { return head }
        let selected = tags.first { $0.name == focus } ?? TopicCount(name: focus, count: 0)
        return [selected] + head.dropLast()
    }

    private var trailing: String {
        guard focus != nil else { return "\(saves.count) saves" }
        return "\(shown.count) of \(saves.count)"
    }

    /// Rows after the featured card, in month runs so the time rail has something to jump to.
    private var runs: [MonthRun<Video>] {
        monthRuns(Array(shown.dropFirst())) { $0.bookmarkedAt }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                StashScrollView(tab: .code) {
                    VStack(alignment: .leading, spacing: 0) {
                        StashHeader(title: "Code", trailing: trailing)
                            .padding(.top, 8)
                        if !tags.isEmpty {
                            chips.padding(.top, 8)
                        }
                        if let featured = shown.first {
                            NavigationLink { VideoDetailView(video: featured) } label: { featuredCard(featured) }
                                .buttonStyle(.plain)
                                .padding(.top, 14)
                        }
                        if shown.isEmpty {
                            emptyState.padding(.top, 48)
                        } else {
                            rows
                        }
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

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                TopicChip(label: "all", isOn: focus == nil) { focus = nil }
                ForEach(rowTags) { tag in
                    TopicChip(label: tag.name, count: tag.count, isOn: focus == tag.name) {
                        focus = focus == tag.name ? nil : tag.name
                    }
                }
                TopicChip(label: "more", symbol: "ellipsis", isOn: false) { browsingTags = true }
            }
        }
        .sheet(isPresented: $browsingTags) {
            TopicPicker(topics: tags, focus: $focus)
        }
    }

    /// Library's "Latest save" card, but the body line is the code note's summary and the
    /// foot carries tag chips — it reads like a changelog entry.
    private func featuredCard(_ video: Video) -> some View {
        let note = video.codeNote
        let summary = note.flatMap { $0.summary.isEmpty ? nil : $0.summary } ?? video.summary
        return VStack(alignment: .leading, spacing: 0) {
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
            if !summary.isEmpty {
                Text(summary)
                    .font(.archivo(14, .semibold))
                    .foregroundStyle(Color.stashOnAccent.opacity(0.8))
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .padding(.top, 4)
            }
            HStack(spacing: 6) {
                ForEach((note?.techTags ?? []).prefix(2), id: \.self) { tag in
                    Micro(text: tag, size: 9.5, tracking: 1.4, color: .stashOnAccent)
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
        .stashCard(fill: .categoryCoding)
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(runs) { run in
                Micro(text: run.title, size: 10, tracking: 2.2, color: .stashInk.opacity(0.45))
                    .padding(.top, 18)
                    .padding(.bottom, 4)
                    .id(run.id)
                ForEach(run.items, id: \.videoID) { video in
                    NavigationLink { VideoDetailView(video: video) } label: { CodeRow(video: video) }
                        .buttonStyle(.plain)
                    Divider().overlay(Color.stashInk.opacity(0.12))
                }
            }
        }
        .animation(.easeOut(duration: 0.35), value: focus)
    }

    private var emptyState: some View {
        StashEmptyState(
            symbol: Category.coding.symbol,
            tint: .categoryCoding,
            title: "Nothing in code yet",
            message: videos.isEmpty
                ? "Coding saves land here, links first, once your favorites are in."
                : "None of your saves came back as code yet — the shelf fills as they are analyzed.",
            offersImport: videos.isEmpty
        )
    }
}

// MARK: - Row

/// Compact row: the first tech tag in green, then the link count — or the author when the
/// save points nowhere. The green up-right arrow is the tell for a save with links.
private struct CodeRow: View {
    let video: Video

    var body: some View {
        let note = video.codeNote
        let tag = note?.techTags.first
        let links = note?.links.count ?? 0
        HStack(spacing: 11) {
            Thumbnail(url: video.thumbnailURL, category: .coding, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(video.rowTitle)
                    .font(.archivo(15, .bold))
                    .foregroundStyle(Color.stashInk)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let tag {
                        Micro(text: tag, size: 10, tracking: 1.2, color: .categoryCoding)
                    }
                    Text(meta(links: links, tagged: tag != nil))
                        .font(.archivo(12))
                        .foregroundStyle(Color.stashInk.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: links > 0 ? "arrow.up.right" : "chevron.right")
                .font(.system(size: links > 0 ? 14 : 12, weight: .bold))
                .foregroundStyle(links > 0 ? Color.categoryCoding : Color.stashInk.opacity(0.4))
        }
        .padding(.vertical, 9)
    }

    private func meta(links: Int, tagged: Bool) -> String {
        let tail: String
        if links > 0 {
            tail = "\(links) link\(links == 1 ? "" : "s")"
        } else if !video.author.isEmpty {
            tail = "@\(video.author)"
        } else {
            return ""
        }
        return tagged ? "· \(tail)" : tail
    }
}

#Preview {
    CodeView()
        .modelContainer(SampleData.previewContainer)
}
