// MusicView.swift
//
// The Music tab (design: "Cook Tab Options" 6a → 7a): every music save files under its
// whole album — the album is the unit, saved tracks are just marks on it. Sleeves are
// typographic placeholders on a scattered mosaic; the album page shows the full
// tracklist with your TikTok saves marked and linked back to their clips.

import SwiftUI
import SwiftData
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

/// Buckets music saves into albums using whatever the store has resolved so far.
private func groupAlbums(_ videos: [Video], refs: [String: AlbumRef]) -> [MusicAlbum] {
    var byKey: [String: MusicAlbum] = [:]
    for video in videos {
        guard let track = video.track else { continue }
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
    private(set) var tracklists: [Int: [String]] = [:]    // collectionID → names in order
    private var attempted: Set<String> = []               // session-only miss cache; retries next launch
    private let resolver = AlbumResolver()

    private struct Snapshot: Codable {
        var refs: [String: AlbumRef]
        var tracklists: [Int: [String]]
    }

    private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MusicAlbumCache.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            refs = snapshot.refs
            tracklists = snapshot.tracklists
        }
    }

    // ponytail: sequential lookups — tens of saves at ~200ms each, and it spares
    // the unauthenticated iTunes API. Parallelize if libraries grow into hundreds.
    func resolve(_ videos: [Video]) async {
        var dirty = false
        for video in videos {
            guard refs[video.videoID] == nil, !attempted.contains(video.videoID),
                  let track = video.track else { continue }
            attempted.insert(video.videoID)
            guard let ref = try? await resolver.album(title: track.title, artist: track.artist) else { continue }
            refs[video.videoID] = ref
            dirty = true
        }
        if dirty { save() }
    }

    func loadTracklist(_ collectionID: Int) async {
        guard tracklists[collectionID] == nil,
              let names = try? await resolver.tracklist(collectionID: collectionID),
              !names.isEmpty else { return }
        tracklists[collectionID] = names
        save()
    }

    private func save() {
        let snapshot = Snapshot(refs: refs, tracklists: tracklists)
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
        videos.filter { $0.category == .music && $0.track != nil }
    }

    private var allAlbums: [MusicAlbum] {
        groupAlbums(musicSaves, refs: store.refs)
    }

    private func shelf(_ albums: [MusicAlbum]) -> [MusicAlbum] {
        switch sorting {
        case .recent:
            albums.sorted { $0.latestSave > $1.latestSave }
        case .mostSaved:
            albums.sorted { ($0.saves.count, $0.latestSave) > ($1.saves.count, $1.latestSave) }
        case .wholeAlbums:
            albums.filter(\.isWhole).sorted { $0.latestSave > $1.latestSave }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                let albums = allAlbums
                VStack(alignment: .leading, spacing: 0) {
                    StashHeader(title: "Music", trailing: "\(albums.count) albums · \(musicSaves.count) saves")
                        .padding(.top, 8)
                    chips.padding(.top, 14)
                    if musicSaves.isEmpty {
                        emptyState.padding(.top, 48)
                    } else {
                        mosaic(shelf(albums)).padding(.top, 22)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, stashTabBarClearance)
            }
            .background(Color.stashBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .task(id: musicSaves.count) { await store.resolve(musicSaves) }
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

    private func mosaic(_ albums: [MusicAlbum]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 22) {
            ForEach(albums) { album in
                let s = scatter(album.id)
                NavigationLink { AlbumDetailView(album: album, store: store) } label: {
                    SleeveTile(album: album)
                }
                .buttonStyle(.plain)
                .rotationEffect(.degrees(s.angle))
                .offset(y: s.dy)
                .accessibilityLabel("\(album.title) by \(album.artist), \(album.clipsLabel)")
            }
        }
        .animation(.easeOut(duration: 0.3), value: sorting)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.categoryMusic)
            Text("No records yet")
                .font(.archivo(17, .bold))
                .foregroundStyle(Color.stashInk)
            Text("Songs you save land here as albums.")
                .font(.archivo(13))
                .foregroundStyle(Color.stashInk.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }
}

/// One mosaic cell: the sleeve plus its coverage caption.
private struct SleeveTile: View {
    let album: MusicAlbum

    var body: some View {
        VStack(spacing: 7) {
            SleeveArt(album: album)
            HStack {
                Micro(text: album.coverageLabel, size: 9.5, tracking: 1.1,
                      color: album.isWhole ? .categoryOther : .stashInk.opacity(0.55))
                Spacer()
                Micro(text: album.clipsLabel, size: 9.5, tracking: 1.1, color: .stashInk.opacity(0.45))
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

    init(for album: MusicAlbum) {
        let hash = stableHash(album.title + album.artist)
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
    let album: MusicAlbum

    private var style: SleeveStyle { SleeveStyle(for: album) }
    private var isGiant: Bool { album.title.count <= 8 && !album.title.contains(" ") }

    var chipColor: Color { style.outlined ? .categoryMusic : style.background }

    var body: some View {
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
                    Text(album.title.uppercased())
                        .font(.archivo(42, .black))
                        .minimumScaleFactor(0.3)
                        .lineLimit(1)
                        .foregroundStyle(style.foreground)
                        .padding(14)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(album.title.lowercased())
                            .font(.archivo(26, .black))
                            .minimumScaleFactor(0.5)
                            .lineLimit(3)
                            .foregroundStyle(style.foreground)
                        Micro(text: album.artist, size: 8.5, tracking: 1.8,
                              color: style.foreground.opacity(0.75))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(16)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .shadow(color: .black.opacity(0.14), radius: 8, y: 6)
    }
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let album: MusicAlbum
    let store: AlbumStore

    private var tracklist: [String]? {
        album.collectionID.flatMap { store.tracklists[$0] }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                SleeveArt(album: album)
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
        .task {
            if let collectionID = album.collectionID {
                await store.loadTracklist(collectionID)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.stashInk)
                    .frame(width: 36, height: 36)
                    .background(Circle().strokeBorder(Color.stashInk, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            Spacer()
            Micro(text: "Album", size: 10, tracking: 1.8, color: .stashOnAccent)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(SleeveArt(album: album).chipColor, in: Capsule())
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
            Text("\(number)")
                .font(.archivo(12, .black))
                .foregroundStyle(save != nil ? Color.categoryRecipe : Color.stashInk)
                .frame(width: 20, alignment: .leading)
            Text(name)
                .font(.archivo(13.5, save != nil ? .bold : .semibold))
                .foregroundStyle(Color.stashInk)
                .lineLimit(1)
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
        .padding(.vertical, 9)
        .opacity(save != nil ? 1 : 0.45)
        .overlay(alignment: .bottom) {
            if !isLast { Divider().overlay(Color.stashInk.opacity(0.12)) }
        }
    }

    // MARK: Actions

    private var actionBar: some View {
        HStack(spacing: 10) {
            StashPrimaryButton(title: "Play on Spotify") { openURL(spotifySearchURL) }
            if let albumURL = album.albumURL {
                Link(destination: universalLink(for: albumURL)) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.stashInk)
                        .frame(width: 52, height: 52)
                        .background(Circle().strokeBorder(Color.stashInk, lineWidth: 1.5))
                }
                .accessibilityLabel("Open on your streaming service")
            }
        }
    }

    /// Spotify album search as a universal link — Spotify's AASA claims `/search/*`, so on a
    /// device with the app this opens Spotify straight to the album search.
    /// ponytail: search, not a direct album id — song.link's album→Spotify mapping missed
    /// every real album tested; search always lands. Upgrade path: Spotify Web API for /album/<id>.
    private var spotifySearchURL: URL {
        // Encode the whole query as one path component — album titles contain "/" (e.g.
        // "russian shoegaze/dream-pop albums vol. 1"), which must not become a path separator.
        let query = "\(album.title) \(album.artist)"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        return URL(string: "https://open.spotify.com/search/\(encoded)")
            ?? URL(string: "https://open.spotify.com")!
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

#Preview("Music wall") {
    MusicView()
        .modelContainer(SampleData.previewContainer)
}

#Preview("Album detail") {
    let saves: [MusicAlbum.Save] = SampleData.makeSampleVideos()
        .filter { $0.category == .music }
        .map { .init(video: $0, trackName: $0.track?.title ?? "", trackNumber: nil) }
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
