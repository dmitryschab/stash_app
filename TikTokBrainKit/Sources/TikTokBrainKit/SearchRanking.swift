// SearchRanking.swift
//
// Search by what a save is about. Each save is searched by one text, `Video.about`, and ranked
// two ways:
//
//   meaning → cosine between the query's vector and the save's, once it clears `meaningFloor`
//   words   → whole-word hits between the query and the about-text, with plurals folded
//
// Online, a save that has a vector is judged on meaning, and saying the query's word lifts it by
// `wordBoost`; scores that land in one `tieBand` count as equal and go newest first. Offline, or
// for a save that has no vector yet, only words can find it, ranked by how many of them hit.
//
// The arithmetic sits here rather than in the view because the view cannot be unit-tested and
// this can: the ordering rule is the whole feature, and a boundary typo in it is invisible until
// someone notices their search got worse.

import Foundation

/// One save, reduced to what ranking reads. Built once per library change by
/// `SearchIndex.build`, so a keystroke ranks over plain values instead of re-reading the store.
public struct SearchEntry: Sendable {
    public var videoID: String
    public var bookmarkedAt: Date
    /// Folded, stemmed words of the text this save is searched by.
    public var words: Set<String>
    /// The words come from the box's about-text. False means they are the summary and transcript
    /// stand-in a save is searched by until its about-text arrives.
    public var hasAbout: Bool
    /// The save's vector, only when it was embedded from the about-text.
    public var embedding: [Float]?

    public init(
        videoID: String,
        bookmarkedAt: Date,
        words: Set<String>,
        hasAbout: Bool,
        embedding: [Float]?
    ) {
        self.videoID = videoID
        self.bookmarkedAt = bookmarkedAt
        self.words = words
        self.hasAbout = hasAbout
        self.embedding = embedding
    }
}

public struct SearchMatch: Sendable, Equatable {
    public let videoID: String
}

public enum SearchIndex {
    /// How close a save has to be in meaning before it shows up having matched no word at all.
    /// Starts at the value `SearchBlend` measured for unrelated pairs versus real paraphrases;
    /// all three constants are meant to be tuned against real about-text vectors.
    public static let meaningFloor = 0.35

    /// What saying one of the query's words adds to a save's meaning score.
    public static let wordBoost = 0.15

    /// Scores closer than this are a tie, and a tie goes to the newer save.
    public static let tieBand = 0.02

    // MARK: Words

    /// Words too common to say anything about what a save is. A query made only of these finds
    /// nothing by word; online its meaning still can.
    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "how", "i", "in", "is",
        "it", "my", "of", "on", "or", "so", "the", "this", "to", "was", "what", "when", "where",
        "who", "why", "with", "you", "your",
    ]

    /// Lowercased, accent-folded, apostrophes removed ("dog's" is "dogs", not "dog" and "s"),
    /// split on anything that is not a letter or digit, one-character tokens and stop-words
    /// dropped, each word stemmed.
    public static func words(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        var result = Set<String>()
        for token in folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(token)
            if word.count < 2 || stopWords.contains(word) { continue }
            result.insert(stem(word))
        }
        return result
    }

    /// Takes a plural down to its singular so "cakes" meets "cake" and "dishes" meets "dish".
    /// "es" comes off only after a sound that needs it (-ses, -xes, -zes, -ches, -shes); any other
    /// word loses just its "s", unless it ends in "ss" ("glass" is not "glas"). Words of three
    /// characters or fewer are left alone ("bus").
    public static func stem(_ word: String) -> String {
        guard word.count > 3 else { return word }
        for ending in ["ses", "xes", "zes", "ches", "shes"] where word.hasSuffix(ending) {
            return String(word.dropLast(2))
        }
        if word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    // MARK: Build

    /// One entry per video. A save with an about-text is searched by that and nothing else: its
    /// title, topics, caption, hashtags and on-screen text are the creator's words for reach, not
    /// for what the video is. A save still waiting for its about-text falls back to its summary
    /// and transcript, and ranks below every save that has one.
    ///
    /// A vector counts only if it was embedded from an about-text (`BoxEmbeddingClient.revision`).
    /// An older one was built from title and hashtags, and comparing a query against it would
    /// rank the save by exactly what the about-text exists to replace.
    public static func build(_ videos: [Video]) -> [SearchEntry] {
        videos.map { video in
            if let about = video.about, !about.isEmpty {
                var vector: [Float]?
                if video.embeddingRevision == BoxEmbeddingClient.revision, let data = video.embedding {
                    let unpacked = EmbeddingVector.unpack(data)
                    vector = unpacked.isEmpty ? nil : unpacked
                }
                return SearchEntry(
                    videoID: video.videoID, bookmarkedAt: video.bookmarkedAt,
                    words: words(about), hasAbout: true, embedding: vector)
            }
            return SearchEntry(
                videoID: video.videoID, bookmarkedAt: video.bookmarkedAt,
                words: words(video.summary + " " + (video.transcript ?? "")),
                hasAbout: false, embedding: nil)
        }
    }

    // MARK: Rank

    /// The matches for a query, best first.
    ///
    /// Group 0 is every save judged on meaning (online, has an about-text and a vector): scored by
    /// cosine, plus `wordBoost` if it says a query word, bucketed by `tieBand`, then newest first
    /// inside a bucket. It is in when it said a word or cleared `meaningFloor`.
    ///
    /// Group 1 is everything else, found by word only: more query words hit first, a save with an
    /// about-text before one without, then newest first. It always sits below group 0.
    public static func rank(
        _ entries: [SearchEntry], query: String, embedding: [Float]?
    ) -> [SearchMatch] {
        let queryWords = words(query)

        struct Scored {
            let entry: SearchEntry
            let group: Int
            let key: Int
        }

        var scored: [Scored] = []
        for entry in entries {
            let hits = queryWords.intersection(entry.words).count
            if let embedding, entry.hasAbout, let stored = entry.embedding {
                let cosine = EmbeddingVector.cosine(embedding, stored)
                guard hits > 0 || cosine >= meaningFloor else { continue }
                let score = cosine + (hits > 0 ? wordBoost : 0)
                scored.append(Scored(entry: entry, group: 0, key: Int((score / tieBand).rounded(.down))))
            } else {
                guard hits > 0 else { continue }
                scored.append(Scored(entry: entry, group: 1, key: hits))
            }
        }

        scored.sort { a, b in
            if a.group != b.group { return a.group < b.group }
            if a.key != b.key { return a.key > b.key }
            if a.group == 1, a.entry.hasAbout != b.entry.hasAbout { return a.entry.hasAbout }
            if a.entry.bookmarkedAt != b.entry.bookmarkedAt {
                return a.entry.bookmarkedAt > b.entry.bookmarkedAt
            }
            return a.entry.videoID < b.entry.videoID
        }
        return scored.map { SearchMatch(videoID: $0.entry.videoID) }
    }
}
