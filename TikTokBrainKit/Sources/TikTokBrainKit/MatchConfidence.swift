// MatchConfidence.swift
//
// Deciding whether a catalogue hit is actually the thing that was asked for.
//
// The iTunes Search API always answers. Ask it for "jungle selection vol 1" and it returns
// "Jungle Skeletons: Fire Various Selection, Vol. 1" by Silent Monkz — a real album, with a real
// tracklist, that appears nowhere in the video that prompted the search. Shipping that is worse
// than shipping nothing: an unlinked name reads as "we could not find it", while a wrong album
// with a full tracklist reads as fact.
//
// Token overlap rather than edit distance, because the two cases that must be separated are:
//   "Reflections"  vs  "Reflections / Secret Portraits"   → same release, accept
//   "jungle selection vol 1"  vs  "Jungle Skeletons: Fire Various Selection, Vol. 1"  → reject
// Character distance ranks those the wrong way round; shared words do not.

import Foundation

public enum MatchConfidence {
    /// Title agreement required when the title is the only evidence there is.
    public static let threshold = 0.6

    /// Title agreement required when the video also named the artist and the artist agrees.
    /// A matching artist is independent evidence, so it buys a lower bar on the title —
    /// "Reflections / Secret Portraits" by New Balance is plainly the album "Reflections"
    /// by New Balance, even though the two titles share only one word in three.
    public static let corroboratedThreshold = 0.3

    /// Case-folded alphanumeric words, punctuation and separators dropped. "Vol." and "vol"
    /// collapse to the same token, which is what makes volume-numbered releases comparable.
    static func tokens(_ text: String) -> Set<String> {
        let cleaned = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return Set(String(cleaned).split(separator: " ").map(String.init).filter { !$0.isEmpty })
    }

    /// Jaccard: shared tokens over the union, so the words the catalogue title adds count
    /// against it.
    ///
    /// Symmetric on purpose. Scoring against the *smaller* set instead — the first thing tried
    /// here — makes any short vague phrase a perfect subset of any long title containing its
    /// words: "jungle selection vol 1" scored 1.0 against "Jungle Skeletons: Fire Various
    /// Selection, Vol. 1", which is the exact match this gate exists to refuse.
    public static func score(_ asked: String, _ returned: String) -> Double {
        let left = tokens(asked), right = tokens(returned)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    /// Whether a catalogue hit may be linked.
    ///
    /// An artist the video named is a hard constraint, never a tiebreak: a title can coincide
    /// across releases, and linking "Genesis" by the wrong act is the same class of error as
    /// matching the wrong album. An artist the video did *not* name (`""`) constrains nothing —
    /// and buys nothing either, so those hits face the full title threshold alone.
    public static func accepts(
        askedTitle: String, askedArtist: String,
        returnedTitle: String, returnedArtist: String
    ) -> Bool {
        let titleScore = score(askedTitle, returnedTitle)
        let askedArtistTokens = tokens(askedArtist)
        guard !askedArtistTokens.isEmpty else { return titleScore >= threshold }
        guard !askedArtistTokens.isDisjoint(with: tokens(returnedArtist)) else { return false }
        return titleScore >= corroboratedThreshold
    }
}
