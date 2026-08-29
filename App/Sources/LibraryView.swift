// LibraryView.swift
//
// The Library tab as a desk: STASH header, then one scroll over intent shelves — To watch,
// To try, To buy, Moodboard, Reference — each shaped like its content (poster strips for the
// watchable, rows for the doable, a wall for the lookable), plus the shared "needs a look"
// pile. Import/pipeline lives behind the header's import button, Settings — account deletion,
// data export, legal — behind its gear.
//
// The desk replaced the category pills after measuring the real 855-save library: two shelves
// held ~480 saves while four pills pointed at fewer than 16 each, and the biggest shelf was
// text-dense Tech while the mid shelves (film, home, style) were visual — one flat row list
// fit none of them. Intent comes from `SaveIntent.classify`, derived on the fly from the
// analysis; categories still exist underneath (rows keep their tints, `libraryShelves` still
// scopes what this tab owns), they just stopped being the navigation.

import SwiftUI
import SwiftData
import TikTokBrainKit

struct LibraryView: View {
    /// The category shelves this library is responsible for, passed in because it depends on
    /// which sections the pill is currently showing — Library takes back the ones switched
    /// off. See `libraryShelves(visible:)`.
    let shelves: [Category]
    /// False when the Haul tab is on the pill and owns the buys — the same take-back rule,
    /// one payload over. A buys-carrying save then files by its next intent instead.
    let includeBuyShelf: Bool

    // Spelled out because `@Query private var videos` makes the synthesized memberwise
    // initializer private, and RootView is in another file.
    init(shelves: [Category] = libraryShelves(visible: TabSlots.fallback),
         includeBuyShelf: Bool = false) {
        self.shelves = shelves
        self.includeBuyShelf = includeBuyShelf
    }

    @Query(sort: \Video.bookmarkedAt, order: .reverse) private var videos: [Video]
    @State private var showSettings = false
    // Drives the incoming-share card; observed the same way RootView observes the sync pill.
    private var center = PipelineCenter.shared

    var body: some View {
        NavigationStack {
            StashScrollView(tab: .library) {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    if !center.pendingShares.isEmpty {
                        IncomingShareCard(shares: center.pendingShares)
                            .padding(.top, 14)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if deskIsEmpty {
                        emptyState.padding(.top, 48)
                    } else {
                        desk
                    }

                    needsLookSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, stashTabBarClearance)
                .animation(.spring(duration: 0.45, bounce: 0.25), value: center.pendingShares)
            }
            .background(Color.stashBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    // MARK: - Data

    /// Every save on this tab's shelves, filed by intent. Classified on the fly — intent is
    /// derived, so the rules can move without touching stored data.
    private var desked: [SaveIntent: [Video]] {
        let scope = Set(shelves)
        var out: [SaveIntent: [Video]] = [:]
        for video in videos where !video.needsLook {
            guard let category = video.category, scope.contains(category) else { continue }
            let intent = SaveIntent.classify(category: category, topics: video.topics,
                                             hasBuys: !video.buys.isEmpty,
                                             includeBuy: includeBuyShelf)
            out[intent, default: []].append(video)
        }
        return out
    }

    /// The buy shelf's unit is a pick, not a video, and it is cross-category on purpose —
    /// exactly Haul's query, shown here only while Haul has no tab of its own.
    private var buyPicks: [(video: Video, pick: BuyPick, index: Int)] {
        guard includeBuyShelf else { return [] }
        return videos.filter { !$0.needsLook }.flatMap { video in
            video.buys.enumerated().map { (video, $1, $0) }
        }
    }

    private var deskIsEmpty: Bool {
        desked.isEmpty && buyPicks.isEmpty
    }

    /// In-flight shares are excluded: until the fast pass classifies them, the incoming card
    /// at the top is their representation — a second "Not classified yet" row would show the
    /// same save twice.
    private var needsLook: [Video] {
        let inFlight = center.pendingShareVideoIDs
        return videos.filter { $0.needsLook && !inFlight.contains($0.videoID) }
    }

    // MARK: - Header

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

    // MARK: - The desk

    /// Fixed order, not biggest-first: a desk sorts by urgency of use — things to act on
    /// first, the archive last — and a stable order is what makes shelves findable by thumb.
    @ViewBuilder
    private var desk: some View {
        if let watch = desked[.watch] { watchShelf(watch) }
        if let doable = desked[.tryIt] { rowShelf(.tryIt, doable, badge: "try it") }
        if !buyPicks.isEmpty { buyShelf(buyPicks) }
        if let mood = desked[.mood] { moodShelf(mood) }
        if let reference = desked[.reference] { rowShelf(.reference, reference) }
    }

    private func shelfHeader(_ title: String, count: Int, tint: Color,
                             @ViewBuilder destination: @escaping () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Micro(text: "\(title) · \(count)", size: 10, tracking: 2, color: tint)
            Spacer()
            NavigationLink { destination() } label: {
                Micro(text: "all ›", size: 9, tracking: 1.4, color: .stashInk.opacity(0.45))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("All \(title.lowercased()) saves")
        }
        .padding(.top, 24)
    }

    /// The watchable, as a poster rail — the one shelf whose saves are chosen by look.
    @ViewBuilder
    private func watchShelf(_ shelf: [Video]) -> some View {
        let intent = SaveIntent.watch
        shelfHeader(intent.deskTitle, count: shelf.count, tint: intent.deskTint) {
            IntentListView(title: intent.deskTitle, tint: intent.deskTint, videos: shelf)
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(shelf.prefix(12), id: \.videoID) { video in
                    NavigationLink { VideoDetailView(video: video) } label: {
                        PosterCard(video: video)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 8)
    }

    /// The doable and the archive share one shape: compact rows, three deep, the rest behind
    /// "all ›". `badge` marks the doable rows — the shelf that is a to-do list says so.
    @ViewBuilder
    private func rowShelf(_ intent: SaveIntent, _ shelf: [Video], badge: String? = nil) -> some View {
        shelfHeader(intent.deskTitle, count: shelf.count, tint: intent.deskTint) {
            IntentListView(title: intent.deskTitle, tint: intent.deskTint, videos: shelf)
        }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shelf.prefix(3).enumerated()), id: \.element.videoID) { index, video in
                if index > 0 { Divider().overlay(Color.stashInk.opacity(0.12)) }
                NavigationLink { VideoDetailView(video: video) } label: {
                    LibraryRow(video: video, tint: intent.deskTint, badge: badge,
                               badgeTint: intent.deskTint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }

    /// Picks wearing prices: the stated one, or the checked one once the pick page has looked
    /// it up (cache-only here — a shelf row never spends a lookup).
    @ViewBuilder
    private func buyShelf(_ picks: [(video: Video, pick: BuyPick, index: Int)]) -> some View {
        let intent = SaveIntent.buy
        shelfHeader(intent.deskTitle, count: picks.count, tint: intent.deskTint) {
            BuyListView(picks: picks)
        }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(picks.prefix(3).enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider().overlay(Color.stashInk.opacity(0.12)) }
                BuyShelfRow(video: item.video, pick: item.pick, pickIndex: item.index)
            }
        }
        .padding(.top, 2)
    }

    /// The lookable, two-up — a wall, not a list, because these saves are their pictures.
    @ViewBuilder
    private func moodShelf(_ shelf: [Video]) -> some View {
        let intent = SaveIntent.mood
        shelfHeader(intent.deskTitle, count: shelf.count, tint: intent.deskTint) {
            IntentListView(title: intent.deskTitle, tint: intent.deskTint, videos: shelf)
        }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)],
                  spacing: 9) {
            ForEach(shelf.prefix(4), id: \.videoID) { video in
                NavigationLink { VideoDetailView(video: video) } label: {
                    MoodTile(video: video)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
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

    private var emptyState: some View {
        StashEmptyState(
            symbol: "tray",
            title: videos.isEmpty ? "Your library is empty" : "Nothing on the desk yet",
            message: videos.isEmpty
                ? "Import your TikTok favorites and Stash sorts them onto these shelves."
                : "Saves land here once they are analyzed.",
            offersImport: false   // the header's import button is already one tap away
        )
    }
}

// MARK: - Intent display

extension SaveIntent {
    /// The shelf's spoken name — a purpose, not a taxonomy label.
    var deskTitle: String {
        switch self {
        case .buy: "To buy"
        case .watch: "To watch"
        case .tryIt: "To try"
        case .mood: "Moodboard"
        case .reference: "Reference"
        }
    }

    /// Borrowed jewel tones: an intent is not a category, but it reads through the same
    /// palette — film's steel for the watchable, Haul's tan for the buyable.
    var deskTint: Color {
        switch self {
        case .buy: .stashHaul
        case .watch: .categoryFilm
        case .tryIt: .categoryCoding
        case .mood: .categoryStyle
        case .reference: .stashInk.opacity(0.6)
        }
    }
}

// MARK: - Shelf cells

/// A watchable save as a small poster: art under a scrim, first topic up top, title on the
/// bottom. The art takes no touches, same rule as `stashArtCard`.
private struct PosterCard: View {
    let video: Video

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            FeaturedArt(url: video.thumbnailURL, tint: .categoryFilm)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 0) {
                if let topic = video.topics.first {
                    Micro(text: topic, size: 6.5, tracking: 1.2, color: .stashOnAccent.opacity(0.75))
                }
                Spacer(minLength: 0)
                Text(video.rowTitle)
                    .font(.archivo(10.5, .heavy))
                    .foregroundStyle(Color.stashOnAccent)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 104, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A mood save as a wall tile — bigger art, smaller words.
private struct MoodTile: View {
    let video: Video

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            FeaturedArt(url: video.thumbnailURL, tint: .categoryStyle)
                .allowsHitTesting(false)
            Text(video.rowTitle)
                .font(.archivo(11, .heavy))
                .foregroundStyle(Color.stashOnAccent)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One pick on the buy shelf: its own frame when one is extracted, the stated or checked
/// price as the badge, and the pick page behind it.
private struct BuyShelfRow: View {
    let video: Video
    let pick: BuyPick
    let pickIndex: Int

    private var price: String {
        if !pick.price.isEmpty { return pick.price }
        let country = Locale.current.region?.identifier ?? "DE"
        return OfferStore.shared.cachedTopOffer(name: pick.name, country: country)?.price ?? ""
    }

    var body: some View {
        NavigationLink { HaulDetailView(video: video, pick: pick, pickIndex: pickIndex) } label: {
            HStack(spacing: 11) {
                Thumbnail(url: PickFrameStore.shared.frame(videoID: video.videoID, pickIndex: pickIndex)
                              ?? video.thumbnailURL,
                          category: video.category, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pick.name)
                        .font(.archivo(14, .bold))
                        .foregroundStyle(Color.stashInk)
                        .lineLimit(1)
                    Text([pick.kind, video.author.isEmpty ? "" : "@\(video.author)"]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.archivo(11.5))
                        .foregroundStyle(Color.stashInk.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !price.isEmpty {
                    Micro(text: price, size: 8, tracking: 0.8, color: .stashHaul)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().strokeBorder(Color.stashHaul, lineWidth: 1.2))
                } else {
                    Image(systemName: "bag")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.stashHaul)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(pick.name)")
    }
}

// MARK: - Row

/// A desk row: 52 pt art, two-line title (the p90 title in the real library is 46 characters
/// and one line was clipping it), and a meta line that leads with the save's first topic in
/// the shelf's tint — topics are the strongest signal in the data, 3.6 per save on every save.
private struct LibraryRow: View {
    let video: Video
    var tint: Color = .stashInk
    var badge: String? = nil
    var badgeTint: Color = .stashInk

    var body: some View {
        HStack(spacing: 11) {
            Thumbnail(url: video.thumbnailURL, category: video.category, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(video.rowTitle)
                    .font(.archivo(14.5, .bold))
                    .foregroundStyle(Color.stashInk)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    if let topic = video.topics.first {
                        Micro(text: topic, size: 9, tracking: 1, color: tint)
                    }
                    Text(meta)
                        .font(.archivo(11.5))
                        .foregroundStyle(Color.stashInk.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let badge {
                Micro(text: badge, size: 7.5, tracking: 1, color: badgeTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().strokeBorder(badgeTint, lineWidth: 1.2))
            } else if let link = video.soleMusicPick?.link {
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

    private var meta: String {
        let base = video.rowMeta
        guard let topic = video.topics.first else { return base }
        // The topic already leads the line; rowMeta repeating it would read stuttered.
        return base == topic ? (video.author.isEmpty ? "" : "@\(video.author)") : "· \(base)"
    }
}

// MARK: - The "all ›" lists

/// One intent shelf, whole: the month-run list the segments used to be, under the shelf's
/// own name. Pushed, so the desk stays the tab's root.
private struct IntentListView: View {
    let title: String
    let tint: Color
    let videos: [Video]

    private var sections: [MonthRun<Video>] {
        monthRuns(videos) { $0.bookmarkedAt }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        StashBackButton()
                        Spacer()
                        Micro(text: "\(videos.count) saves", size: 10, tracking: 1.4,
                              color: .stashInk.opacity(0.5))
                    }
                    .padding(.top, 8)
                    Text(title)
                        .font(.archivo(28, .heavy))
                        .foregroundStyle(tint)
                        .padding(.top, 16)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections, id: \.id) { section in
                            Micro(text: section.title, size: 10, tracking: 2.2, color: .stashInk.opacity(0.45))
                                .padding(.top, 18)
                                .padding(.bottom, 4)
                                .id(section.id)
                            ForEach(section.items, id: \.videoID) { video in
                                NavigationLink { VideoDetailView(video: video) } label: {
                                    LibraryRow(video: video, tint: tint)
                                }
                                .buttonStyle(.plain)
                                Divider().overlay(Color.stashInk.opacity(0.12))
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(Color.stashBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .trailing) {
                let entries = timeRailEntries(for: sections)
                if entries.count >= 2 {
                    TimeRail(entries: entries, proxy: proxy)
                }
            }
        }
    }
}

/// Every pick, priced where a price is known — the buy shelf, whole.
private struct BuyListView: View {
    let picks: [(video: Video, pick: BuyPick, index: Int)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    StashBackButton()
                    Spacer()
                    Micro(text: "\(picks.count) picks", size: 10, tracking: 1.4,
                          color: .stashInk.opacity(0.5))
                }
                .padding(.top, 8)
                Text("To buy")
                    .font(.archivo(28, .heavy))
                    .foregroundStyle(Color.stashHaul)
                    .padding(.top, 16)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(picks.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Divider().overlay(Color.stashInk.opacity(0.12)) }
                        BuyShelfRow(video: item.video, pick: item.pick, pickIndex: item.index)
                    }
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Color.stashBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - Featured art

/// The featured card's ground: the save's thumbnail under a deep wash of the jewel colour —
/// enough to give the card a face, not enough to fight the type on it. No thumbnail, plain
/// jewel fill, same as before.
struct FeaturedArt: View {
    let url: URL?
    let tint: Color

    var body: some View {
        ZStack {
            tint
            if let url {
                // Overlay on a clear colour: the image never gets a say in the card's size.
                Color.clear
                    .overlay {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        }
                    }
                    .clipped()
                tint.opacity(0.78)
                LinearGradient(colors: [tint.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

extension View {
    /// `stashCard`, with the save's thumbnail dimmed into the fill.
    ///
    /// The art takes no touches: `scaledToFill` makes the image taller than the card, and
    /// `clipped()` trims what is drawn, not what is hit — build 21 shipped a Library whose
    /// header buttons and shelf pills were all "inside" the featured card's thumbnail.
    func stashArtCard(fill: Color, art: URL?) -> some View {
        padding(18)
            .background { FeaturedArt(url: art, tint: fill).allowsHitTesting(false) }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Incoming share

/// The optimistic entry for a shared TikTok: on screen from the moment the app notices the
/// share-extension inbox — before any network — and shimmering until the fast pass files the
/// save onto its real shelf. The caption follows the pipeline's actual checkpoints, so a slow
/// stage holds its line rather than pretending progress.
private struct IncomingShareCard: View {
    let shares: [PipelineCenter.PendingShare]

    private var stage: PipelineCenter.PendingShare.Stage { shares.first?.stage ?? .fetching }

    private var caption: String {
        let base: String = switch stage {
        case .fetching: "Fetching link…"
        case .saving: "Saving…"
        case .reading: "Reading the video…"
        case .failed(let message): message
        }
        return shares.count > 1 ? "\(shares.count) shares · \(base)" : base
    }

    private var isFailed: Bool { if case .failed = stage { true } else { false } }

    var body: some View {
        HStack(spacing: 11) {
            ShimmerBlock(cornerRadius: 10)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 6) {
                ShimmerBlock().frame(width: 150, height: 11)
                ShimmerBlock().frame(width: 90, height: 9)
                Micro(text: caption, size: 10, tracking: 1.6,
                      color: isFailed ? .categoryOther : .categoryMusic)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .stashOutlineCard(padding: 12)
        .animation(.easeOut(duration: 0.25), value: caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Syncing a shared TikTok — \(caption)")
    }
}

#Preview {
    LibraryView(includeBuyShelf: true)
        .modelContainer(SampleData.previewContainer)
}
