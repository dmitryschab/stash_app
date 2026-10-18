// FilmsView.swift
//
// The Films tab: every movie your saves named, as a poster wall. Music's idea, one medium
// over — the film is the unit and a save is a mark on it, so one clip that lists ten movies
// puts ten posters on the wall and the same movie named by two clips is still one poster.
//
// A save that named two or more films is a "list" (the "10 best sci-fi movies" TikTok). A
// film that came out of one wears a deck edge behind its poster; the list itself gets a card
// (the Films / Lists switch, and the newest one above the wall). A long press marks a film
// seen: a tick lands on the poster and it sinks below the unseen ones in its month. Posters and the Wikipedia
// link come from `FilmResolver`, resolved lazily per film, and an unresolved title renders
// as a typographic sleeve and is *not* a link — the same honesty rule as FilmSection.

import SwiftUI
import SwiftData
import TikTokBrainKit

// MARK: - Grouping

/// The wall's grouping, over plain values rather than SwiftData rows, so the four rules it
/// encodes (identity merge, list vs single, placement, newest first) are checkable without a
/// store — see `selfTest`.
enum FilmWall {
    /// What one save contributes: the films it named, in the order it named them.
    struct Source {
        let id: String
        let savedAt: Date
        let picks: [FilmPick]
    }

    /// One save's mark on one film.
    struct Mark: Identifiable {
        let sourceID: String
        let savedAt: Date
        let position: Int       // 1-based, in the order that save named its films
        let outOf: Int          // how many films that save named
        var id: String { sourceID }
        /// Two or more films in one clip is a list, not a recommendation of one movie.
        var isList: Bool { outOf >= 2 }
    }

    /// One film, with every save that named it, newest first.
    struct Film: Identifiable {
        let id: String
        /// The newest save's spelling — sources arrive newest first, so that is the first seen.
        let title: String
        let year: Int?
        var marks: [Mark]

        var savedAt: Date { marks.first?.savedAt ?? .distantPast }
        /// The most recent list save that named it, if any.
        var listMark: Mark? { marks.first(where: \.isList) }
        var isFromList: Bool { listMark != nil }
        /// Where the most recent list save placed it, e.g. "4 of 10".
        var placement: String? { listMark.map { "\($0.position) of \($0.outOf)" } }

        var accessibilityLabel: String {
            var parts = [title]
            if let year { parts.append(String(year)) }
            if let listMark { parts.append("from a list of \(listMark.outOf)") }
            return parts.joined(separator: ", ")
        }
    }

    /// ponytail: `FilmPick.Identity` is the Kit's own merge key but it is private, so the same
    /// fold is repeated here rather than widening the Kit's API for one caller. Same rule, so
    /// the same film named with and without its year stays two films, as it does inside a save.
    static func identity(_ pick: FilmPick) -> String {
        let title = pick.title.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                       locale: Locale(identifier: "en_US_POSIX"))
        return title + "|" + (pick.year.map(String.init) ?? "")
    }

    /// One entry per pick, merged by identity. Ties break on id so the order is deterministic
    /// (Swift's sort is not stable) — a wall that reshuffles on every redraw is not a wall.
    static func films(from sources: [Source]) -> [Film] {
        var byIdentity: [String: Film] = [:]
        var order: [String] = []
        for source in sources {
            for (index, pick) in source.picks.enumerated() {
                let key = identity(pick)
                let mark = Mark(sourceID: source.id, savedAt: source.savedAt,
                                position: index + 1, outOf: source.picks.count)
                if byIdentity[key] == nil {
                    byIdentity[key] = Film(id: key, title: pick.title, year: pick.year, marks: [mark])
                    order.append(key)
                } else {
                    byIdentity[key]?.marks.append(mark)
                }
            }
        }
        return order
            .compactMap { byIdentity[$0] }
            .map { film in
                var film = film
                film.marks.sort { ($0.savedAt, $1.sourceID) > ($1.savedAt, $0.sourceID) }
                return film
            }
            .sorted { a, b in
                if a.savedAt != b.savedAt { return a.savedAt > b.savedAt }
                // Same save, so a list: keep the order the clip showed them in, as FilmSection does.
                let (pa, pb) = (a.marks.first?.position ?? 0, b.marks.first?.position ?? 0)
                return pa != pb ? pa < pb : a.id < b.id
            }
    }

    // MARK: Seen

    /// The seen flag is one set of identity keys for the whole wall, kept the way `codeChecks`
    /// is: a JSON-encoded sorted array, nil once empty. It lives in defaults rather than on a
    /// save because it is the user's mark, not analysis — a pipeline re-run must not clear it.
    static let seenKey = "filmSeen"

    static func seenKeys(_ data: Data?) -> Set<String> {
        guard let data, let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(keys)
    }

    static func seenData(_ keys: Set<String>) -> Data? {
        keys.isEmpty ? nil : try? JSONEncoder().encode(keys.sorted())
    }

    /// Seen films sink below the unseen ones; each half keeps the wall's own order. Applied
    /// per month run, so a film never leaves its month for having been watched.
    static func ordered(_ films: [Film], seen: Set<String>) -> [Film] {
        films.filter { !seen.contains($0.id) } + films.filter { seen.contains($0.id) }
    }

    #if DEBUG
    /// Runs on every debug launch, next to the other shell asserts.
    static func selfTest() -> Bool {
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        let t3 = Date(timeIntervalSince1970: 3_000)
        let single = Source(id: "single", savedAt: t3, picks: [FilmPick(title: "Dune", year: 2021)])
        let clip = Source(id: "clip", savedAt: t2, picks: [FilmPick(title: "Aftersun", year: 2022)])
        let list = Source(id: "list", savedAt: t1, picks: [
            FilmPick(title: "Arrival", year: 2016),
            FilmPick(title: "aftersun", year: 2022),      // same film, other spelling
            FilmPick(title: "Past Lives", year: 2023),
            FilmPick(title: "Amélie", year: 2001),        // alphabetically first, shown last
        ])
        let wall = films(from: [single, clip, list])
        return wall.count == 5                                          // six picks, five films
            && wall.map(\.title) == ["Dune", "Aftersun", "Arrival", "Past Lives", "Amélie"]   // newest first, then the list's own order
            && wall[1].marks.count == 2                                 // merged across two saves
            && wall[1].placement == "2 of 4"                            // the list mark, not the single
            && wall[2].placement == "1 of 4"
            && !wall[0].isFromList && wall[0].placement == nil          // a single-film save is no list
            && ordered(wall, seen: ["dune|2021", "arrival|2016"]).map(\.title)
                == ["Aftersun", "Past Lives", "Amélie", "Dune", "Arrival"]           // seen sink, both halves keep their order
            && seenKeys(seenData(["b", "a"])) == ["a", "b"] && seenData([]) == nil   // the codeChecks round trip
            && wall[0].accessibilityLabel == "Dune, 2021"
            && wall[2].accessibilityLabel == "Arrival, 2016, from a list of 4"
    }
    #endif
}

// MARK: - The wall

struct FilmsView: View {
    @Query(sort: \Video.bookmarkedAt, order: .reverse) private var videos: [Video]
    @State private var focus: Filter = .all
    @State private var mode: Mode = .films
    @State private var browsingTopics = false
    @AppStorage(FilmWall.seenKey) private var seenJSON: Data?
    /// Poster lookups, keyed by `FilmWall.Film.id`, so scrolling back does not re-resolve.
    /// An absent key is "still asking Wikipedia"; a `nil` value is a recorded miss. The tile
    /// draws those differently — a poster that will never arrive should not shimmer (F34).
    @State private var refs: [String: FilmRef?] = [:]

    private enum Filter: Equatable { case all, topic(String) }
    /// The switch under the header: the wall of films, or one card per list save.
    private enum Mode { case films, lists }

    /// Read once per body pass (see `body`): each access decodes every video's film payload.
    private var saves: [Video] {
        videos.filter { $0.category == .film && !$0.films.isEmpty }
    }

    private func shown(in films: [FilmWall.Film], saves: [Video]) -> [FilmWall.Film] {
        switch focus {
        case .all:
            return films
        case .topic(let name):
            let ids = Set(saves.filter { $0.topics.contains(name) }.map(\.videoID))
            return films.filter { film in film.marks.contains { ids.contains($0.sourceID) } }
        }
    }

    /// The list saves — those that named two or more films — newest first, under the same chip.
    private func lists(in saves: [Video]) -> [Video] {
        saves.filter { save in
            guard save.films.count >= 2 else { return false }
            if case .topic(let name) = focus { return save.topics.contains(name) }
            return true
        }
    }

    /// Every topic across the film saves with how many carry it, most-used first.
    private func topics(in saves: [Video]) -> [TopicCount] {
        var counts: [String: Int] = [:]
        for video in saves {
            for topic in video.topics { counts[topic, default: 0] += 1 }
        }
        return counts
            .map { TopicCount(name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    /// The head of the row, plus whatever the picker put in focus down the tail — same rule as
    /// Cook: a selected chip you cannot see reads as no selection.
    private func rowTopics(_ topics: [TopicCount]) -> [TopicCount] {
        let head = Array(topics.filter { $0.count >= TopicPicker.browseFloor }.prefix(5))
        guard case .topic(let name) = focus, !head.contains(where: { $0.name == name }) else { return head }
        let selected = topics.first { $0.name == name } ?? TopicCount(name: name, count: 0)
        return [selected] + head.dropLast()
    }

    /// The picker speaks in topic names; the row has one more state than that.
    private var topicFocus: Binding<String?> {
        Binding(
            get: { if case .topic(let name) = focus { return name }; return nil },
            set: { focus = $0.map(Filter.topic) ?? .all }
        )
    }

    var body: some View {
        // The fold once per body pass: `refs` is @State, so every resolved poster re-renders
        // this, and the header, chips and wall all read the same films.
        let saves = self.saves
        let films = FilmWall.films(from: saves.map {
            FilmWall.Source(id: $0.videoID, savedAt: $0.bookmarkedAt, picks: $0.films)
        })
        let shown = shown(in: films, saves: saves)
        let seen = FilmWall.seenKeys(seenJSON)
        let runs = monthRuns(shown) { $0.savedAt }.map { run in
            var run = run
            run.items = FilmWall.ordered(run.items, seen: seen)
            return run
        }
        let lists = lists(in: saves)
        let savesByID = Dictionary(saves.map { ($0.videoID, $0) }, uniquingKeysWith: { first, _ in first })
        let filmsByID = Dictionary(films.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        NavigationStack {
            ScrollViewReader { proxy in
                StashScrollView(tab: .films) {
                    VStack(alignment: .leading, spacing: 0) {
                        StashHeader(title: "Films", trailing: trailing(films: films, shown: shown, lists: lists, seen: seen))
                            .padding(.top, 8)
                        if !saves.isEmpty {
                            // A switch that can only show an empty page is not a switch.
                            if films.contains(where: \.isFromList) {
                                segment.padding(.top, 10)
                            }
                            chips(saves: saves).padding(.top, 4)
                        }
                        if films.isEmpty {
                            emptyState.padding(.top, 48)
                        } else if mode == .lists {
                            listCards(lists, filmsByID: filmsByID, seen: seen).padding(.top, 10)
                        } else {
                            if focus == .all, let newest = lists.first {
                                listCard(newest, filmsByID: filmsByID, seen: seen,
                                         label: "Newest list · \(newest.bookmarkedAt.formatted(.relative(presentation: .named)))")
                                    .padding(.top, 10)
                            }
                            wall(runs: runs, savesByID: savesByID, seen: seen).padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, stashTabBarClearance)
                }
                .background(Color.stashBackground.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .overlay(alignment: .trailing) {
                    let entries = timeRailEntries(for: runs)
                    if mode == .films, entries.count >= 2 {
                        TimeRail(entries: entries, proxy: proxy)
                    }
                }
            }
        }
    }

    /// Cook's rule for the header: totals until a chip is on, then how much of the wall it left.
    /// The films total counts what is left to see, so the seen flag has a number to move.
    private func trailing(films: [FilmWall.Film], shown: [FilmWall.Film], lists: [Video], seen: Set<String>) -> String {
        if mode == .lists { return "\(lists.count) \(lists.count == 1 ? "list" : "lists")" }
        guard focus == .all else { return "\(shown.count) of \(films.count)" }
        let toSee = films.filter { !seen.contains($0.id) }.count
        let total = "\(films.count) \(films.count == 1 ? "film" : "films")"
        return toSee == 0 && !films.isEmpty ? "\(total) · all seen" : "\(total) · \(toSee) to see"
    }

    /// Films / Lists. Drawn like the chips — ink capsule on, outline off — but it is one
    /// control with two states rather than two filters, so it sits on its own line.
    private var segment: some View {
        HStack(spacing: 2) {
            segmentPill("Films", .films)
            segmentPill("Lists", .lists)
        }
        .padding(2)
        .background(Capsule().strokeBorder(Color.stashInk.opacity(0.28), lineWidth: 1.2))
    }

    private func segmentPill(_ label: String, _ value: Mode) -> some View {
        let isOn = mode == value
        return Micro(text: label, size: 9.5, tracking: 1, color: isOn ? .stashOnInk : .stashInk.opacity(0.65))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background { if isOn { Capsule().fill(Color.stashInk) } }
            .contentShape(Capsule())
            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { mode = value } }
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : [.isButton])
    }

    private func chips(saves: [Video]) -> some View {
        let topics = topics(in: saves)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                TopicChip(label: "all", isOn: focus == .all) { focus = .all }
                ForEach(rowTopics(topics)) { topic in
                    // The count is saves carrying the topic, not films — say so to VoiceOver.
                    TopicChip(label: topic.name, count: topic.count, unit: "saves", isOn: focus == .topic(topic.name)) {
                        focus = focus == .topic(topic.name) ? .all : .topic(topic.name)
                    }
                }
                TopicChip(label: "more", symbol: "ellipsis", isOn: false) { browsingTopics = true }
            }
        }
        .sheet(isPresented: $browsingTopics) {
            TopicPicker(topics: topics, focus: topicFocus, unit: "saves")
        }
    }

    private func listCards(_ lists: [Video], filmsByID: [String: FilmWall.Film], seen: Set<String>) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(lists) { video in
                listCard(video, filmsByID: filmsByID, seen: seen)
            }
        }
        .animation(.easeOut(duration: 0.35), value: focus)
    }

    /// One list save as a card; tapping opens the save's own page, not a film's.
    private func listCard(_ video: Video, filmsByID: [String: FilmWall.Film], seen: Set<String>,
                          label: String? = nil) -> some View {
        NavigationLink {
            VideoDetailView(video: video)
        } label: {
            ListCard(video: video,
                     films: video.films.compactMap { filmsByID[FilmWall.identity($0)] },
                     refs: refs, seen: seen, label: label, resolve: resolve)
        }
        .buttonStyle(.plain)
    }

    private func wall(runs: [MonthRun<FilmWall.Film>], savesByID: [String: Video], seen: Set<String>) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(runs) { run in
                Micro(text: run.title, size: 10, tracking: 2.2, color: .stashInk.opacity(0.62))
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                    .id(run.id)
                // Captions run one or two lines, so cells hang from the top of their row.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 3), spacing: 10) {
                    ForEach(run.items) { film in
                        let isSeen = seen.contains(film.id)
                        NavigationLink {
                            FilmPageView(film: film, saves: savesByID)
                        } label: {
                            FilmTile(film: film, ref: refs[film.id], seen: isSeen)
                        }
                        .buttonStyle(.plain)
                        // A long press is the seen toggle; a tap still opens the page.
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in toggleSeen(film) })
                        .accessibilityLabel(film.accessibilityLabel + (isSeen ? ", seen" : ""))
                        .accessibilityAction(named: isSeen ? "Mark unseen" : "Mark seen") { toggleSeen(film) }
                        .task(id: film.id) { await resolve(film) }
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.35), value: focus)
        .animation(.easeOut(duration: 0.35), value: seenJSON)
    }

    /// One flag per film; nothing else in the store moves.
    private func toggleSeen(_ film: FilmWall.Film) {
        var keys = FilmWall.seenKeys(seenJSON)
        if !keys.insert(film.id).inserted { keys.remove(film.id) }
        seenJSON = FilmWall.seenData(keys)
    }

    /// One lookup per film, once. `FilmResolver` caches too, so a cell that reappears never
    /// leaves the actor either way — this just keeps the poster on screen across scrolls.
    private func resolve(_ film: FilmWall.Film) async {
        guard !refs.keys.contains(film.id) else { return }
        do {
            let ref = try await FilmResolver.shared.film(for: FilmPick(title: film.title, year: film.year))
            refs.updateValue(ref, forKey: film.id)
        } catch {
            // Offline, or cancelled by scrolling away mid-lookup. Neither is a verdict on the
            // film, so the key stays absent: the tile keeps shimmering and the next appearance
            // asks again. Only a returned no-match is recorded as one.
        }
    }

    private var emptyState: some View {
        StashEmptyState(
            symbol: "movieclapper",
            tint: .categoryFilm,
            title: "No films yet.",
            message: "Save a TikTok that names a movie — or ten — and it lands here.",
            offersImport: videos.isEmpty
        )
    }
}

// MARK: - Poster

/// The poster, or a typographic sleeve when Wikipedia had no unambiguous match. A film that
/// came out of a list gets a deck edge behind it: two cards of the same shape peeking out,
/// so "one of ten" reads before the caption does.
private struct FilmTile: View {
    let film: FilmWall.Film
    /// The lookup in one value: `nil` while it is in flight, `.some(nil)` once it came back
    /// without an unambiguous match, `.some(ref)` when it found one.
    var ref: FilmRef??
    /// A tick on the poster, and the caption dims and says so.
    var seen = false
    /// Off on the film page and in list cards, where something else carries the title.
    var caption = true
    /// List cards draw the poster at thumb size: tighter corners, no deck edge, no sleeve text.
    var compact = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: compact ? 6 : 12, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                if film.isFromList, !compact {
                    shape.fill(Color.categoryFilm.opacity(0.14)).offset(x: 6, y: -6)
                    shape.fill(Color.categoryFilm.opacity(0.28)).offset(x: 3, y: -3)
                }
                poster
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            if caption {
                Text(film.title)
                    .font(.archivo(12, .bold))
                    .foregroundStyle(Color.stashInk.opacity(seen ? 0.62 : 1))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                let yearLine = [film.year.map(String.init), seen ? "seen" : nil].compactMap { $0 }
                if !yearLine.isEmpty {
                    Micro(text: yearLine.joined(separator: " · "), size: 9.5, tracking: 1.2, color: .stashInk.opacity(0.62))
                        .lineLimit(1)
                }
            }
        }
    }

    /// Overlaid on a clear colour so the image never gets a say in the tile's size, and clipped
    /// for touches as well as drawing — the same two traps WallTile documents on Cook.
    ///
    /// Shimmer means "coming"; the sleeve means "this is the poster". A lookup still in flight
    /// and one that came back with nothing used to draw the same tile (F34).
    private var poster: some View {
        Color.clear
            .overlay {
                switch ref {
                case .none:
                    ShimmerBlock(cornerRadius: 12)
                case .some(let resolved):
                    // A match without portrait art is as final as no match at all.
                    if let url = resolved?.posterURL {
                        AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
                            ShimmerBlock(cornerRadius: 12)
                        }
                    } else {
                        sleeve
                    }
                }
            }
            .clipped()
            .contentShape(shape)
            .clipShape(shape)
            .overlay(alignment: .topTrailing) {
                if seen {
                    Image(systemName: "checkmark")
                        .font(.system(size: compact ? 7 : 10, weight: .black))
                        .foregroundStyle(Color.stashOnAccent)
                        .frame(width: compact ? 14 : 22, height: compact ? 14 : 22)
                        .background(Color.categoryCoding, in: Circle())
                        .padding(compact ? 3 : 6)
                }
            }
    }

    private var sleeve: some View {
        Color.categoryFilm
            .overlay(alignment: .bottomLeading) {
                if !compact {
                    Micro(text: film.title, size: 12, tracking: 0.4, color: .stashOnAccent)
                        .lineLimit(3)
                        .padding(10)
                }
            }
    }
}

// MARK: - List card

/// One list save: the clip's title and author, a fan of its posters, and how many of them
/// you have seen. The same card is the "Newest list" above the wall and every row of Lists.
private struct ListCard: View {
    let video: Video
    /// The save's films in the order it named them, as the wall knows them (merged identity).
    let films: [FilmWall.Film]
    let refs: [String: FilmRef?]
    let seen: Set<String>
    /// Over the title; defaults to when the clip was saved.
    var label: String? = nil
    let resolve: (FilmWall.Film) async -> Void

    private static let fan = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Micro(text: label ?? video.bookmarkedAt.formatted(.relative(presentation: .named)),
                  size: 9.5, tracking: 1.8, color: .categoryFilm)
            Text(video.rowTitle)
                .font(.archivo(15, .heavy))
                .foregroundStyle(Color.stashInk)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(subline)
                .font(.archivo(11.5))
                .foregroundStyle(Color.stashInk.opacity(0.55))
                .lineLimit(1)
            HStack(spacing: 4) {
                ForEach(films.prefix(Self.fan)) { film in
                    FilmTile(film: film, ref: refs[film.id], seen: seen.contains(film.id), caption: false, compact: true)
                        .frame(width: 36)
                        .task(id: film.id) { await resolve(film) }
                }
                if films.count > Self.fan {
                    Micro(text: "+\(films.count - Self.fan)", size: 9.5, tracking: 0.4, color: .stashInk.opacity(0.62))
                        .frame(width: 36, height: 54)
                        .background(Color.stashInk.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .stashOutlineCard(padding: 14)
        .accessibilityElement(children: .combine)
    }

    private var subline: String {
        let seenCount = films.filter { seen.contains($0.id) }.count
        let author = video.author.isEmpty ? nil : "@\(video.author)"
        return [author, "\(seenCount) of \(films.count) seen"].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Film page

/// One film: the poster big, and every save that named it.
private struct FilmPageView: View {
    let film: FilmWall.Film
    let saves: [String: Video]

    @Environment(\.openURL) private var openURL
    @AppStorage(FilmWall.seenKey) private var seenJSON: Data?
    /// Same three states as the wall's tiles: absent while resolving, `nil` for a recorded miss.
    @State private var ref: FilmRef??

    /// The resolved match, if the lookup has produced one. Only this is a link.
    private var match: FilmRef? { ref ?? nil }

    /// The clip to watch: the newest save that named this film, which is also the first of
    /// the "Saved in" rows below.
    private var newestSave: Video? {
        film.marks.lazy.compactMap { saves[$0.sourceID] }.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                FilmTile(film: film, ref: ref, seen: FilmWall.seenKeys(seenJSON).contains(film.id), caption: false)
                    .containerRelativeFrame(.horizontal) { width, _ in width * 0.6 }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                Text(film.title)
                    .font(.archivo(28, .heavy))
                    .foregroundStyle(Color.stashInk)
                    .padding(.top, 20)
                if let year = film.year {
                    Micro(text: String(year), size: 10, tracking: 1.8, color: .stashInk.opacity(0.62))
                        .padding(.top, 6)
                }
                actions.padding(.top, 18)
                savesSection.padding(.top, 24)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, stashTabBarClearance)
        }
        .background(Color.stashBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            do {
                ref = .some(try await FilmResolver.shared.film(for: FilmPick(title: film.title, year: film.year)))
            } catch is CancellationError {
                // Left the page mid-lookup; nothing to draw for.
            } catch {
                // Offline. Unlike the wall — whose cells re-run `.task(id:)` as they recycle —
                // this `.task` runs once per appearance, so leaving it unresolved would promise
                // a hero poster that never arrives. Draw the sleeve instead. The state dies
                // with the view, so coming back to the page asks again.
                ref = .some(nil)
            }
        }
    }

    /// One primary, one secondary — the grammar every other vertical's detail already uses
    /// (F22). The film page used to have neither: a Wikipedia text link was the whole of it.
    private var actions: some View {
        VStack(spacing: 10) {
            if let newestSave {
                StashPrimaryButton(title: "Watch the clip", systemImage: "play.fill") {
                    openURL(newestSave.url)
                }
            }
            // Only a resolved title is a link; a guess would be a link to the wrong movie.
            if let match {
                linkRow("Where to watch", "JustWatch · streaming, rent, buy", whereToWatch)
                linkRow("Read about it", "Wikipedia", match.detailURL)
            }
        }
    }

    /// JustWatch's search for the title and year, in the user's country (JustWatch spells
    /// Britain "uk"). Its own pages need a JustWatch id the resolver does not have.
    private var whereToWatch: URL {
        let region = Locale.current.region?.identifier ?? "US"
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "www.justwatch.com"
        parts.path = "/\(region == "GB" ? "uk" : region.lowercased())/search"
        parts.queryItems = [URLQueryItem(name: "q", value: [film.title, film.year.map(String.init)].compactMap { $0 }.joined(separator: " "))]
        return parts.url ?? URL(string: "https://www.justwatch.com")!
    }

    /// A row that leaves the app, so it wears the arrow (F5) — same frame as the "Saved in" rows.
    private func linkRow(_ title: String, _ detail: String, _ url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 11) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.archivo(13.5, .bold))
                        .foregroundStyle(Color.stashInk)
                    Text(detail)
                        .font(.archivo(11.5))
                        .foregroundStyle(Color.stashInk.opacity(0.55))
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.categoryFilm)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.stashInk, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(detail)")
    }

    private var topBar: some View {
        HStack {
            StashBackButton()
            Spacer()
            CategoryBadge(category: .film)
        }
        .padding(.top, 8)
    }

    private var savesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Micro(text: "Saved in", size: 10, tracking: 2, color: .categoryFilm)
            ForEach(film.marks) { mark in
                if let video = saves[mark.sourceID] {
                    NavigationLink { VideoDetailView(video: video) } label: { row(video, mark) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ video: Video, _ mark: FilmWall.Mark) -> some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text(video.rowTitle)
                    .font(.archivo(13.5, .bold))
                    .foregroundStyle(Color.stashInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !video.author.isEmpty {
                    Text("@\(video.author)")
                        .font(.archivo(11.5))
                        .foregroundStyle(Color.stashInk.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if mark.isList {
                Micro(text: "\(mark.position) of \(mark.outOf)", size: 9.5, tracking: 1.2,
                      color: .categoryFilm)
            }
            // The row pushes the save's own screen. Music's identical-looking rows leave the
            // app and wear the arrow; nothing else may (F5).
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.stashInk.opacity(0.4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.stashInk, lineWidth: 1.5))
    }
}

#Preview("Film wall") {
    FilmsView()
        .modelContainer(SampleData.previewContainer)
}
