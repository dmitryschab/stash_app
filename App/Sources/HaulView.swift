// HaulView.swift
//
// The Haul tab: everything your saves are trying to sell you, pulled out of every category and
// hung on one shelf. Built on Code's bones — StashHeader, chips, a featured card, month runs
// with the TimeRail. The row unit is the save: one video that runs through six products is ONE
// row here, and the six live inside, on the save's own page — six sibling rows made a haul
// video read as six unrelated saves. A save with a single pick still reads as the pick itself.
//
// The other tabs are windows onto a `Category`. This one is a query: a `BuyPick` hangs off the
// analysis regardless of what the save was filed under, so the sneakers from a style video and
// the desk lamp from a home tour land side by side. See `BuyPick` for why that is the only
// payload built that way.
//
// A row's tap opens the pick's own page (`HaulDetailView`), which is where prices live — looked
// up there, for the reader's country, never here. The bag glyph keeps the keyless escape hatch:
// a search URL at a store (`Shop`), which needs no API key, no affiliate account and no quota.

import SwiftUI
import SwiftData
import TikTokBrainKit

/// One pick, plus the save it came out of. `id` carries the index because a video may recommend
/// two things with the same name (two colourways, a bundle listed twice) and a list cannot hold
/// two rows with one id.
private struct HaulItem: Identifiable {
    let video: Video
    let pick: BuyPick
    let index: Int

    var id: String { "\(video.videoID)#\(index)" }
    var date: Date { video.bookmarkedAt }
    /// What gets typed into the store's search box. The brand is already inside `name` when the
    /// video gave one — this is deliberately not "name + kind", which turns "Nike Vomero 5" into
    /// "Nike Vomero 5 sneakers" and narrows a good query into a bad one.
    var query: String { pick.name }
}

/// One save's worth of picks: the row unit of the shelf.
private struct HaulSave: Identifiable {
    let video: Video
    let items: [HaulItem]

    var id: String { video.videoID }
    var date: Date { video.bookmarkedAt }
}

struct HaulView: View {
    @Query(sort: \Video.bookmarkedAt, order: .reverse) private var videos: [Video]
    @State private var focus: String?   // selected kind; nil = all
    @State private var browsingKinds = false

    /// Every pick in the library, newest save first, in the order each video presented them.
    private var items: [HaulItem] {
        videos.filter { !$0.needsLook }.flatMap { video in
            video.buys.enumerated().map { HaulItem(video: video, pick: $1, index: $0) }
        }
    }

    private var shown: [HaulItem] {
        guard let focus else { return items }
        return items.filter { $0.pick.kind == focus }
    }

    /// How many saves contributed at least one pick — the honest denominator for "9 of 412
    /// saves had something in them", which is the number that says whether the shelf is working.
    private var sourceCount: Int {
        Set(items.map(\.video.videoID)).count
    }

    /// Every kind across the shelf with how many picks carry it, most-used first.
    private var kinds: [TopicCount] {
        var counts: [String: Int] = [:]
        for item in items where !item.pick.kind.isEmpty {
            counts[item.pick.kind, default: 0] += 1
        }
        return counts
            .map { TopicCount(name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    /// The five most-used kinds — plus whatever is in focus, which the picker may have set to
    /// something far down the tail (see CookView.rowTopics).
    private var rowKinds: [TopicCount] {
        let head = Array(kinds.filter { $0.count >= TopicPicker.browseFloor }.prefix(5))
        guard let focus, !head.contains(where: { $0.name == focus }) else { return head }
        let selected = kinds.first { $0.name == focus } ?? TopicCount(name: focus, count: 0)
        return [selected] + head.dropLast()
    }

    private var trailing: String {
        guard focus == nil else { return "\(shown.count) of \(items.count)" }
        return "\(items.count) item\(items.count == 1 ? "" : "s") · \(sourceCount) saves"
    }

    /// The (filtered) picks regrouped one row per save, newest save first. Under a kind focus a
    /// six-pick haul may group down to the one matching pick — it then reads as that pick.
    private var saves: [HaulSave] {
        var rowIndex: [String: Int] = [:]
        var result: [HaulSave] = []
        for item in shown {
            if let at = rowIndex[item.video.videoID] {
                result[at] = HaulSave(video: result[at].video, items: result[at].items + [item])
            } else {
                rowIndex[item.video.videoID] = result.count
                result.append(HaulSave(video: item.video, items: [item]))
            }
        }
        return result
    }

    /// The featured card already wears the newest save (and links to it), so its row is dropped
    /// whole — the old dropFirst() kept the same video's other picks as rows, which is exactly
    /// the duplication the per-save row exists to end.
    private var runs: [MonthRun<HaulSave>] {
        let featuredID = shown.first?.video.videoID
        return monthRuns(saves.filter { $0.id != featuredID }) { $0.date }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                StashScrollView(tab: .haul) {
                    VStack(alignment: .leading, spacing: 0) {
                        StashHeader(title: "Haul", trailing: trailing)
                            .padding(.top, 8)
                        if !kinds.isEmpty {
                            chips.padding(.top, 8)
                        }
                        if let featured = shown.first {
                            featuredCard(featured).padding(.top, 14)
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
                ForEach(rowKinds) { kind in
                    TopicChip(label: kind.name, count: kind.count, isOn: focus == kind.name) {
                        focus = focus == kind.name ? nil : kind.name
                    }
                }
                TopicChip(label: "more", symbol: "ellipsis", isOn: false) { browsingKinds = true }
            }
        }
        .sheet(isPresented: $browsingKinds) {
            TopicPicker(topics: kinds, focus: $focus)
        }
    }

    /// The newest pick, big. The whole card opens the pick's page — offers, product frame, the
    /// lot — and the small "from this save" row underneath stays the shortcut to the video.
    private func featuredCard(_ item: HaulItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                HaulDetailView(video: item.video, pick: item.pick, pickIndex: item.index)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Micro(text: "Latest want", size: 10, tracking: 2.2, color: .stashOnAccent.opacity(0.65))
                        Spacer()
                        Micro(text: item.date.formatted(.relative(presentation: .named)), size: 10, tracking: 2, color: .stashOnAccent.opacity(0.65))
                    }
                    Text(item.pick.name)
                        .font(.archivo(24, .heavy))
                        .foregroundStyle(Color.stashOnAccent)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 10)
                    if !item.pick.price.isEmpty {
                        Text(item.pick.price)
                            .font(.archivo(15, .semibold))
                            .foregroundStyle(Color.stashOnAccent.opacity(0.8))
                            .padding(.top, 4)
                    }
                    HStack(spacing: 6) {
                        if !item.pick.kind.isEmpty {
                            Micro(text: item.pick.kind, size: 9.5, tracking: 1.4, color: .stashOnAccent)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(Capsule().strokeBorder(Color.stashOnAccent.opacity(0.5), lineWidth: 1.2))
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.stashOnAccent)
                            .frame(width: 32, height: 32)
                            .background(Circle().strokeBorder(Color.stashOnAccent.opacity(0.6), lineWidth: 1.5))
                    }
                    .padding(.top, 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .stashArtCard(fill: .stashHaul,
                              art: PickFrameStore.shared.frame(videoID: item.video.videoID,
                                                               pickIndex: item.index)
                                   ?? item.video.thumbnailURL)
            }
            .buttonStyle(.plain)
            NavigationLink { VideoDetailView(video: item.video) } label: {
                HStack(spacing: 6) {
                    Micro(text: "from \(item.video.rowTitle)", size: 9.5, tracking: 1.2,
                          color: .stashInk.opacity(0.5))
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.stashInk.opacity(0.4))
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(runs) { run in
                Micro(text: run.title, size: 10, tracking: 2.2, color: .stashInk.opacity(0.45))
                    .padding(.top, 18)
                    .padding(.bottom, 4)
                    .id(run.id)
                ForEach(run.items) { save in
                    HaulSaveRow(save: save)
                    Divider().overlay(Color.stashInk.opacity(0.12))
                }
            }
        }
        .animation(.easeOut(duration: 0.35), value: focus)
    }

    private var emptyState: some View {
        StashEmptyState(
            symbol: StashTab.haul.symbol,
            tint: .stashHaul,
            title: focus == nil ? "Nothing to buy yet" : "Nothing in \(focus ?? "")",
            message: videos.isEmpty
                ? "When a save is built around some thing — shoes, a phone, a chair — it lands here with a way to go find it."
                : "None of your saves named a product yet. Most posts sell nothing, and the shelf fills as the rest are analyzed.",
            offersImport: videos.isEmpty
        )
    }
}

// MARK: - Row

/// One save. A save with a single pick reads as the pick itself — name, price, bag menu, the
/// pick's own page — and a save with several reads as the video with its product count, and
/// opens the save's page, where every pick is listed with its own row.
private struct HaulSaveRow: View {
    let save: HaulSave

    var body: some View {
        if save.items.count == 1, let item = save.items.first {
            HaulRow(item: item)
        } else {
            NavigationLink { VideoDetailView(video: save.video) } label: {
                HStack(spacing: 11) {
                    Thumbnail(url: save.video.thumbnailURL,
                              category: save.video.category, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(save.video.rowTitle)
                            .font(.archivo(15, .bold))
                            .foregroundStyle(Color.stashInk)
                            .multilineTextAlignment(.leading)
                            .lineLimit(1)
                        Text(meta)
                            .font(.archivo(12))
                            .foregroundStyle(Color.stashInk.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.stashInk.opacity(0.4))
                        .frame(width: 44, height: 44)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 9)
            .accessibilityLabel("Open \(save.video.rowTitle)")
        }
    }

    private var meta: String {
        let tail = save.video.author.isEmpty ? "" : "@\(save.video.author)"
        return ["\(save.items.count) products", tail].filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// One pick: thumbnail, the searchable name, then kind · price · author. Tapping the text
/// opens the pick's page; the bag on the right keeps the quick search menu. The thumbnail is
/// the pick's own frame once one is extracted.
private struct HaulRow: View {
    let item: HaulItem

    var body: some View {
        HStack(spacing: 11) {
            NavigationLink {
                HaulDetailView(video: item.video, pick: item.pick, pickIndex: item.index)
            } label: {
                HStack(spacing: 11) {
                    Thumbnail(url: PickFrameStore.shared.frame(videoID: item.video.videoID,
                                                               pickIndex: item.index)
                                   ?? item.video.thumbnailURL,
                              category: item.video.category, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.pick.name)
                            .font(.archivo(15, .bold))
                            .foregroundStyle(Color.stashInk)
                            .multilineTextAlignment(.leading)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if !item.pick.price.isEmpty {
                                Micro(text: item.pick.price, size: 10, tracking: 1.2, color: .stashHaul)
                            }
                            Text(meta)
                                .font(.archivo(12))
                                .foregroundStyle(Color.stashInk.opacity(0.55))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ShopMenu(item: item) {
                Image(systemName: "bag")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.stashHaul)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 9)
    }

    /// Kind, then whoever recommended it — the author matters more here than elsewhere, because
    /// "who told me to buy this" is half of whether you still want it.
    private var meta: String {
        let tail = item.video.author.isEmpty ? "" : "@\(item.video.author)"
        let head = item.pick.kind
        return [head, tail].filter { !$0.isEmpty }
            .joined(separator: " · ")
            .prefixedBySeparator(if: !item.pick.price.isEmpty)
    }
}

private extension String {
    /// Prepends the row's "· " only when something already sits to the left of it.
    func prefixedBySeparator(if condition: Bool) -> String {
        condition && !isEmpty ? "· \(self)" : self
    }
}

// MARK: - Going shopping

/// The store menu behind every pick. A link, not an integration: `Shop.searchURL` builds a plain
/// search URL, so this needs no key, no account and no network call of its own — and a pick the
/// video linked directly keeps that link at the top, where it is a better answer than any search.
private struct ShopMenu<Trigger: View>: View {
    let item: HaulItem
    // Not named `Label`: the generic would shadow SwiftUI's `Label` inside the menu below.
    @ViewBuilder var trigger: Trigger

    var body: some View {
        Menu {
            if let link = item.pick.link {
                Link(destination: link) {
                    Label("Open the link from the video", systemImage: "arrow.up.right")
                }
            }
            ForEach(Shop.allCases, id: \.self) { shop in
                if let url = shop.searchURL(for: item.query) {
                    Link(destination: url) {
                        Label("Search \(shop.label)", systemImage: "magnifyingglass")
                    }
                }
            }
        } label: {
            trigger
        }
        .accessibilityLabel("Shop for \(item.pick.name)")
    }
}

#Preview {
    HaulView()
        .modelContainer(SampleData.previewContainer)
}
