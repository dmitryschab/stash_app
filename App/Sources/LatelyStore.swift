// LatelyStore.swift
//
// The app side of Lately: whose digest this is, when it may be rebuilt, and where it lives on
// disk. The rules themselves are in the Kit (LatelySelector, LatelyDigestState) — this file
// holds none of them, so a threshold can never drift between what is tested and what ships.
//
// Three things it exists to get right:
//
// Ownership. A digest describes the user's own saves back to them, so the file is named by a
// hash of the account and carries the owner inside as well. Both have to agree before a byte
// of it is read. Signing out drops it from memory but leaves it on disk, matching what the
// library already does for a returning user; deleting the account removes it.
//
// Timing. Imports write in bursts. Rebuilding on every write would rearrange the screen while
// it is being read, so input is debounced and the work happens off the main actor, with any
// result belonging to an older revision or a previous account thrown away.
//
// Safety over stability. Everything else here defends a published digest from changing. The
// exception is evidence that no longer exists: that is removed the moment it goes, before the
// debounce, because a card linking to a deleted save is a broken promise rather than a stale
// one. Spec: docs/superpowers/specs/2026-09-18-lately-technical-spec.md §6–7.

import Foundation
import Observation
import TikTokBrainKit

@MainActor @Observable
final class LatelyStore {
    static let shared = LatelyStore()

    /// What is on screen. Nil until the first digest is built for this account.
    private(set) var snapshot: LatelyDigestState.Snapshot?
    /// A newer digest is waiting behind the "New connections" control.
    private(set) var hasProposal = false
    /// The card just hidden, for as long as Undo is offered.
    private(set) var undoable: LatelySelector.Card?

    /// Whether Lately is the tab being looked at. A change nobody is watching is installed
    /// silently; a change under the user's eyes is offered instead.
    var isVisible = false

    private var state = LatelyDigestState()
    private var owner: String?
    private var proposal: LatelyDigestState.Snapshot?
    private var revision = 0
    private var debounce: Task<Void, Never>?

    /// How long a burst of import writes is allowed to settle before anything is recomputed.
    private static let debounceInterval: Duration = .seconds(2)

    private init() {}

    // MARK: - Account lifecycle

    /// Points the store at an account, or at nobody. Called whenever `StashSession.userID`
    /// changes, including the sign-out that sets it to nil.
    func adopt(userID: String?) {
        guard userID != owner else { return }
        debounce?.cancel()
        debounce = nil
        // Bumping the revision orphans any computation still running for the old account, so
        // its result cannot land in the new one's view.
        revision += 1
        snapshot = nil
        proposal = nil
        hasProposal = false
        undoable = nil
        state = LatelyDigestState()
        owner = userID

        guard let userID, let url = Self.url(for: userID),
              let data = try? Data(contentsOf: url),
              let stored = LatelyDigestState.decode(data, expecting: userID) else { return }
        state = stored
        snapshot = stored.snapshot
    }

    /// Removes an account's digest from disk. Used when the account is deleted and when a
    /// different user signs in on the same device — the same moments the library is dropped.
    nonisolated static func discardState(for userID: String) {
        guard let url = url(for: userID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Input

    /// Hands the store the eligible saves. Safe to call on every SwiftData change: unsafe
    /// evidence is dropped at once, and the expensive part is debounced.
    func observe(_ saves: [LatelySelector.Save], now: Date = Date()) {
        guard owner != nil else { return }
        revalidate(against: Set(saves.map(\.id)))

        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            await self?.rebuild(saves, now: now)
        }
    }

    /// Drops evidence whose save has gone and removes any card that no longer qualifies. Runs
    /// synchronously so no frame is ever drawn with a link to something deleted.
    private func revalidate(against available: Set<String>) {
        guard let current = snapshot else { return }
        let safe = current.revalidated(against: available)
        guard safe != current else { return }
        snapshot = safe
        state.snapshot = safe
        persist()
    }

    private func rebuild(_ saves: [LatelySelector.Save], now: Date) async {
        revision += 1
        let mine = revision
        let account = owner
        let suppression = state

        let proposed = await Task.detached(priority: .utility) { () -> LatelyDigestState.Snapshot? in
            guard let digest = LatelySelector.digest(saves, now: now, allow: {
                !suppression.isSuppressed($0)
            }) else { return nil }
            return LatelyDigestState.Snapshot(
                anchor: digest.anchor, generatedAt: now,
                rulesVersion: LatelySelector.Rules.rulesVersion,
                fingerprint: LatelyDigestState.fingerprint(of: saves), cards: digest.cards)
        }.value

        // A result from an older input revision, or from the account that was signed in when
        // the work started, describes saves that are no longer the ones on screen.
        guard revision == mine, owner == account, let proposed else { return }

        switch LatelyDigestState.decide(current: snapshot, proposed: proposed,
                                        isVisible: isVisible,
                                        hasPublishedDigest: state.hasPublishedDigest) {
        case .none:
            break
        case .install, .updateInPlace:
            // Identical cards with corrected counts are installed without a control: there is
            // nothing for the user to choose between, and the old numbers are simply untrue.
            install(proposed)
        case .offer:
            proposal = proposed
            hasProposal = true
        }
    }

    // MARK: - User actions

    /// Takes the waiting digest. One atomic swap, never a card at a time.
    func acceptProposal() {
        guard let proposal else { return }
        install(proposal)
    }

    /// Hides a card from Lately. It does not delete, archive or edit anything saved, and the
    /// freed slot stays empty until the next rebuild rather than refilling under the finger.
    func hide(_ card: LatelySelector.Card) {
        guard let current = snapshot else { return }
        state = state.dismissing(card, at: Date())
        undoable = card
        let remaining = current.cards.filter { $0.signature != card.signature }
        install(LatelyDigestState.Snapshot(
            anchor: current.anchor, generatedAt: current.generatedAt,
            rulesVersion: current.rulesVersion, fingerprint: current.fingerprint,
            cards: remaining))
    }

    func undoHide() {
        guard let card = undoable, let current = snapshot else { return }
        state = state.undoingDismissal(of: card)
        undoable = nil
        // Back into display order rather than onto the end, so the screen returns to exactly
        // what it looked like.
        var cards = current.cards
        let position = cards.firstIndex { order($0) > order(card) } ?? cards.count
        cards.insert(card, at: position)
        install(LatelyDigestState.Snapshot(
            anchor: current.anchor, generatedAt: current.generatedAt,
            rulesVersion: current.rulesVersion, fingerprint: current.fingerprint, cards: cards))
    }

    func clearUndo() { undoable = nil }

    private func order(_ card: LatelySelector.Card) -> Int {
        switch card.kind {
        case .currentInterest: 0
        case .connection: 1
        case .returningInterest: 2
        }
    }

    // MARK: - Export

    /// The current owner's Lately state for the account export, versioned so a future reader
    /// knows what shape it is. Only ever this account's — the export is one user's data — and
    /// no media, titles or transcripts, which the export already carries once under `device`.
    var exportPayload: [String: Any]? {
        guard owner != nil,
              let data = try? JSONEncoder().encode(state),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return ["stateVersion": LatelyDigestState.stateVersion,
                "rulesVersion": LatelySelector.Rules.rulesVersion,
                "state": object]
    }

    // MARK: - Persistence

    private func install(_ proposed: LatelyDigestState.Snapshot) {
        snapshot = proposed
        proposal = nil
        hasProposal = false
        state.snapshot = proposed
        // An empty digest is not a published one: a user who hid everything has not been shown
        // a digest they can be left alone with, and should get the explicit control instead.
        if !proposed.cards.isEmpty { state.hasPublishedDigest = true }
        persist()
    }

    /// Best effort by design. A digest is derived data, so a failed write costs a recomputation
    /// on next launch — not a reason to keep it off the screen now.
    private func persist() {
        guard let owner, let url = Self.url(for: owner),
              let data = try? state.encoded(owner: owner) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private nonisolated static func url(for userID: String) -> URL? {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return directory.appendingPathComponent(LatelyDigestState.filename(for: userID))
    }
}
