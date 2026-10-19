import XCTest
@testable import TikTokBrainKit

/// The search scorecard: the owner's real library, ranked by the scorer the app shipped before
/// about-texts (`LegacyRanker`) and by `SearchIndex.rank`, against hand-picked queries that each
/// name the saves that must come back (`mustAppear`) and the ones that belong in the first three
/// (`top3`).
///
/// No model is called here. scripts/search_scorecard/build_cache.py writes every about-text and
/// every vector to one JSON file; this reads only that. Skipped unless `STASH_SCORECARD` is the
/// path of that file, so the normal suite never needs the library:
///
///   STASH_SCORECARD=/path/to/scorecard-cache.json swift test --filter SearchScorecardTests
///
/// The gate is not "beat legacy on recall": legacy matches query words as substrings of the
/// title, caption and transcript, so "the" or "in" brings back nearly the whole library (211 saves
/// a query on average) and every save it was meant to find along with it. Instead the new ranker
/// must find most of what it should (`minimumRecall`) while returning a short list
/// (`maximumAverageReturned`), and put the right save in the first three at least as often as
/// legacy. Saves legacy found and the new ranker misses are printed, not asserted: queries that
/// reuse a save's title words make some of those unreachable by design.
final class SearchScorecardTests: XCTestCase {

    private static let minimumRecall = 0.80
    private static let maximumAverageReturned = 40.0

    // MARK: Cache

    private struct Cache: Decodable {
        struct Save: Decodable {
            struct Legacy: Decodable {
                let title: String
                let topics: [String]
                let caption: String
                let summary: String
                let transcript: String
            }

            let videoID: String
            let bookmarkedAt: Date
            let about: String
            let aboutVector: [Float]
            let legacy: Legacy
            let legacyVector: [Float]
        }

        struct Query: Decodable {
            let query: String
            let vector: [Float]
            let mustAppear: [String]
            let top3: [String]
        }

        let saves: [Save]
        let queries: [Query]
    }

    private func loadCache() throws -> Cache {
        guard let path = ProcessInfo.processInfo.environment["STASH_SCORECARD"], !path.isEmpty else {
            throw XCTSkip("STASH_SCORECARD is not set — the scorecard needs the cache build_cache.py writes")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Cache.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    // MARK: Rankers

    private func legacyMatches(_ cache: Cache, _ query: Cache.Query) -> [String] {
        // The old scorer reads `entries` newest first: its recency term takes the library's span
        // from the first and last entry.
        let entries = cache.saves.sorted { $0.bookmarkedAt > $1.bookmarkedAt }.map { save in
            LegacyRanker.Entry(
                videoID: save.videoID,
                bookmarkedAt: save.bookmarkedAt,
                fields: [
                    ("title", save.legacy.title.lowercased(), 2),
                    ("topics", save.legacy.topics.joined(separator: " ").lowercased(), 1.5),
                    ("caption", save.legacy.caption.lowercased(), 1),
                    ("summary", save.legacy.summary.lowercased(), 1),
                    ("transcript", save.legacy.transcript.lowercased(), 1),
                    // The seed has no on-screen text; the field stays so the weights line up.
                    ("on-screen text", "", 1),
                ],
                embedding: save.legacyVector.isEmpty ? nil : save.legacyVector)
        }
        return LegacyRanker.score(entries, query: query.query, embedding: query.vector).map(\.videoID)
    }

    private func newMatches(_ cache: Cache, _ query: Cache.Query) -> [String] {
        let entries = cache.saves.map { save in
            SearchEntry(
                videoID: save.videoID,
                bookmarkedAt: save.bookmarkedAt,
                words: SearchIndex.words(save.about),
                hasAbout: !save.about.isEmpty,
                embedding: save.aboutVector.isEmpty ? nil : save.aboutVector)
        }
        return SearchIndex.rank(entries, query: query.query, embedding: query.vector).map(\.videoID)
    }

    // MARK: Scoring

    private struct Score {
        var found = 0
        var must = 0
        var top3Hits = 0
        var queries = 0
        /// Results returned across every query: recall bought by returning the whole library
        /// shows up here.
        var returned = 0

        var recall: Double { must == 0 ? 0 : Double(found) / Double(must) }
        var top3Rate: Double { queries == 0 ? 0 : Double(top3Hits) / Double(queries) }
        var averageReturned: Double { queries == 0 ? 0 : Double(returned) / Double(queries) }
    }

    private struct Row {
        let found: Set<String>
        let top3Hit: Bool
        let returned: Int
    }

    private func row(_ matches: [String], _ query: Cache.Query) -> Row {
        let returned = Set(matches)
        return Row(
            found: Set(query.mustAppear).intersection(returned),
            top3Hit: !Set(matches.prefix(3)).isDisjoint(with: query.top3),
            returned: matches.count)
    }

    private func cell(_ row: Row, _ query: Cache.Query) -> String {
        let found = "\(row.found.count)/\(query.mustAppear.count)"
        return "\(found.padding(toLength: 6, withPad: " ", startingAt: 0)) "
            + "\(row.top3Hit ? "yes" : "no ") "
            + String(row.returned).padding(toLength: 4, withPad: " ", startingAt: 0)
    }

    func testAboutRankingBeatsLegacyOnTheScorecard() throws {
        let cache = try loadCache()
        var legacy = Score()
        var new = Score()
        var lost: [String] = []
        let titles = Dictionary(uniqueKeysWithValues: cache.saves.map { ($0.videoID, $0.legacy.title) })

        print("scorecard: \(cache.saves.count) saves, \(cache.queries.count) queries")
        print("query                                  | legacy found top3 returned | new found top3 returned")
        for query in cache.queries {
            let old = row(legacyMatches(cache, query), query)
            let now = row(newMatches(cache, query), query)
            legacy.found += old.found.count
            legacy.must += query.mustAppear.count
            legacy.top3Hits += old.top3Hit ? 1 : 0
            legacy.queries += 1
            legacy.returned += old.returned
            new.found += now.found.count
            new.must += query.mustAppear.count
            new.top3Hits += now.top3Hit ? 1 : 0
            new.queries += 1
            new.returned += now.returned

            for id in old.found.subtracting(now.found).sorted() {
                lost.append("\(query.query): \(titles[id] ?? "") (\(id))")
            }
            let label = query.query.padding(toLength: 38, withPad: " ", startingAt: 0)
            print("\(label) | \(cell(old, query))       | \(cell(now, query))")
        }

        func total(_ score: Score) -> String {
            String(format: "recall %d/%d = %.3f, top-3 %d/%d = %.3f, avg returned %.1f",
                   score.found, score.must, score.recall, score.top3Hits, score.queries,
                   score.top3Rate, score.averageReturned)
        }
        print("legacy: \(total(legacy))")
        print("new:    \(total(new))")
        print("found by legacy, missed by new (\(lost.count)):"
              + (lost.isEmpty ? " none" : "\n  " + lost.joined(separator: "\n  ")))

        XCTAssertGreaterThanOrEqual(new.recall, Self.minimumRecall, "new recall below the gate")
        XCTAssertLessThanOrEqual(new.averageReturned, Self.maximumAverageReturned,
                                 "new ranker returns too many saves per query")
        XCTAssertGreaterThanOrEqual(new.top3Rate, legacy.top3Rate, "new top-3 rate below legacy")
    }
}

// MARK: - Legacy ranker

/// Today's ranking before about-texts, copied verbatim from `App/Sources/SearchView.swift`
/// (`SearchIndex.score`, `recency`) and `TikTokBrainKit/.../BoxEmbeddingClient.swift`
/// (`SearchBlend`) as of 409d04f, renamed so it cannot collide with the Kit's own types. Kept
/// here, not in the app, because the app no longer ranks this way — this is the bar to beat.
enum LegacyRanker {
    struct Entry {
        let videoID: String
        let bookmarkedAt: Date
        /// (field label, lowercased text, weight) — title matches count double.
        let fields: [(label: String, text: String, weight: Double)]
        let embedding: [Float]?
    }

    struct Match {
        let videoID: String
        let score: Double
        let matchedIn: String
    }

    enum Blend {
        static let semanticWeight = 0.65
        static let lexicalWeight = 0.30
        static let recencyWeight = 0.05
        static let meaningFloor = 0.35

        static func score(cosine: Double, lexical: Double, recency: Double) -> Double {
            semanticWeight * cosine + lexicalWeight * lexical + recencyWeight * recency
        }
    }

    /// `entries` are newest first.
    static func score(_ entries: [Entry], query: String, embedding: [Float]?) -> [Match] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let oldest = entries.last?.bookmarkedAt ?? .distantPast
        let newest = entries.first?.bookmarkedAt ?? .distantPast

        return entries.compactMap { entry in
            var raw = 0.0
            var matchedIn: String?
            for field in entry.fields {
                let hits = tokens.filter { field.text.contains($0) }
                if !hits.isEmpty {
                    raw += Double(hits.count) * field.weight
                    if matchedIn == nil { matchedIn = field.label }
                }
            }
            let lexical = min(1, raw / (Double(tokens.count) * 2))

            guard let embedding, let stored = entry.embedding else {
                guard let matchedIn else { return nil }
                return Match(videoID: entry.videoID, score: lexical, matchedIn: matchedIn)
            }

            let cosine = EmbeddingVector.cosine(embedding, stored)
            let meaning = cosine >= Blend.meaningFloor
            guard matchedIn != nil || meaning else { return nil }
            let reason: String
            switch (matchedIn, meaning) {
            case (let field?, true): reason = "meaning and \(field)"
            case (let field?, false): reason = field
            case (nil, _): reason = "meaning"
            }
            return Match(
                videoID: entry.videoID,
                score: Blend.score(cosine: cosine, lexical: lexical,
                                   recency: recency(of: entry.bookmarkedAt, oldest: oldest, newest: newest)),
                matchedIn: reason)
        }
        .sorted { $0.score > $1.score }
    }

    private static func recency(of date: Date, oldest: Date, newest: Date) -> Double {
        let span = newest.timeIntervalSince(oldest)
        guard span > 0 else { return 1 }
        return min(1, max(0, date.timeIntervalSince(oldest) / span))
    }
}
