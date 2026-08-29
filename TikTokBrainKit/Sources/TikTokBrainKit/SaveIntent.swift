// SaveIntent.swift
//
// Why a save was saved. The Library's desk shelves group by intent — to watch, to try, to
// buy, to look at, to know — because that is the question a person asks their own library
// ("what was I going to do with all this?"), where a category only answers what a video was
// about. Measured on the real 855-save library, categories also under-shelve: topics find a
// 42-save travel cluster where the category system filed 15.
//
// Derived, never stored: intent is a pure function of what the analysis already carries
// (category, topics, whether anything is for sale), so the rules can move without a
// migration or a re-analysis pass. The rules are deliberately word-list simple — a save the
// lists misread lands on Reference, which is the shelf that claims the least.

import Foundation

public enum SaveIntent: String, CaseIterable, Codable, Sendable {
    case buy, watch, tryIt, mood, reference

    /// Precedence is the argument order of a person sorting their own desk: something for
    /// sale is a purchase whatever the video was about; a film list that mentions
    /// productivity is still a film list (watch beats try); doing beats looking (a DIY save
    /// under `home` is try, a decor save is mood); and everything unclaimed is reference.
    ///
    /// `includeBuy: false` hands the buy shelf back to the Haul tab when it is on the pill —
    /// the same take-back rule `libraryShelves(visible:)` applies to categories.
    public static func classify(category: Category?, topics: [String],
                                hasBuys: Bool, includeBuy: Bool = true) -> SaveIntent {
        if includeBuy && hasBuys { return .buy }
        let lowered = Set(topics.map { $0.lowercased() })
        if category == .film || category == .comedy || !lowered.isDisjoint(with: Self.watchTopics) {
            return .watch
        }
        if category == .fitness || category == .travel || category == .recipe
            || !lowered.isDisjoint(with: Self.tryTopics) {
            return .tryIt
        }
        if category == .style || category == .home || !lowered.isDisjoint(with: Self.moodTopics) {
            return .mood
        }
        return .reference
    }

    /// Exact topic matches, not substrings: the analyzer already writes topics as short
    /// lowercase keywords, and substring matching made "styling" claim "style".
    static let watchTopics: Set<String> = [
        "cinema", "movies", "movie", "film", "films", "anime", "tv", "tv shows", "series",
        "show", "shows", "sci-fi", "documentary", "netflix", "watchlist", "k-drama", "drama",
    ]

    static let tryTopics: Set<String> = [
        "diy", "tutorial", "tutorials", "how-to", "howto", "productivity", "automation",
        "ai agents", "life hacks", "lifehack", "lifehacks", "habits", "meal prep", "recipe",
        "recipes", "workout", "fitness", "travel", "travel tips", "cleaning", "organization",
        "renovation", "study tips", "gardening",
    ]

    static let moodTopics: Set<String> = [
        "aesthetic", "aesthetics", "interior design", "home decor", "decor", "interior",
        "fashion", "outfit", "outfits", "style", "beauty", "makeup", "skincare", "moodboard",
        "vibes", "design inspiration",
    ]
}
