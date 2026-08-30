// RecentsSelector.swift
//
// The Recents tab's brain: which saves count as "recent", which of them arrived together as
// a thread, and which one old save gets resurfaced. Measured on the real 855-save library,
// saving is streaky — median 1 day between active days, p90 five, max 32 — so a fixed
// calendar window is either empty or overflowing depending on the month. The rule here is
// count-based and time-clamped instead: the window reaches back to the 8th-newest save,
// never less than 3 days, never more than 30, and it anchors on the newest save rather than
// on the clock so a quiet month doesn't blank the screen. The header label stays honest
// ("Since Jun 29"), never "Today".
//
// Threads exist because 44% of that library's 3+ save bursts share one topic (ai agents ×3
// in a day, linux ×4, cooking ×6). A session is saves less than 4 hours apart; it becomes a
// thread when it has 3+ members and its most common topic covers at least half of them.
//
// Derived, never stored — same contract as SaveIntent: a pure function of dates and topics,
// so the rules can move without a migration. Full derivation:
// docs/superpowers/specs/2026-08-30-recents-interest-mining-and-today-redesign.md

import Foundation

public enum RecentsSelector {

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

    public struct Thread: Sendable, Equatable {
        /// The session's most common topic, as the analyzer wrote it (short lowercase keyword).
        public let theme: String
        /// Members, newest first.
        public let saveIDs: [String]
    }

    public struct Board: Sendable, Equatable {
        /// Oldest save inside the window — the "Since Jun 29" of the header.
        public let windowStart: Date
        /// Saves on the board (hero + threads + loose), for the "8 saves" subtitle.
        public let saveCount: Int
        /// The newest window save, but only when it is loose — a thread leads otherwise.
        public let heroID: String?
        /// Newest thread first.
        public let threads: [Thread]
        /// Window saves in no thread, newest first, hero excluded.
        public let looseIDs: [String]
        /// One older save worth returning to; nil until the library has a past.
        public let resurfaceID: String?
    }

    static let targetCount = 8
    static let displayCap = 12
    static let minSpan: TimeInterval = 3 * 86400
    static let maxSpan: TimeInterval = 30 * 86400
    static let sessionGap: TimeInterval = 4 * 3600
    static let resurfaceAge: TimeInterval = 60 * 86400

    public static func board(_ saves: [Save], now: Date = Date()) -> Board? {
        guard !saves.isEmpty else { return nil }
        let sorted = saves.sorted { $0.date > $1.date }
        let anchor = sorted[0].date

        // Reach back to the 8th-newest save (or the oldest, in a small library), clamped.
        let reach = sorted[min(targetCount, sorted.count) - 1].date
        let span = min(max(anchor.timeIntervalSince(reach), minSpan), maxSpan)
        let window = Array(sorted.prefix(while: { anchor.timeIntervalSince($0.date) <= span })
            .prefix(displayCap))

        // Sessions: walk newest→oldest, split on a 4h+ gap, keep the thematic 3+ ones.
        var threads: [Thread] = []
        var threaded = Set<String>()
        var session: [Save] = []
        func closeSession() {
            defer { session = [] }
            guard session.count >= 3 else { return }
            let counts = session.flatMap { Set($0.topics.map { $0.lowercased() }) }
                .reduce(into: [:]) { $0[$1, default: 0] += 1 }
            guard let (theme, hits) = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
                  hits >= max(2, session.count / 2) else { return }
            threads.append(Thread(theme: theme, saveIDs: session.map(\.id)))
            threaded.formUnion(session.map(\.id))
        }
        for save in window {
            if let last = session.last, last.date.timeIntervalSince(save.date) >= sessionGap {
                closeSession()
            }
            session.append(save)
        }
        closeSession()

        var loose = window.filter { !threaded.contains($0.id) }.map(\.id)
        let hero = loose.first == window.first?.id ? loose.first : nil
        if hero != nil { loose.removeFirst() }

        return Board(
            windowStart: window.last?.date ?? anchor,
            saveCount: window.count,
            heroID: hero,
            threads: threads,
            looseIDs: loose,
            resurfaceID: resurface(from: sorted, anchor: anchor, window: window, now: now))
    }

    /// One save at least 60 days older than the window, preferring one that shares a topic
    /// with it, rotated deterministically by calendar day — same promise as the old Today
    /// rotation, shrunk to a single closing card.
    private static func resurface(from sorted: [Save], anchor: Date,
                                  window: [Save], now: Date) -> String? {
        let old = sorted.filter { anchor.timeIntervalSince($0.date) >= resurfaceAge }
        guard !old.isEmpty else { return nil }
        let windowTopics = Set(window.flatMap { $0.topics.map { $0.lowercased() } })
        let related = old.filter { !windowTopics.isDisjoint(with: $0.topics.map { $0.lowercased() }) }
        let pool = related.isEmpty ? old : related
        let day = Calendar.current.ordinality(of: .day, in: .era, for: now) ?? 0
        return pool[day % pool.count].id
    }
}
