// MusicView.swift
//
// The Music tab (design: "Cook Tab Options" 6a → 7a): every music save files under its
// whole album — the album is the unit, saved tracks are just marks on it. Sleeves are the
// real covers once iTunes has been asked (typographic until then) on a scattered mosaic; a
// recommendation list keeps its typographic sleeve and wears its picks' covers as a strip
// along the top. The album page shows the full tracklist with your TikTok saves marked and
// linked back to their clips.

import SwiftUI
import SwiftData
import AVFoundation
import TikTokBrainKit

// MARK: - Album grouping

/// One wall unit: an iTunes-resolved album, or a lone unresolved track ("single").
struct MusicAlbum: Identifiable {
    struct Save: Identifiable {
        let video: Video
        let trackName: String
        let trackNumber: Int?
        var id: String { video.videoID }
    }

    let id: String
    var title: String
    var artist: String
    var year: Int?
    var trackCount: Int?          // nil = unresolved single
    var collectionID: Int?
    var albumURL: URL?
    var saves: [Save]             // newest first

    var latestSave: Date { saves.map(\.video.bookmarkedAt).max() ?? .distantPast }
    var earliestSave: Date { saves.map(\.video.bookmarkedAt).min() ?? .distantPast }

    /// Distinct tracks covered — two clips of the same song still count once.
    var savedTrackCount: Int { Set(saves.map { $0.trackName.lowercased() }).count }
    var isWhole: Bool { trackCount.map { savedTrackCount >= $0 } ?? false }

    var clipsLabel: String { "\(saves.count) clip\(saves.count == 1 ? "" : "s")" }
    var coverageLabel: String {
        if isWhole { return "Whole album" }
        if let trackCount { return "\(savedTrackCount) of \(trackCount) tracks" }
        return "Single"
    }
}

/// One video's recommendation list — five albums in one clip, kept together as the unit they
/// were presented as. Its releases deliberately do NOT also scatter into the album grid: the
/// set is what the video was about, and splitting it loses that.
struct MusicList: Identifiable {
    let video: Video
    let picks: [MusicPick]
    var id: String { video.videoID }
    var title: String { video.title }
    /// The wall cell has no artist line to show — the whole point is that there are several.
    var subtitle: String { "\(picks.count) releases" }
    var linkedCount: Int { picks.filter { $0.link != nil }.count }
}

/// One cell on the wall.
enum MusicShelfItem: Identifiable {
    case album(MusicAlbum)
    case list(MusicList)

    var id: String {
        switch self {
        case .album(let album): "album:" + album.id
        case .list(let list): "list:" + list.id
        }
    }
    var title: String {
        switch self {
        case .album(let album): album.title
        case .list(let list): list.title
        }
    }
    var artist: String {
        switch self {
        case .album(let album): album.artist
        case .list(let list): list.subtitle
        }
    }
    var latestSave: Date {
        switch self {
        case .album(let album): album.latestSave
        case .list(let list): list.video.bookmarkedAt
        }
    }
    var saveCount: Int {
        switch self {
        case .album(let album): album.saves.count
        case .list(let list): list.picks.count
        }
    }
    var isWhole: Bool {
        switch self {
        case .album(let album): album.isWhole
        case .list: false     // a list is never "the whole album"
        }
    }
    var coverageLabel: String {
        switch self {
        case .album(let album): album.coverageLabel
        case .list(let list): "\(list.linkedCount) of \(list.picks.count) linked"
        }
    }
    var clipsLabel: String {
        switch self {
        case .album(let album): album.clipsLabel
        case .list: "1 clip"
        }
    }
}

/// Splits music saves into the two wall units: a video recommending several releases becomes one
/// list; a video about a single song files under its album, grouped with every other save of it.
func shelfItems(_ videos: [Video], refs: [String: AlbumRef]) -> [MusicShelfItem] {
    let lists = videos.filter { $0.music.count > 1 }
        .map { MusicShelfItem.list(MusicList(video: $0, picks: $0.music)) }
    let singles = videos.filter { $0.music.count == 1 }
    return lists + groupAlbums(singles, refs: refs).map(MusicShelfItem.album)
}

/// Buckets single-release saves into albums using whatever the store has resolved so far.
private func groupAlbums(_ videos: [Video], refs: [String: AlbumRef]) -> [MusicAlbum] {
    var byKey: [String: MusicAlbum] = [:]
    for video in videos {
        guard let track = video.soleMusicPick else { continue }
        let key: String
        let save: MusicAlbum.Save
        if let ref = refs[video.videoID] {
            key = "album-\(ref.collectionID)"
            save = .init(video: video, trackName: ref.trackName, trackNumber: ref.trackNumber)
            if byKey[key] == nil {
                byKey[key] = MusicAlbum(
                    id: key, title: ref.albumTitle, artist: ref.artist, year: ref.year,
                    trackCount: ref.trackCount, collectionID: ref.collectionID,
                    albumURL: ref.albumURL, saves: []
                )
            }
        } else {
            key = "single-\(track.title.lowercased())|\(track.artist.lowercased())"
            save = .init(video: video, trackName: track.title, trackNumber: nil)
            if byKey[key] == nil {
                byKey[key] = MusicAlbum(
                    id: key, title: track.title, artist: track.artist, year: nil,
                    trackCount: nil, collectionID: nil, albumURL: nil, saves: []
                )
            }
        }
        byKey[key]?.saves.append(save)
    }
    return Array(byKey.values)
}

// MARK: - Album store

/// Resolves saves to albums through the Kit's `AlbumResolver`, caching results on disk
/// so the wall works offline after the first pass.
@MainActor @Observable
final class AlbumStore {
    private(set) var refs: [String: AlbumRef] = [:]       // videoID → album
    private(set) var pickRefs: [String: AlbumRef] = [:]   // videoID#index → a list pick's album
    private(set) var tracklists: [Int: [String]] = [:]    // collectionID → names in order
    private(set) var sleeves: [Int: URL] = [:]            // collectionID → sleeve on disk
    private var attempted: Set<String> = []               // session-only miss cache; retries next launch
    private let resolver = AlbumResolver()

    private struct Snapshot: Codable {
        var refs: [String: AlbumRef]
        var tracklists: [Int: [String]]
        /// Absent from caches written before covers existed; those refetch on the next pass.
        var sleeves: [Int: URL]?
        /// Absent from caches written before lists had sleeves.
        var pickRefs: [String: AlbumRef]?
    }

    /// Not private: account deletion has to be able to remove it, and it holds resolved album
    /// and tracklist data derived from the user's saves.
    static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MusicAlbumCache.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            refs = snapshot.refs
            pickRefs = snapshot.pickRefs ?? [:]
            tracklists = snapshot.tracklists
            // Signing out wipes the sleeve folder but not this file, so drop anything whose
            // bytes are gone rather than handing the wall a dead file URL.
            sleeves = (snapshot.sleeves ?? [:]).filter {
                FileManager.default.fileExists(atPath: $0.value.path)
            }
        }
    }

    // ponytail: sequential lookups — tens of saves at ~200ms each, and it spares
    // the unauthenticated iTunes API. Parallelize if libraries grow into hundreds.
    func resolve(_ videos: [Video]) async {
        var dirty = false
        for video in videos {
            if let track = video.soleMusicPick {
                if refs[video.videoID] == nil, !attempted.contains(video.videoID) {
                    attempted.insert(video.videoID)
                    if let ref = try? await resolver.album(title: track.title, artist: track.artist) {
                        refs[video.videoID] = ref
                        dirty = true
                    }
                }
                if let ref = refs[video.videoID], await fetchSleeve(for: ref) { dirty = true }
            } else {
                // A list: every pick is looked up on its own, album picks through the album
                // index, so the strip on its sleeve is the picks' real covers.
                for (index, pick) in video.music.enumerated() {
                    let key = Self.pickKey(video.videoID, index)
                    if pickRefs[key] == nil, !attempted.contains(key) {
                        attempted.insert(key)
                        if let ref = try? await resolver.album(for: pick) {
                            pickRefs[key] = ref
                            dirty = true
                        }
                    }
                    if let ref = pickRefs[key], await fetchSleeve(for: ref) { dirty = true }
                }
            }
        }
        if dirty { save() }
    }

    /// Separate from the lookup: a ref cached before covers existed, or one whose sleeve was
    /// wiped with the thumbnail folder, still needs its bytes fetching. True when it did.
    private func fetchSleeve(for ref: AlbumRef) async -> Bool {
        guard sleeves[ref.collectionID] == nil, let remote = ref.artworkURL,
              let local = try? await ThumbnailStore.download(remote, videoID: "album-\(ref.collectionID)")
        else { return false }
        sleeves[ref.collectionID] = local
        return true
    }

    private static func pickKey(_ videoID: String, _ index: Int) -> String { "\(videoID)#\(index)" }

    /// The sleeve for a wall cell, or nil when it is unresolved, art-less, or not fetched yet.
    func sleeve(for album: MusicAlbum) -> URL? {
        album.collectionID.flatMap { sleeves[$0] }
    }

    /// One sleeve per pick of a list — nil where iTunes had no confident match, or not yet.
    func sleeves(for list: MusicList) -> [URL?] {
        list.picks.indices.map { pickRefs[Self.pickKey(list.id, $0)].flatMap { sleeves[$0.collectionID] } }
    }

    /// The album one pick of a list resolved to; nil when nothing matched confidently, or not yet.
    func ref(for list: MusicList, at index: Int) -> AlbumRef? {
        pickRefs[Self.pickKey(list.id, index)]
    }

    /// Either catalogue: a negative id is a Deezer-sourced ref, and the resolver asks Deezer.
    func loadTracklist(_ collectionID: Int) async {
        guard tracklists[collectionID] == nil,
              let names = try? await resolver.tracklist(collectionID: collectionID),
              !names.isEmpty else { return }
        tracklists[collectionID] = names
        save()
    }

    private func save() {
        let snapshot = Snapshot(refs: refs, tracklists: tracklists, sleeves: sleeves, pickRefs: pickRefs)
        try? JSONEncoder().encode(snapshot).write(to: Self.cacheURL)
    }
}

// MARK: - The wall (6a)

struct MusicView: View {
    @Query(sort: \Video.bookmarkedAt, order: .reverse) private var videos: [Video]
    @State private var store = AlbumStore()
    @State private var sorting: Sorting = .recent

    enum Sorting: String, CaseIterable {
        case recent = "Recent", mostSaved = "Most saved", wholeAlbums = "Whole albums"
    }

    private var musicSaves: [Video] {
        videos.filter { $0.category == .music && !$0.music.isEmpty }
    }

    private var allItems: [MusicShelfItem] {
        shelfItems(musicSaves, refs: store.refs)
    }

    private func shelf(_ items: [MusicShelfItem]) -> [MusicShelfItem] {
        switch sorting {
        case .recent:
            items.sorted { $0.latestSave > $1.latestSave }
        case .mostSaved:
            items.sorted { ($0.saveCount, $0.latestSave) > ($1.saveCount, $1.latestSave) }
        case .wholeAlbums:
            items.filter(\.isWhole).sorted { $0.latestSave > $1.latestSave }
        }
    }

    var body: some View {
        NavigationStack {
            StashScrollView(tab: .music) {
                let items = allItems
                VStack(alignment: .leading, spacing: 0) {
                    StashHeader(title: "Music", trailing: "\(items.count) records · \(musicSaves.count) saves")
                        .padding(.top, 8)
                    chips.padding(.top, 14)
                    if musicSaves.isEmpty {
                        emptyState.padding(.top, 48)
                    } else {
                        mosaic(shelf(items)).padding(.top, 22)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, stashTabBarClearance)
            }
            .background(Color.stashBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .task(id: musicSaves.count) { await store.resolve(musicSaves) }
        .onDisappear { PreviewPlayer.shared.stop() }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Sorting.allCases, id: \.self) { option in
                    let isOn = sorting == option
                    Button { sorting = option } label: {
                        Micro(text: option.rawValue, size: 9.5, tracking: 0.8,
                              color: isOn ? .stashOnInk : .stashInk.opacity(0.65))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
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
            }
        }
    }

    /// A list cell deliberately gets no single cover: it stands for several releases at once,
    /// and picking one of their sleeves would claim the clip was about that one. It gets all of
    /// them instead, as a strip on its typographic sleeve.
    private func sleeve(for item: MusicShelfItem) -> URL? {
        switch item {
        case .album(let album): store.sleeve(for: album)
        case .list: nil
        }
    }

    private func strip(for item: MusicShelfItem) -> [URL?] {
        switch item {
        case .album: []
        case .list(let list): store.sleeves(for: list)
        }
    }

    private func mosaic(_ items: [MusicShelfItem]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 22) {
            ForEach(items) { item in
                let s = scatter(item.id)
                NavigationLink {
                    switch item {
                    case .album(let album): AlbumDetailView(album: album, store: store)
                    case .list(let list): MusicListDetailView(list: list, store: store)
                    }
                } label: {
                    SleeveTile(item: item, artwork: sleeve(for: item), strip: strip(for: item))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title), \(item.artist), \(item.clipsLabel)")
                // Outside the link, so the tap auditions rather than opens. Albums only: a list
                // is several releases, and its page has a button per pick.
                .overlay(alignment: .topTrailing) {
                    if case .album(let album) = item {
                        PreviewButton(key: item.id, pick: MusicPick(
                            kind: .track, title: album.saves.first?.trackName ?? album.title,
                            artist: album.artist))
                            .padding(4)
                    }
                }
                .rotationEffect(.degrees(s.angle))
                .offset(y: s.dy)
                // A save the fast pass just filed as music springs into the wall rather
                // than blinking in — the arrival the incoming card was promising.
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.3), value: sorting)
        .animation(.spring(duration: 0.5, bounce: 0.25), value: items.map(\.id))
    }

    private var emptyState: some View {
        StashEmptyState(
            symbol: "music.note",
            tint: .categoryMusic,
            title: "No records yet",
            message: videos.isEmpty
                ? "Songs land here as whole albums once your favorites are in."
                : "None of your saves came back as music yet — albums appear as they are analyzed.",
            offersImport: videos.isEmpty
        )
    }
}

/// One mosaic cell: the sleeve plus its coverage caption.
private struct SleeveTile: View {
    let item: MusicShelfItem
    var artwork: URL? = nil
    var strip: [URL?] = []

    var body: some View {
        VStack(spacing: 7) {
            SleeveArt(title: item.title, artist: item.artist, artwork: artwork, strip: strip)
            HStack {
                Micro(text: item.coverageLabel, size: 9.5, tracking: 1.1,
                      color: item.isWhole ? .categoryOther : .stashInk.opacity(0.55))
                Spacer()
                Micro(text: item.clipsLabel, size: 9.5, tracking: 1.1, color: .stashInk.opacity(0.45))
            }
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - Sleeve art

/// Deterministic sleeve look: a jewel fill (or the occasional cream sleeve with an
/// ink outline) picked by hashing the album, so covers are stable across launches.
private struct SleeveStyle {
    let background: Color
    let foreground: Color
    let outlined: Bool

    private static let jewels: [Color] = [
        .categoryRecipe, .categoryTravel, .categoryStyle, .categoryFitness,
        .categoryHome, .categoryMusic, .categoryOther, .stashInk,
    ]

    init(title: String, artist: String) {
        let hash = stableHash(title + artist)
        if hash % 5 == 0 {
            background = .stashSurface
            foreground = .stashInk
            outlined = true
        } else {
            background = Self.jewels[hash % Self.jewels.count]
            foreground = .stashOnAccent
            outlined = false
        }
    }
}

/// The typographic cover: short one-word titles go giant and centered; everything
/// else stacks bottom-left with the artist in caps underneath.
struct SleeveArt: View {
    let title: String
    let artist: String
    /// The real cover once iTunes has been asked and its bytes are on disk. Everything else —
    /// an unresolved single, a release with no art, the first pass before the lookup lands —
    /// keeps the typographic sleeve, which is a designed cover rather than a missing one.
    var artwork: URL? = nil
    /// A list's picks, one sleeve each, worn as a strip along the top of the typographic
    /// cover. Empty for anything that is not a list.
    var strip: [URL?] = []

    private var style: SleeveStyle { SleeveStyle(title: title, artist: artist) }
    private var isGiant: Bool { title.count <= 8 && !title.contains(" ") }

    var chipColor: Color { style.outlined ? .categoryMusic : style.background }

    var body: some View {
        if let artwork {
            // The typographic sleeve doubles as the placeholder, so a cover that is still
            // decoding shows the designed cover rather than a hole in the mosaic.
            AsyncImage(url: artwork) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                typographic
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()                       // touch region too, not just the drawing
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 8, y: 6)
        } else {
            typographic
        }
    }

    private var typographic: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(style.background)
            .overlay {
                if style.outlined {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.stashInk, lineWidth: 1.5)
                }
            }
            .overlay {
                if isGiant {
                    Text(title.uppercased())
                        .font(.archivo(42, .black))
                        .minimumScaleFactor(0.3)
                        .lineLimit(1)
                        .foregroundStyle(style.foreground)
                        .padding(14)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(title.lowercased())
                            .font(.archivo(26, .black))
                            .minimumScaleFactor(0.5)
                            .lineLimit(3)
                            .foregroundStyle(style.foreground)
                        Micro(text: artist, size: 8.5, tracking: 1.8,
                              color: style.foreground.opacity(0.75))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(16)
                    // Keep the title clear of the strip: it shrinks rather than runs under it.
                    .padding(.top, strip.isEmpty ? 0 : SleeveStrip.band)
                }
            }
            .overlay(alignment: .topLeading) {
                if !strip.isEmpty {
                    SleeveStrip(sleeves: strip, foreground: style.foreground).padding(12)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .shadow(color: .black.opacity(0.14), radius: 8, y: 6)
    }
}

/// A list's picks as a row of small sleeves along the top of its typographic cover: the first
/// four, then "+n". A pick iTunes could not match keeps a plain dark square, so the row never
/// has a hole in it.
struct SleeveStrip: View {
    let sleeves: [URL?]
    let foreground: Color
    static let size: CGFloat = 24
    /// Height the strip claims at the top of a sleeve, padding included.
    static let band: CGFloat = 12 + size + 8

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(sleeves.prefix(4).enumerated()), id: \.offset) { _, url in
                cell(url)
            }
            if sleeves.count > 4 {
                Text("+\(sleeves.count - 4)")
                    .font(.archivo(8, .heavy))
                    .foregroundStyle(foreground)
                    .frame(width: Self.size, height: Self.size)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.22)))
            }
        }
    }

    private func cell(_ url: URL?) -> some View {
        Group {
            if let url {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { blank }
            } else {
                blank
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.black.opacity(0.18), lineWidth: 1))
    }

    private var blank: some View { Color.black.opacity(0.22) }
}

/// Stable per-album collage jitter (Swift's `hashValue` reseeds every launch).
private func stableHash(_ string: String) -> Int {
    var hash = 5381
    for byte in string.utf8 { hash = (hash &* 33) &+ Int(byte) }
    return abs(hash)
}

private func scatter(_ id: String) -> (angle: Double, dy: CGFloat) {
    let hash = stableHash(id)
    return (Double(hash % 33) / 10 - 1.6, CGFloat((hash / 7) % 17) - 8)
}

// MARK: - Album detail (7a)

struct AlbumDetailView: View {
    @Environment(\.openURL) private var openURL
    @AppStorage(MusicService.key) private var serviceRaw = ""
    @State private var pending: MusicTarget?
    let album: MusicAlbum
    let store: AlbumStore
    private var service: MusicService? { MusicService(rawValue: serviceRaw) }

    private var tracklist: [String]? {
        album.collectionID.flatMap { store.tracklists[$0] }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                SleeveArt(title: album.title, artist: album.artist, artwork: store.sleeve(for: album))
                    .frame(width: 196, height: 196)
                    .rotationEffect(.degrees(-1.4))
                    .shadow(color: .black.opacity(0.2), radius: 14, y: 10)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                masthead
                savesSection
                tracklistSection
                actionBar.padding(.top, 28)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, stashTabBarClearance)
        }
        .background(Color.stashBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear { PreviewPlayer.shared.stop() }
        .task {
            if let collectionID = album.collectionID {
                await store.loadTracklist(collectionID)
            }
        }
    }

    private var topBar: some View {
        HStack {
            StashBackButton()
            Spacer()
            Micro(text: "Album", size: 10, tracking: 1.8, color: .stashOnAccent)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(SleeveArt(title: album.title, artist: album.artist).chipColor, in: Capsule())
        }
        .padding(.top, 8)
    }

    private var masthead: some View {
        VStack(spacing: 5) {
            Text(album.title)
                .font(.archivo(27, .black))
                .foregroundStyle(Color.stashInk)
                .multilineTextAlignment(.center)
            Micro(
                text: album.artist + (album.year.map { " · \($0)" } ?? ""),
                size: 10, tracking: 1.8, color: .stashInk.opacity(0.5)
            )
            Micro(text: coverageLine, size: 9.5, tracking: 1.2, color: .categoryRecipe)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
    }

    private var coverageLine: String {
        let month = album.earliestSave.formatted(.dateTime.month(.wide))
        if album.isWhole { return "Whole album saved · first save in \(month)" }
        if let trackCount = album.trackCount {
            return "\(album.savedTrackCount) of \(trackCount) tracks saved · first save in \(month)"
        }
        return "Saved in \(month)"
    }

    // MARK: From your TikToks

    private var savesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Micro(text: "From your TikToks · \(album.saves.count)", size: 10, tracking: 2, color: .categoryRecipe)
            ForEach(Array(album.saves.enumerated()), id: \.element.id) { index, save in
                Link(destination: save.video.url) {
                    HStack(spacing: 11) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(saveTint(index))
                            .frame(width: 34, height: 34)
                            .overlay {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color.stashOnAccent)
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(save.trackName)
                                .font(.archivo(13.5, .bold))
                                .foregroundStyle(Color.stashInk)
                                .lineLimit(1)
                            Text(saveByline(save))
                                .font(.archivo(11.5))
                                .foregroundStyle(Color.stashInk.opacity(0.55))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.stashInk, lineWidth: 1.5)
                    )
                }
                .accessibilityLabel("Open the clip for \(save.trackName)")
            }
        }
        .padding(.top, 22)
    }

    private func saveTint(_ index: Int) -> Color {
        let tints: [Color] = [.categoryTravel, .categoryStyle, .categoryFitness, .categoryHome, .categoryLearning]
        return tints[index % tints.count]
    }

    private func saveByline(_ save: MusicAlbum.Save) -> String {
        let month = save.video.bookmarkedAt.formatted(.dateTime.month(.wide))
        let saved = "saved in \(month)"
        return save.video.author.isEmpty ? saved : "@\(save.video.author) · \(saved)"
    }

    // MARK: Tracklist

    @ViewBuilder
    private var tracklistSection: some View {
        if let collectionID = album.collectionID {
            VStack(alignment: .leading, spacing: 4) {
                Micro(text: "Tracklist" + (album.trackCount.map { " · \($0)" } ?? ""),
                      size: 10, tracking: 2, color: .stashInk.opacity(0.45))
                if let tracklist {
                    VStack(spacing: 0) {
                        ForEach(Array(tracklist.enumerated()), id: \.offset) { index, name in
                            trackRow(number: index + 1, name: name,
                                     isLast: index == tracklist.count - 1)
                        }
                    }
                } else {
                    Text("Fetching the tracklist…")
                        .font(.archivo(12.5))
                        .foregroundStyle(Color.stashInk.opacity(0.45))
                        .padding(.vertical, 10)
                        .task { await store.loadTracklist(collectionID) }
                }
            }
            .padding(.top, 22)
        }
    }

    /// The clip behind a tracklist row, matched by track number first, then name.
    private func savedClip(number: Int, name: String) -> MusicAlbum.Save? {
        album.saves.first { $0.trackNumber == number }
            ?? album.saves.first { $0.trackName.lowercased() == name.lowercased() }
    }

    private func trackRow(number: Int, name: String, isLast: Bool) -> some View {
        let save = savedClip(number: number, name: name)
        return HStack(spacing: 12) {
            // Every track, saved or not, at full strength: the unsaved ones are exactly the ones
            // worth auditioning before going to look for them.
            PreviewButton(key: "\(album.id)#\(number)",
                          pick: MusicPick(kind: .track, title: name, artist: album.artist), size: 24)
            HStack(spacing: 12) {
                Text("\(number)")
                    .font(.archivo(12, .black))
                    .foregroundStyle(save != nil ? Color.categoryRecipe : Color.stashInk)
                    .frame(width: 20, alignment: .leading)
                Text(name)
                    .font(.archivo(13.5, save != nil ? .bold : .semibold))
                    .foregroundStyle(Color.stashInk)
                    .lineLimit(1)
            }
            .opacity(save != nil ? 1 : 0.45)
            Spacer(minLength: 0)
            if let save {
                Link(destination: save.video.url) {
                    Micro(text: "▶\u{FE0E} Clip", size: 8.5, tracking: 1, color: .categoryRecipe)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().strokeBorder(Color.categoryRecipe, lineWidth: 1.2))
                }
                .accessibilityLabel("Open the clip for \(name)")
            }
        }
        .padding(.vertical, 2)
        .overlay(alignment: .bottom) {
            if !isLast { Divider().overlay(Color.stashInk.opacity(0.12)) }
        }
    }

    // MARK: Actions

    private var actionBar: some View {
        HStack(spacing: 10) {
            StashPrimaryButton(title: service.map { "Play on \($0.label)" } ?? "Play") {
                let target = MusicTarget(title: album.title, artist: album.artist,
                                         link: album.albumURL.map(universalLink))
                if let service {
                    openURL(service.url(title: target.title, artist: target.artist, link: target.link))
                } else {
                    pending = target
                }
            }
            if let albumURL = album.albumURL {
                Link(destination: universalLink(for: albumURL)) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.stashInk)
                        .frame(width: 52, height: 52)
                        .background(Circle().strokeBorder(Color.stashInk, lineWidth: 1.5))
                }
                .accessibilityLabel("Open on every streaming service")
            }
        }
        .musicServiceChooser($pending)
    }

    /// song.link universal wrapper, same encoding contract as the Kit's track links.
    private func universalLink(for albumURL: URL) -> URL {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        let encoded = albumURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return URL(string: "https://song.link/\(encoded)") ?? albumURL
    }
}

// MARK: - Recommendation list detail

/// One video's set of releases. Deliberately plainer than the album page: there is no single
/// cover, no tracklist and no year to show, and every row here came off the video's own frames
/// rather than out of a catalogue.
///
/// A row with no link is not a failure to render — it is the honest outcome when nothing in the
/// catalogue plausibly matched the name. The alternative, shipped until now, was a confident
/// album page built on a guess.
struct MusicListDetailView: View {
    @Environment(\.openURL) private var openURL
    @AppStorage(MusicService.key) private var serviceRaw = ""
    @State private var pending: MusicTarget?
    let list: MusicList
    let store: AlbumStore
    private var service: MusicService? { MusicService(rawValue: serviceRaw) }
    /// Indexes of the album picks opened into their tracklists.
    @State private var expanded: Set<Int> = []

    private var sleeves: [URL?] { store.sleeves(for: list) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                SleeveArt(title: list.title, artist: list.subtitle, strip: sleeves)
                    .frame(width: 196, height: 196)
                    .rotationEffect(.degrees(-1.4))
                    .shadow(color: .black.opacity(0.2), radius: 14, y: 10)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                masthead
                picksSection
                clipLink.padding(.top, 26)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, stashTabBarClearance)
        }
        .background(Color.stashBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .musicServiceChooser($pending)
        .onDisappear { PreviewPlayer.shared.stop() }
    }

    private var topBar: some View {
        HStack {
            StashBackButton()
            Spacer()
            Micro(text: "Selection", size: 10, tracking: 1.8, color: .stashOnAccent)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(SleeveArt(title: list.title, artist: list.subtitle).chipColor, in: Capsule())
        }
        .padding(.top, 8)
    }

    private var masthead: some View {
        VStack(spacing: 5) {
            Text(list.title)
                .font(.archivo(27, .black))
                .foregroundStyle(Color.stashInk)
                .multilineTextAlignment(.center)
            Micro(text: bylines, size: 10, tracking: 1.8, color: .stashInk.opacity(0.5))
            Micro(text: "\(list.picks.count) releases · saved in "
                  + list.video.bookmarkedAt.formatted(.dateTime.month(.wide)),
                  size: 9.5, tracking: 1.2, color: .categoryRecipe)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
    }

    private var bylines: String {
        list.video.author.isEmpty ? "From your TikToks" : "@" + list.video.author
    }

    private var picksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Micro(text: "In this video · \(list.picks.count)", size: 10, tracking: 2, color: .categoryRecipe)
            let sleeves = sleeves
            ForEach(Array(list.picks.enumerated()), id: \.offset) { index, pick in
                row(index: index, pick: pick, sleeve: sleeves[index])
            }
        }
        .padding(.top, 22)
    }

    private func row(index: Int, pick: MusicPick, sleeve: URL?) -> some View {
        // Opens only when it resolved as an album. An empty trackName is how a ref says so, and
        // it holds even when the model labelled the pick "track" — which it does for albums.
        let album = store.ref(for: list, at: index).flatMap { $0.trackName.isEmpty ? $0 : nil }
        let isOpen = expanded.contains(index)
        return VStack(spacing: 0) {
            HStack(spacing: 11) {
                Text("\(index + 1)")
                    .font(.archivo(12, .black))
                    .foregroundStyle(pick.link != nil ? Color.categoryRecipe : Color.stashInk.opacity(0.45))
                    .frame(width: 18, alignment: .leading)
                // The sleeve is the preview button: hear it before deciding to go looking for it.
                pickArt(sleeve)
                    .overlay { PreviewButton(key: "\(list.id)#\(index)", pick: pick, size: 26) }
                // A pick with no confident catalogue match still gets you somewhere: a search on
                // the name the video showed. Better than a dead row, and honest about being a search.
                Button {
                    let target = MusicTarget(title: pick.title, artist: pick.artist, link: pick.link)
                    if let service {
                        openURL(service.url(title: target.title, artist: target.artist, link: target.link))
                    } else {
                        pending = target
                    }
                } label: {
                    HStack(spacing: 11) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pick.title)
                                .font(.archivo(13.5, .bold))
                                .foregroundStyle(Color.stashInk)
                                .lineLimit(2)
                            Micro(text: subtitle(for: pick), size: 9, tracking: 1.2,
                                  color: .stashInk.opacity(0.5))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: pick.link != nil ? "arrow.up.right" : "magnifyingglass")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.stashInk.opacity(pick.link != nil ? 1 : 0.4))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pick.link != nil
                                    ? "Open \(pick.title)"
                                    : "Search for \(pick.title)")
                if album != nil {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            if isOpen { expanded.remove(index) } else { expanded.insert(index) }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.stashInk)
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel((isOpen ? "Hide" : "Show") + " the tracks of \(pick.title)")
                }
            }
            if isOpen, let album {
                tracks(of: album, pickIndex: index)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.stashInk.opacity(pick.link != nil ? 1 : 0.3), lineWidth: 1.5)
        )
    }

    /// An opened album pick's tracklist, a preview on every track, its ▶ column under the sleeve's.
    /// The artist is the catalogue's, so each lookup asks for exactly the record the row shows.
    private func tracks(of album: AlbumRef, pickIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let names = store.tracklists[album.collectionID] {
                ForEach(Array(names.enumerated()), id: \.offset) { number, name in
                    HStack(spacing: 10) {
                        PreviewButton(key: "\(list.id)#\(pickIndex)#\(number)",
                                      pick: MusicPick(kind: .track, title: name, artist: album.artist),
                                      size: 22)
                        Text("\(number + 1)")
                            .font(.archivo(11, .black))
                            .foregroundStyle(Color.stashInk.opacity(0.45))
                            .frame(width: 18, alignment: .leading)
                        Text(name)
                            .font(.archivo(13, .semibold))
                            .foregroundStyle(Color.stashInk)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Text("Fetching the tracklist…")
                    .font(.archivo(12.5))
                    .foregroundStyle(Color.stashInk.opacity(0.45))
                    .padding(.vertical, 8)
            }
        }
        .padding(.leading, 31)
        .padding(.top, 8)
        .task { await store.loadTracklist(album.collectionID) }
    }

    /// The strip's sleeve at row size — or a quiet square where iTunes had no match.
    private func pickArt(_ url: URL?) -> some View {
        Group {
            if let url {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.stashInk.opacity(0.12) }
            } else {
                Color.stashInk.opacity(0.12)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func subtitle(for pick: MusicPick) -> String {
        let kind = pick.kind == .album ? "Album" : "Track"
        let who = pick.artist.isEmpty ? "" : " · " + pick.artist
        return pick.link == nil ? kind + who + " · search" : kind + who
    }

    private var clipLink: some View {
        Link(destination: list.video.url) {
            HStack(spacing: 9) {
                Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                Micro(text: "Open the clip", size: 10, tracking: 1.4, color: .stashInk)
            }
            .foregroundStyle(Color.stashInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Capsule().strokeBorder(Color.stashInk, lineWidth: 1.5))
        }
    }
}

// MARK: - Audition

/// One ~30 second catalogue preview at a time, app-wide: starting another stops the first.
/// ponytail: a lookup per tap (~300 ms), nothing cached or preloaded. Cache iTunes URLs in
/// `AlbumStore` if that wait ever shows — never Deezer's, which are signed and expire.
@MainActor @Observable
final class PreviewPlayer {
    static let shared = PreviewPlayer()

    /// The key of the preview loading or playing; nil when silent.
    private(set) var current: String?
    private(set) var isLoading = false
    /// Keys neither catalogue had a preview for, so their button stops offering one.
    private(set) var missing: Set<String> = []

    private let player = AVPlayer()
    private let resolver = AlbumResolver()
    private var generation = 0

    private init() {
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
                self.stop()
            }
        }
    }

    func toggle(_ key: String, pick: MusicPick) {
        guard current != key else { return stop() }
        stop()
        current = key
        isLoading = true
        let generation = generation
        Task {
            var found: URL?
            var answered = true
            do { found = try await resolver.previewURL(for: pick) } catch { answered = false }
            guard generation == self.generation else { return }   // a later tap owns the player
            isLoading = false
            guard let found else {
                // Only a real "no preview" retires the button; a dropped connection can retry.
                if answered { missing.insert(key) }
                current = nil
                return
            }
            // Playback, so a button someone pressed is heard with the ring switch on silent.
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player.replaceCurrentItem(with: AVPlayerItem(url: found))
            player.play()
        }
    }

    func stop() {
        generation += 1
        let wasPlaying = player.currentItem != nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        isLoading = false
        // Hand the audio back to whatever the preview interrupted.
        if wasPlaying {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Play/stop for one pick's preview: a spinner while the catalogues are asked, a crossed-out
/// speaker once neither had anything to play.
struct PreviewButton: View {
    let key: String
    let pick: MusicPick
    var size: CGFloat = 34

    var body: some View {
        let player = PreviewPlayer.shared
        let isCurrent = player.current == key
        let isMissing = player.missing.contains(key)
        Button { player.toggle(key, pick: pick) } label: {
            Group {
                if isCurrent && player.isLoading {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: isMissing ? "speaker.slash.fill" : isCurrent ? "stop.fill" : "play.fill")
                        .font(.system(size: size * 0.36, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .background(Circle().fill(Color.black.opacity(isMissing ? 0.3 : 0.6)))
            .padding(5)                     // the wall's 34 pt disc gets a 44 pt target
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isMissing)
        .accessibilityLabel(isMissing ? "No preview for \(pick.title)"
                            : isCurrent ? "Stop preview" : "Preview \(pick.title)")
    }
}

#Preview("Music wall") {
    MusicView()
        .modelContainer(SampleData.previewContainer)
}

#Preview("Album detail") {
    let saves: [MusicAlbum.Save] = SampleData.makeSampleVideos()
        .filter { $0.category == .music }
        .map { .init(video: $0, trackName: $0.music.first?.title ?? "", trackNumber: nil) }
    return AlbumDetailView(
        album: MusicAlbum(
            id: "album-1", title: "Currents", artist: "Tame Impala", year: 2015,
            trackCount: 13, collectionID: 1_440_838_039,
            albumURL: URL(string: "https://music.apple.com/us/album/currents/1440838039"),
            saves: saves
        ),
        store: AlbumStore()
    )
}

// MARK: - Streaming service choice

/// A release about to be opened — held while the first-tap chooser asks where to send it.
struct MusicTarget: Equatable {
    let title: String
    let artist: String
    let link: URL?
}

extension View {
    /// The one-time "where do you listen?" sheet. Views set `pending` when no service is chosen
    /// yet; the chosen service is stored and the pending release opened there.
    func musicServiceChooser(_ pending: Binding<MusicTarget?>) -> some View {
        modifier(MusicServiceChooser(pending: pending))
    }
}

private struct MusicServiceChooser: ViewModifier {
    @Binding var pending: MusicTarget?
    @AppStorage(MusicService.key) private var serviceRaw = ""
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Where do you listen?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            ForEach(MusicService.allCases) { service in
                Button(service.label) {
                    serviceRaw = service.rawValue
                    if let t = pending { openURL(service.url(title: t.title, artist: t.artist, link: t.link)) }
                    pending = nil
                }
            }
        } message: {
            Text("Every release opens there from now on. Change it any time in Settings.")
        }
    }
}
