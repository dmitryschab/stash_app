// LatelyDigestState.swift
//
// When Lately is allowed to change, and what stays hidden after the user hides it.
//
// The selector decides what is true; this decides what the user sees and when. Those are
// different jobs. A digest recomputed in a SwiftUI body would reshuffle while being read, and
// a screen that rearranges itself under a finger reads as the app fidgeting rather than as new
// information. So the digest is a snapshot: built once, kept until the input behind it actually
// changes, and replaced only through one of the decisions below.
//
// Two rules outrank stability. Evidence that no longer exists is removed at once — a card
// linking to a deleted save is a broken promise, not a stale one. And a card the user hid stays
// hidden: not until the next launch, not until the ranking shifts, but until there is genuinely
// new evidence they have not already turned down.
//
// Everything here is pure. Disk, debouncing and the account boundary live in the app's
// LatelyStore. Spec: docs/superpowers/specs/2026-09-18-lately-technical-spec.md §6–7.

import CryptoKit
import Foundation

public struct LatelyDigestState: Codable, Sendable, Equatable {

    /// Bumped when this document's shape changes. Unreadable state regenerates rather than
    /// migrating: the digest is derived data, so losing it costs one recomputation.
    public static let stateVersion = 1

    public var version: Int
    public var snapshot: Snapshot?
    public var dismissals: [Dismissal]
    /// Whether a nonempty digest has ever reached the screen for this account. An empty digest
    /// the user emptied themselves is not the same as never having had one.
    public var hasPublishedDigest: Bool

    public init(version: Int = LatelyDigestState.stateVersion,
                snapshot: Snapshot? = nil,
                dismissals: [Dismissal] = [],
                hasPublishedDigest: Bool = false) {
        self.version = version
        self.snapshot = snapshot
        self.dismissals = dismissals
        self.hasPublishedDigest = hasPublishedDigest
    }

    // MARK: - Snapshot

    public struct Snapshot: Codable, Sendable, Equatable {
        /// The newest save at build time. Wording keeps using this while the snapshot stands,
        /// so saves arriving behind a frozen digest cannot make old stories read as current.
        public let anchor: Date
        public let generatedAt: Date
        public let rulesVersion: Int
        /// Digest of every selection-relevant field of the input this was built from.
        public let fingerprint: String
        public let cards: [LatelySelector.Card]

        public init(anchor: Date, generatedAt: Date, rulesVersion: Int,
                    fingerprint: String, cards: [LatelySelector.Card]) {
            self.anchor = anchor
            self.generatedAt = generatedAt
            self.rulesVersion = rulesVersion
            self.fingerprint = fingerprint
            self.cards = cards
        }

        public var signatures: [String] { cards.map(\.signature) }

        /// The window this digest describes, measured from its own anchor. Saves arriving
        /// behind a published snapshot must not silently widen the period it claims.
        public var recentStart: Date {
            anchor.addingTimeInterval(-LatelySelector.Rules.recentWindow)
        }

        /// Nothing has been saved for longer than a window, so the copy speaks in the past.
        /// Read from the captured anchor, so time passing changes the wording and never the
        /// stories.
        public func isHistorical(at now: Date) -> Bool {
            now.timeIntervalSince(anchor) > LatelySelector.Rules.recentWindow
        }

        /// Drops evidence that no longer exists and removes any card that stops qualifying.
        /// Deliberately does not recompute dates: this runs the instant a save is deleted, to
        /// close the broken link, and a full recomputation from live saves follows it.
        public func revalidated(against available: Set<String>) -> Snapshot {
            Snapshot(anchor: anchor, generatedAt: generatedAt, rulesVersion: rulesVersion,
                     fingerprint: fingerprint,
                     cards: cards.compactMap { $0.revalidated(against: available) })
        }
    }

    // MARK: - Dismissal

    public struct Dismissal: Codable, Sendable, Equatable {
        /// What the user hid. Stored separately from a card's versioned signature so that a
        /// rules change cannot quietly revive something they turned down.
        public enum Subject: Codable, Sendable, Equatable, Hashable {
            /// One key per normalized topic, covering both topic-shaped kinds.
            case theme(String)
            /// The two save IDs, always sorted, so either ordering matches.
            case pair(String, String)
        }

        public let subject: Subject
        /// What the card was showing when it was hidden — the baseline new evidence is
        /// measured against.
        public let evidenceIDs: [String]
        public let dismissedAt: Date

        public init(subject: Subject, evidenceIDs: [String], dismissedAt: Date) {
            self.subject = subject
            self.evidenceIDs = evidenceIDs
            self.dismissedAt = dismissedAt
        }
    }

    /// Records a dismissal, replacing any earlier one for the same subject so "most recently
    /// dismissed evidence" stays unambiguous.
    public func dismissing(_ card: LatelySelector.Card, at date: Date) -> LatelyDigestState {
        let subject = LatelyDigestState.subject(of: card)
        var copy = self
        copy.dismissals.removeAll { $0.subject == subject }
        copy.dismissals.append(Dismissal(subject: subject,
                                         evidenceIDs: LatelyDigestState.recentEvidence(of: card),
                                         dismissedAt: date))
        return copy
    }

    public func undoingDismissal(of card: LatelySelector.Card) -> LatelyDigestState {
        let subject = LatelyDigestState.subject(of: card)
        var copy = self
        copy.dismissals.removeAll { $0.subject == subject }
        return copy
    }

    /// Whether a proposed card is still hidden. A theme comes back only on genuinely new
    /// recent evidence; losing evidence, being respelled, or a rules bump never counts.
    public func isSuppressed(_ card: LatelySelector.Card) -> Bool {
        let subject = LatelyDigestState.subject(of: card)
        guard let dismissal = dismissals.last(where: { $0.subject == subject }) else {
            return false
        }
        // A pair is one specific juxtaposition; there is no larger version of it to earn its
        // way back, so hiding one hides it for good.
        guard case .theme = subject else { return true }
        let alreadySeen = Set(dismissal.evidenceIDs)
        let unseen = LatelyDigestState.recentEvidence(of: card).filter { !alreadySeen.contains($0) }
        return unseen.count < LatelySelector.Rules.minCurrentSaves
    }

    private static func subject(of card: LatelySelector.Card) -> Dismissal.Subject {
        switch card {
        case let .currentInterest(interest): .theme(interest.theme)
        case let .returningInterest(returning): .theme(returning.theme)
        case let .connection(connection):
            {
                let sorted = [connection.recentID, connection.olderID].sorted()
                return .pair(sorted[0], sorted[1])
            }()
        }
    }

    /// Evidence from inside the recent window only. A return card also carries history, but
    /// history is what the user was already shown when they hid it.
    private static func recentEvidence(of card: LatelySelector.Card) -> [String] {
        switch card {
        case let .currentInterest(interest): interest.evidenceIDs
        case let .returningInterest(returning): returning.recentIDs
        case let .connection(connection): connection.evidenceIDs
        }
    }

    // MARK: - Refresh decisions

    public enum RefreshDecision: Sendable, Equatable {
        /// The input behind the digest has not moved.
        case none
        /// Take the proposal now: nobody is looking, or there is nothing to disturb.
        case install
        /// Offer it behind a control; the user chooses when the screen changes.
        case offer
        /// Same stories, same evidence, corrected facts. Nothing to choose between, and the
        /// stale numbers would be untrue.
        case updateInPlace
    }

    public static func decide(current: Snapshot?, proposed: Snapshot,
                              isVisible: Bool, hasPublishedDigest: Bool) -> RefreshDecision {
        if current?.fingerprint == proposed.fingerprint { return .none }
        guard isVisible else { return .install }

        guard let current, !current.cards.isEmpty else {
            // Nothing on screen to protect — unless the screen is empty because the user
            // emptied it, which is a state they chose and we do not undo for them.
            return hasPublishedDigest ? .offer : .install
        }
        return current.signatures == proposed.signatures ? .updateInPlace : .offer
    }

    // MARK: - Account-scoped storage

    /// The state as it sits on disk, owner and all. The filename already scopes it, but a file
    /// is a thing that can be restored, copied between devices or left behind by a crash, and
    /// one account's saves must never be described to another account's user. So the owner is
    /// written inside the document too, and both have to agree before any of it is read.
    public struct Envelope: Codable, Sendable, Equatable {
        public let owner: String
        public let state: LatelyDigestState

        public init(owner: String, state: LatelyDigestState) {
            self.owner = owner
            self.state = state
        }
    }

    /// A filesystem-safe filename for an account. The user ID is hashed rather than used
    /// directly: it is an account identifier, and Application Support is not the place to
    /// leave a list of them lying around in plain sight.
    public static func filename(for userID: String) -> String {
        let digest = SHA256.hash(data: Data(userID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "Lately-\(digest).json"
    }

    /// Reads stored state, or nil when there is nothing safe to use: unreadable bytes, a
    /// version this build does not know, or a document belonging to someone else. Every one of
    /// those falls back to regenerating from the live library, which costs one recomputation.
    public static func decode(_ data: Data, expecting owner: String) -> LatelyDigestState? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.owner == owner,
              envelope.state.version == stateVersion else { return nil }
        return envelope.state
    }

    public func encoded(owner: String) throws -> Data {
        try JSONEncoder().encode(Envelope(owner: owner, state: self))
    }

    // MARK: - Fingerprint

    /// A stable digest of everything selection reads: IDs, dates and normalized topics. SHA-256
    /// over a canonical sorted encoding, never Swift's `Hasher` — that is seeded per process,
    /// so a digest built on it would look different on every launch and rebuild a digest the
    /// user had already settled into.
    public static func fingerprint(of saves: [LatelySelector.Save]) -> String {
        let lines = saves.map { save -> String in
            let topics = Set(save.topics.compactMap(canonicalTopic)).sorted()
            return "\(save.id)|\(save.date.timeIntervalSince1970)|\(topics.joined(separator: ","))"
        }
        let canonical = lines.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Mirrors the selector's normalization so a respelling the selector ignores does not read
    /// as a change worth rebuilding for.
    private static func canonicalTopic(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed.lowercased()
    }
}

// MARK: - Card revalidation

private extension LatelySelector.Card {
    /// The card with vanished evidence removed, or nil when too little is left to support the
    /// claim it makes.
    func revalidated(against available: Set<String>) -> LatelySelector.Card? {
        switch self {
        case let .currentInterest(interest):
            let kept = interest.evidenceIDs.filter(available.contains)
            guard kept.count >= LatelySelector.Rules.minCurrentSaves else { return nil }
            return .currentInterest(.init(
                theme: interest.theme, displayTheme: interest.displayTheme, evidenceIDs: kept,
                saveCount: kept.count, firstDate: interest.firstDate,
                lastDate: interest.lastDate))

        case let .connection(connection):
            // A connection is the two saves. Either one going means there is no pair left.
            guard available.contains(connection.recentID),
                  available.contains(connection.olderID) else { return nil }
            return self

        case let .returningInterest(returning):
            let recent = returning.recentIDs.filter(available.contains)
            let history = returning.historicalIDs.filter(available.contains)
            guard recent.count >= LatelySelector.Rules.minReturningRecent,
                  history.count >= LatelySelector.Rules.minReturningHistorical else { return nil }
            return .returningInterest(.init(
                theme: returning.theme, displayTheme: returning.displayTheme, recentIDs: recent,
                historicalIDs: history, recentCount: recent.count, gapDays: returning.gapDays,
                firstRecentDate: returning.firstRecentDate,
                lastRecentDate: returning.lastRecentDate))
        }
    }
}
