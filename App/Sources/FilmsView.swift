// FilmsView.swift
//
// The Films tab: every movie your saves named, as a poster wall. Music's idea, one medium
// over — the film is the unit and a save is a mark on it, so one clip that lists ten movies
// puts ten posters on the wall and the same movie named by two clips is still one poster.
//
// A save that named two or more films is a "list" (the "10 best sci-fi movies" TikTok). A
// film that came out of one wears a deck edge behind its poster and says where it placed
// ("4 of 10"); a film from a single-movie save is a plain poster. Posters and the Wikipedia
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

        /// The line under the poster: "2023 · 4 of 10", or just whichever half exists.
        var microLine: String {
            [year.map(String.init), placement].compactMap { $0 }.joined(separator: " · ")
        }

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
            && wall[0].microLine == "2021" && wall[2].microLine == "2016 · 1 of 4"
            && wall[0].accessibilityLabel == "Dune, 2021"
            && wall[2].accessibilityLabel == "Arrival, 2016, from a list of 4"
    }
    #endif
}

// MARK: - The wall

struct FilmsView: View {
    @Query(sort: \Video.bookmarkedAt, order: .reverse) private var videos: [Video]
    @State private var focus: Filter = .all
    @State private var browsingTopics = false
    /// Resolved posters, keyed by `FilmWall.Film.id`, so scrolling back does not re-resolve.
    @State private var refs: [String: FilmRef] = [:]

    /// One more state than Cook's `String?`: "lists" is a filter that is not a topic.
    private enum Filter: Equatable { case all, lists, topic(String) }

    /// Read once per body pass (see `body`): each access decodes every video's film payload.
    private var saves: [Video] {
        videos.filter { $0.category == .film && !$0.films.isEmpty }
    }

    private func shown(in films: [FilmWall.Film], saves: [Video]) -> [FilmWall.Film] {
        switch focus {
        case .all:
            return films
        case .lists:
            return films.filter(\.isFromList)
        case .topic(let name):
            let ids = Set(saves.filter { $0.topics.contains(name) }.map(\.videoID))
            return films.filter { film in film.marks.contains { ids.contains($0.sourceID) } }
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
        let runs = monthRuns(shown) { $0.savedAt }
        let savesByID = Dictionary(saves.map { ($0.videoID, $0) }, uniquingKeysWith: { first, _ in first })
        NavigationStack {
            ScrollViewReader { proxy in
                StashScrollView(tab: .films) {
                    VStack(alignment: .leading, spacing: 0) {
                        StashHeader(title: "Films", trailing: trailing(films: films, shown: shown, saves: saves))
                            .padding(.top, 8)
                        if !saves.isEmpty {
                            chips(films: films, saves: saves).padding(.top, 8)
                        }
                        if films.isEmpty {
                            emptyState.padding(.top, 48)
                        } else {
                            wall(runs: runs, savesByID: savesByID).padding(.top, 4)
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

    /// Cook's rule for the header: totals until a chip is on, then how much of the wall it left.
    private func trailing(films: [FilmWall.Film], shown: [FilmWall.Film], saves: [Video]) -> String {
        guard focus != .all else {
            return "\(films.count) \(films.count == 1 ? "film" : "films") · \(saves.count) \(saves.count == 1 ? "save" : "saves")"
        }
        return "\(shown.count) of \(films.count)"
    }

    private func chips(films: [FilmWall.Film], saves: [Video]) -> some View {
        let topics = topics(in: saves)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                TopicChip(label: "all", isOn: focus == .all) { focus = .all }
                // A chip that can only show an empty wall is not a filter.
                if films.contains(where: \.isFromList) {
                    TopicChip(label: "lists", isOn: focus == .lists) {
                        focus = focus == .lists ? .all : .lists
                    }
                }
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

    private func wall(runs: [MonthRun<FilmWall.Film>], savesByID: [String: Video]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(runs) { run in
                Micro(text: run.title, size: 10, tracking: 2.2, color: .stashInk.opacity(0.45))
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                    .id(run.id)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(run.items) { film in
                        NavigationLink {
                            FilmPageView(film: film, saves: savesByID)
                        } label: {
                            FilmTile(film: film, ref: refs[film.id])
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(film.accessibilityLabel)
                        .task(id: film.id) { await resolve(film) }
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.35), value: focus)
    }

    /// One lookup per film, once. `FilmResolver` caches too, so a cell that reappears never
    /// leaves the actor either way — this just keeps the poster on screen across scrolls.
    private func resolve(_ film: FilmWall.Film) async {
        guard refs[film.id] == nil else { return }
        if let ref = try? await FilmResolver.shared.film(for: FilmPick(title: film.title, year: film.year)) {
            refs[film.id] = ref
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
    var ref: FilmRef?
    /// Off on the film page, where the title block carries the year.
    var caption = true

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                if film.isFromList {
                    shape.fill(Color.categoryFilm.opacity(0.14)).offset(x: 6, y: -6)
                    shape.fill(Color.categoryFilm.opacity(0.28)).offset(x: 3, y: -3)
                }
                poster
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            if caption, !film.microLine.isEmpty {
                Micro(text: film.microLine, size: 10, tracking: 1.2, color: .stashInk.opacity(0.45))
                    .lineLimit(1)
            }
        }
    }

    /// Overlaid on a clear colour so the image never gets a say in the tile's size, and clipped
    /// for touches as well as drawing — the same two traps WallTile documents on Cook.
    private var poster: some View {
        Color.clear
            .overlay {
                AsyncImage(url: ref?.posterURL) { $0.resizable().scaledToFill() } placeholder: {
                    sleeve
                }
            }
            .clipped()
            .contentShape(shape)
            .clipShape(shape)
    }

    private var sleeve: some View {
        Color.categoryFilm
            .overlay(alignment: .bottomLeading) {
                Micro(text: film.title, size: 12, tracking: 0.4, color: .stashOnAccent)
                    .lineLimit(3)
                    .padding(10)
            }
    }
}

// MARK: - Film page

/// One film: the poster big, and every save that named it.
private struct FilmPageView: View {
    let film: FilmWall.Film
    let saves: [String: Video]

    @State private var ref: FilmRef?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                FilmTile(film: film, ref: ref, caption: false)
                    .containerRelativeFrame(.horizontal) { width, _ in width * 0.6 }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                Text(film.title)
                    .font(.archivo(28, .heavy))
                    .foregroundStyle(Color.stashInk)
                    .padding(.top, 20)
                if let year = film.year {
                    Micro(text: String(year), size: 10, tracking: 1.8, color: .stashInk.opacity(0.5))
                        .padding(.top, 6)
                }
                // Only a resolved title is a link; a guess would be a link to the wrong movie.
                if let ref {
                    Link("Open on Wikipedia", destination: ref.detailURL)
                        .font(.archivo(13, .semibold))
                        .foregroundStyle(Color.categoryFilm)
                        .padding(.top, 10)
                }
                savesSection.padding(.top, 24)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, stashTabBarClearance)
        }
        .background(Color.stashBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { ref = try? await FilmResolver.shared.film(for: FilmPick(title: film.title, year: film.year)) }
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
