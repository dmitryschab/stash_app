// HaulView.swift
//
// The Haul tab: everything your saves are trying to sell you, pulled out of every category and
// hung on one shelf. Built on Code's bones — StashHeader, chips, a featured card, month runs
// with the TimeRail — but the unit of a row is different, and that difference is the whole
// section. Cook lists recipes, Code lists saves; Haul lists *picks*. One video that runs
// through six products is six rows here, because six is how many things you wanted.
//
// The other tabs are windows onto a `Category`. This one is a query: a `BuyPick` hangs off the
// analysis regardless of what the save was filed under, so the sneakers from a style video and
// the desk lamp from a home tour land side by side. See `BuyPick` for why that is the only
// payload built that way.
//
// Nothing here knows a product's price, stock or seller, and nothing tries to: a row's action is
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

    private var runs: [MonthRun<HaulItem>] {
        monthRuns(Array(shown.dropFirst())) { $0.date }
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

    /// The newest pick, big. Not a NavigationLink like Code's: the card's job here is the
    /// shopping action, so the whole card is the store button and the small "from this save"
    /// row underneath is the way to the video.
    private func featuredCard(_ item: HaulItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ShopMenu(item: item) {
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
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.stashOnAccent)
                            .frame(width: 32, height: 32)
                            .background(Circle().strokeBorder(Color.stashOnAccent.opacity(0.6), lineWidth: 1.5))
                    }
                    .padding(.top, 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .stashArtCard(fill: .stashHaul, art: item.video.thumbnailURL)
            }
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
                ForEach(run.items) { item in
                    HaulRow(item: item)
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

/// One pick: thumbnail, the searchable name, then kind · price · author. Tapping the text goes
/// to the video it came from; the bag on the right goes shopping.
private struct HaulRow: View {
    let item: HaulItem

    var body: some View {
        HStack(spacing: 11) {
            NavigationLink { VideoDetailView(video: item.video) } label: {
                HStack(spacing: 11) {
                    Thumbnail(url: item.video.thumbnailURL, category: item.video.category, size: 36)
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
