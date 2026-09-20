// LatelySelector.swift
//
// The Lately tab's brain: which topic the user is deep in right now, which old save a new one
// quietly rhymes with, and which interest came back after a real silence. Zero to three cards,
// never padded — a weak card is worse than an absent one, because every card makes a factual
// claim about the user's own library that has to survive being checked against its evidence.
//
// Deliberately unlike RecentsSelector, which this replaces. No four-hour sessions (an interest
// returned to across three weeks is still one interest), no calendar-day rotation (the digest
// must not change because the clock moved), no "one old save worth returning to" chosen for
// the user. Everything here is a pure function of IDs, dates and topics.
//
// The rules are exact-match only. A shared topic proves both saves mention local models; it
// does not prove the tutorial solves the project. Copy built on these candidates may only say
// what the counts and dates support. Full derivation, including why each threshold has the
// value it does: docs/superpowers/specs/2026-09-18-lately-technical-spec.md
//
// Eligibility that needs SwiftData — unclassified, archived, uncategorised saves — is the
// caller's job when it maps records into `Save`. What this file defends against is input that
// would make a claim dishonest regardless of provenance: no ID, no topics, a bookmark date in
// the future, or the same video twice.

import Foundation

public enum LatelySelector {

    // MARK: - Input

    public struct Save: Sendable {
        public let id: String
        public let date: Date
        public let topics: [String]
        public init(id: String, date: Date, topics: [String]) {
            self.id = id
            self.date = date
            self.topics = topics
        }
    }

    // MARK: - Rules

    /// Every threshold on screen. Changing one changes which stories exist, so `rulesVersion`
    /// moves with it and the persisted digests built under the old number stop matching.
    public enum Rules {
        public static let rulesVersion = 1
        /// How far back "recent" reaches from the newest save.
        public static let recentWindow: TimeInterval = 30 * 86400
        /// Saves needed before a topic is a current interest.
        public static let minCurrentSaves = 3
        /// Distinct topics two saves must share before they are a connection.
        public static let minSharedTopics = 2
        /// A shared topic this common describes the library, not the pair.
        public static let rarityCeiling = 0.20
        public static let minReturningRecent = 3
        public static let minReturningHistorical = 2
        /// Silence long enough that saving the topic again is a return, not a continuation.
        public static let returningGap: TimeInterval = 60 * 86400
        /// Labels that say nothing about what a save is about.
        public static let genericTopics: Set<String> = [
            "other", "general", "video", "tiktok", "fyp", "viral", "trending", "lifestyle",
        ]
    }

    // MARK: - Output

    public enum Kind: String, Sendable, Codable, Equatable {
        case currentInterest, connection, returningInterest
    }

    public struct CurrentInterest: Sendable, Codable, Equatable {
        /// Normalized topic, used for identity and dismissal.
        public let theme: String
        /// The topic as the analyzer spelled it, for the card's title.
        public let displayTheme: String
        /// Supporting saves, newest first. The card shows a few; the count is of all of them.
        public let evidenceIDs: [String]
        public let saveCount: Int
        public let firstDate: Date
        public let lastDate: Date
    }

    public struct Connection: Sendable, Codable, Equatable {
        public let recentID: String
        public let olderID: String
        /// The two rarest shared topics, in display spelling, for "Both mention X and Y."
        public let sharedTopics: [String]
        /// Every shared topic, normalized — more than the two the card names.
        public let sharedThemes: [String]
        public let recentDate: Date
        public let olderDate: Date
        public var evidenceIDs: [String] { [recentID, olderID] }
    }

    public struct ReturningInterest: Sendable, Codable, Equatable {
        public let theme: String
        public let displayTheme: String
        /// Saves inside the recent window, newest first. The face count is of these only.
        public let recentIDs: [String]
        /// The two newest saves from before the silence, newest first.
        public let historicalIDs: [String]
        public let recentCount: Int
        /// Whole days between the last save before the break and the first one after it.
        public let gapDays: Int
        public let firstRecentDate: Date
        public let lastRecentDate: Date
        public var evidenceIDs: [String] { recentIDs + historicalIDs }
    }

    public enum Card: Sendable, Codable, Equatable {
        case currentInterest(CurrentInterest)
        case connection(Connection)
        case returningInterest(ReturningInterest)

        public var kind: Kind {
            switch self {
            case .currentInterest: .currentInterest
            case .connection: .connection
            case .returningInterest: .returningInterest
            }
        }

        /// The normalized topic a card is about, shared by the two topic-shaped kinds so one
        /// dismissal covers both. A connection is about a pair, not a theme.
        public var themeKey: String? {
            switch self {
            case let .currentInterest(interest): interest.theme
            case let .returningInterest(returning): returning.theme
            case .connection: nil
            }
        }

        public var evidenceIDs: [String] {
            switch self {
            case let .currentInterest(interest): interest.evidenceIDs
            case let .connection(connection): connection.evidenceIDs
            case let .returningInterest(returning): returning.evidenceIDs
            }
        }

        /// A card's identity across rebuilds: same rules, same kind, same subject, same
        /// evidence. Ranking is not part of it, so a card that merely moved does not read as
        /// a new story the user has not seen.
        public var signature: String {
            let subject: String
            switch self {
            case let .currentInterest(interest): subject = interest.theme
            case let .returningInterest(returning): subject = returning.theme
            case let .connection(connection): subject = connection.evidenceIDs.sorted().joined(separator: "+")
            }
            return "\(Rules.rulesVersion)|\(kind.rawValue)|\(subject)|"
                + evidenceIDs.sorted().joined(separator: ",")
        }
    }

    public struct Digest: Sendable, Equatable {
        /// The newest eligible save. All windows measure from here, never from the clock.
        public let anchor: Date
        /// The oldest date still inside the recent window.
        public let recentStart: Date
        /// The library has not been touched in over a window: the copy speaks in past tense.
        public let isHistorical: Bool
        /// Zero to three, in display order.
        public let cards: [Card]
    }

    // MARK: - Entry point

    /// Builds the digest. `allow` rejects cards the user has hidden; it runs before
    /// composition so a hidden card frees its slot for the runner-up instead of blanking it.
    public static func digest(_ saves: [Save], now: Date,
                              allow: (Card) -> Bool = { _ in true }) -> Digest? {
        let eligible = eligible(saves, now: now)
        guard let anchor = eligible.map(\.date).max() else { return nil }

        let recentStart = anchor.addingTimeInterval(-Rules.recentWindow)
        let recent = eligible.filter { $0.date >= recentStart }
        let older = eligible.filter { $0.date < recentStart }
        let spellings = displaySpellings(eligible)
        let frequency = documentFrequency(eligible)

        var recentByID: [String: Eligible] = [:]
        for save in recent { recentByID[save.id] = save }
        var olderByID: [String: Eligible] = [:]
        for save in older { olderByID[save.id] = save }

        return Digest(
            anchor: anchor,
            recentStart: recentStart,
            isHistorical: now.timeIntervalSince(anchor) > Rules.recentWindow,
            cards: compose(
                currents: currentInterests(recent, spellings: spellings).filter {
                    allow(.currentInterest($0))
                },
                returnings: returningInterests(recent: recent, older: older,
                                               spellings: spellings).filter {
                    allow(.returningInterest($0))
                },
                connections: connectionCandidates(recent: recent, older: older,
                                                  frequency: frequency),
                connectionCard: { candidate in
                    makeConnection(candidate, recentByID: recentByID, olderByID: olderByID,
                                   spellings: spellings, frequency: frequency)
                },
                allow: allow))
    }

    // MARK: - Normalized input

    private struct Eligible {
        let id: String
        let date: Date
        /// Normalized, deduplicated, sorted — the keys everything below counts.
        let topics: [String]
        /// `topics` minus the labels that describe nothing. Sorted, and precomputed because
        /// connection matching intersects it once per candidate pair.
        let allowedTopics: [String]
        /// Collapsed but not lowercased, parallel to `topics`, for display spellings.
        let spellings: [String]
        /// Stable encoding of every field selection reads, for the duplicate-ID tie-break.
        var canonical: String {
            "\(id)|\(date.timeIntervalSince1970)|\(topics.joined(separator: ","))"
        }
    }

    /// Trim, collapse runs of whitespace, then lowercase. `lowercased()` is locale-independent
    /// in Swift, so a user's region cannot change which saves count as the same topic.
    private static func normalize(_ raw: String) -> (key: String, display: String)? {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return (collapsed.lowercased(), collapsed)
    }

    private static func eligible(_ saves: [Save], now: Date) -> [Eligible] {
        var byID: [String: Eligible] = [:]
        for save in saves {
            let id = save.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, save.date <= now else { continue }

            var keys: [String: String] = [:] // key -> smallest spelling within this save
            for topic in save.topics {
                guard let (key, display) = normalize(topic) else { continue }
                if let existing = keys[key], existing <= display { continue }
                keys[key] = display
            }
            guard !keys.isEmpty else { continue }

            let sorted = keys.keys.sorted()
            let candidate = Eligible(id: id, date: save.date, topics: sorted,
                                     allowedTopics: sorted.filter(isAllowed),
                                     spellings: sorted.map { keys[$0] ?? $0 })
            // Storage should hold one record per video; if it does not, the newest wins so a
            // count on a card can never double-count the same save.
            if let existing = byID[id] {
                let newer = candidate.date > existing.date
                let tied = candidate.date == existing.date && candidate.canonical < existing.canonical
                guard newer || tied else { continue }
            }
            byID[id] = candidate
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    /// One spelling per topic across the whole library, chosen deterministically so the same
    /// input always titles a card the same way.
    private static func displaySpellings(_ saves: [Eligible]) -> [String: String] {
        var best: [String: String] = [:]
        for save in saves {
            for (key, display) in zip(save.topics, save.spellings) {
                if let existing = best[key], existing <= display { continue }
                best[key] = display
            }
        }
        return best
    }

    /// Share of eligible saves mentioning each topic. A label on most of the library explains
    /// the library, not any pair inside it.
    private static func documentFrequency(_ saves: [Eligible]) -> [String: Double] {
        guard !saves.isEmpty else { return [:] }
        var counts: [String: Int] = [:]
        for save in saves {
            for topic in save.topics { counts[topic, default: 0] += 1 }
        }
        return counts.mapValues { Double($0) / Double(saves.count) }
    }

    private static func isAllowed(_ topic: String) -> Bool {
        !Rules.genericTopics.contains(topic)
    }

    /// Topic -> saves mentioning it, restricted to topics that can carry a story.
    private static func index(_ saves: [Eligible]) -> [String: [Eligible]] {
        var index: [String: [Eligible]] = [:]
        for save in saves {
            for topic in save.topics where isAllowed(topic) {
                index[topic, default: []].append(save)
            }
        }
        return index
    }

    /// Newest first; identical timestamps fall back to ID so the order cannot depend on how
    /// the array arrived.
    private static func newestFirst(_ saves: [Eligible]) -> [Eligible] {
        saves.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }

    private static func utcDay(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 86400).rounded(.down))
    }

    // MARK: - Current interest

    private static func currentInterests(_ recent: [Eligible],
                                         spellings: [String: String]) -> [CurrentInterest] {
        // Distinct save days ranks interests but never appears on a card, so it rides
        // alongside the candidate instead of inside it.
        index(recent).compactMap { topic, saves -> (CurrentInterest, days: Int)? in
            guard saves.count >= Rules.minCurrentSaves else { return nil }
            let ordered = newestFirst(saves)
            let interest = CurrentInterest(
                theme: topic,
                displayTheme: spellings[topic] ?? topic,
                evidenceIDs: ordered.map(\.id),
                saveCount: ordered.count,
                firstDate: ordered[ordered.count - 1].date,
                lastDate: ordered[0].date)
            return (interest, Set(ordered.map { utcDay($0.date) }).count)
        }
        .sorted { a, b in
            // More saves, then spread over more separate days, then more recent, then topic.
            if a.0.saveCount != b.0.saveCount { return a.0.saveCount > b.0.saveCount }
            if a.days != b.days { return a.days > b.days }
            if a.0.lastDate != b.0.lastDate { return a.0.lastDate > b.0.lastDate }
            return a.0.theme < b.0.theme
        }
        .map(\.0)
    }

    // MARK: - Connection

    /// A ranked pair before its card exists. Deliberately allocation-free: a large library can
    /// produce six figures of these, and only one ever becomes a card.
    private struct ConnectionCandidate {
        let recentID: String
        let olderID: String
        let recentDate: Date
        let olderDate: Date
        let sharedCount: Int
        let score: Double
    }

    private static func connectionCandidates(recent: [Eligible], older: [Eligible],
                                             frequency: [String: Double]) -> [ConnectionCandidate] {
        let olderIndex = index(older)
        var olderByID: [String: Eligible] = [:]
        for save in older { olderByID[save.id] = save }

        // A qualifying pair shares at least two allowed topics, at least one of them rare, so
        // only rare topics are worth walking. That alone is not a bound: in a library of
        // several hundred topics almost every topic sits under the rarity ceiling, and walking
        // those pairwise is quadratic. So the walk only counts co-occurrences, and anything
        // further happens on candidates that can still qualify — two shared rare topics is
        // already enough, one is enough only if the recent save also carries a common topic
        // the pair might share.
        var found: [ConnectionCandidate] = []
        for recentSave in recent {
            let allowed = recentSave.allowedTopics
            guard allowed.count >= Rules.minSharedTopics else { continue }
            let rare = allowed.filter { (frequency[$0] ?? 1) <= Rules.rarityCeiling }
            guard !rare.isEmpty else { continue }
            let mayShareCommonTopic = allowed.count > rare.count

            var sharedRareCount: [String: Int] = [:]
            for topic in rare {
                for olderSave in olderIndex[topic] ?? [] {
                    sharedRareCount[olderSave.id, default: 0] += 1
                }
            }

            for (olderID, rareCount) in sharedRareCount {
                guard rareCount >= Rules.minSharedTopics || mayShareCommonTopic else { continue }
                guard let olderSave = olderByID[olderID] else { continue }
                let shared = sharedSummary(allowed, olderSave.allowedTopics, frequency)
                guard shared.count >= Rules.minSharedTopics else { continue }
                found.append(ConnectionCandidate(
                    recentID: recentSave.id, olderID: olderSave.id,
                    recentDate: recentSave.date, olderDate: olderSave.date,
                    sharedCount: shared.count, score: shared.score))
            }
        }
        return found.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.sharedCount != b.sharedCount { return a.sharedCount > b.sharedCount }
            if a.recentDate != b.recentDate { return a.recentDate > b.recentDate }
            if a.olderDate != b.olderDate { return a.olderDate > b.olderDate }
            if a.recentID != b.recentID { return a.recentID < b.recentID }
            return a.olderID < b.olderID
        }
    }

    /// Walks two sorted topic lists together, counting what they share and summing rarity as
    /// it goes. Ascending order makes the sum independent of how the saves arrived. Returns a
    /// count rather than the topics themselves so the hot path allocates nothing.
    private static func sharedSummary(_ a: [String], _ b: [String],
                                      _ frequency: [String: Double]) -> (count: Int, score: Double) {
        var count = 0
        var score = 0.0
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                count += 1
                score += 1 / (frequency[a[i]] ?? 1)
                i += 1
                j += 1
            } else if a[i] < b[j] {
                i += 1
            } else {
                j += 1
            }
        }
        return (count, score)
    }

    /// Turns a ranked pair into the card the user reads. Only ever called for candidates that
    /// survive suppression and the no-shared-evidence rule.
    private static func makeConnection(_ candidate: ConnectionCandidate,
                                       recentByID: [String: Eligible],
                                       olderByID: [String: Eligible],
                                       spellings: [String: String],
                                       frequency: [String: Double]) -> Connection? {
        guard let recentSave = recentByID[candidate.recentID],
              let olderSave = olderByID[candidate.olderID] else { return nil }
        var shared: [String] = []
        var i = 0, j = 0
        let a = recentSave.allowedTopics, b = olderSave.allowedTopics
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                shared.append(a[i])
                i += 1
                j += 1
            } else if a[i] < b[j] {
                i += 1
            } else {
                j += 1
            }
        }
        // The card names the rarest two; ties break on the topic itself.
        let ranked = shared.sorted { x, y in
            let fx = frequency[x] ?? 1, fy = frequency[y] ?? 1
            return fx == fy ? x < y : fx < fy
        }
        return Connection(
            recentID: recentSave.id, olderID: olderSave.id,
            sharedTopics: ranked.prefix(2).map { spellings[$0] ?? $0 },
            sharedThemes: shared,
            recentDate: recentSave.date, olderDate: olderSave.date)
    }

    // MARK: - Returning interest

    private static func returningInterests(recent: [Eligible], older: [Eligible],
                                           spellings: [String: String]) -> [ReturningInterest] {
        let olderIndex = index(older)
        return index(recent).compactMap { topic, recentSaves -> ReturningInterest? in
            guard recentSaves.count >= Rules.minReturningRecent else { return nil }
            let history = newestFirst(olderIndex[topic] ?? [])
            guard history.count >= Rules.minReturningHistorical else { return nil }

            let ordered = newestFirst(recentSaves)
            // The recent window holds every save inside it, so the distance from the newest
            // save before it to the oldest save after it is an observed silence, not a guess.
            let resumed = ordered[ordered.count - 1].date
            let paused = history[0].date
            let gap = resumed.timeIntervalSince(paused)
            guard gap >= Rules.returningGap else { return nil }

            return ReturningInterest(
                theme: topic,
                displayTheme: spellings[topic] ?? topic,
                recentIDs: ordered.map(\.id),
                historicalIDs: history.prefix(2).map(\.id),
                recentCount: ordered.count,
                gapDays: Int((gap / 86400).rounded(.down)),
                firstRecentDate: resumed,
                lastRecentDate: ordered[0].date)
        }
        .sorted { a, b in
            if a.recentCount != b.recentCount { return a.recentCount > b.recentCount }
            if a.gapDays != b.gapDays { return a.gapDays > b.gapDays }
            if a.lastRecentDate != b.lastRecentDate { return a.lastRecentDate > b.lastRecentDate }
            return a.theme < b.theme
        }
    }

    // MARK: - Composition

    /// At most one card of each kind, never the same save twice. The return is reserved first:
    /// a topic that came back after months is a more specific story than the same topic simply
    /// being busy, and it would otherwise win both slots and be shown as neither.
    private static func compose(currents: [CurrentInterest],
                                returnings: [ReturningInterest],
                                connections: [ConnectionCandidate],
                                connectionCard: (ConnectionCandidate) -> Connection?,
                                allow: (Card) -> Bool) -> [Card] {
        let returning = returnings.first
        var used = Set(returning?.evidenceIDs ?? [])

        let current = currents.first {
            $0.theme != returning?.theme && Set($0.evidenceIDs).isDisjoint(with: used)
        }
        used.formUnion(current?.evidenceIDs ?? [])

        // Ranked pairs stay unbuilt until one is actually wanted, so a library with six
        // figures of candidates still only ever builds the card it shows.
        var connection: Connection?
        for candidate in connections {
            guard !used.contains(candidate.recentID), !used.contains(candidate.olderID),
                  let card = connectionCard(candidate), allow(.connection(card)) else { continue }
            connection = card
            break
        }

        return [current.map(Card.currentInterest), connection.map(Card.connection),
                returning.map(Card.returningInterest)].compactMap { $0 }
    }
}
