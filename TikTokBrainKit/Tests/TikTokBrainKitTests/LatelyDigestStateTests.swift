// LatelyDigestStateTests.swift
//
// Pins the stability half of the 2026-09-18 spec: a digest the user has seen must not rotate
// under them, a card they hid must stay hidden across restarts, and evidence that stops
// existing must stop being shown before anything else is considered. These are the rules that
// decide when the screen is allowed to change, so a regression here is felt as the surface
// being twitchy or as a hidden card coming back — both of which read as the app ignoring them.

import Foundation
import Testing
@testable import TikTokBrainKit

@Suite("Lately digest state")
struct LatelyDigestStateTests {

    let now = Date(timeIntervalSince1970: 1_780_000_000)

    func save(_ id: String, daysAgo: Double, _ topics: [String]) -> LatelySelector.Save {
        .init(id: id, date: now.addingTimeInterval(-daysAgo * 86400), topics: topics)
    }

    func interest(_ theme: String, _ ids: [String]) -> LatelySelector.Card {
        .currentInterest(.init(theme: theme, displayTheme: theme, evidenceIDs: ids,
                               saveCount: ids.count, firstDate: now, lastDate: now))
    }

    func returning(_ theme: String, recent: [String], historical: [String]) -> LatelySelector.Card {
        .returningInterest(.init(theme: theme, displayTheme: theme, recentIDs: recent,
                                 historicalIDs: historical, recentCount: recent.count,
                                 gapDays: 90, firstRecentDate: now, lastRecentDate: now))
    }

    func connection(_ recentID: String, _ olderID: String) -> LatelySelector.Card {
        .connection(.init(recentID: recentID, olderID: olderID, sharedTopics: ["a", "b"],
                          sharedThemes: ["a", "b"], recentDate: now, olderDate: now))
    }

    func snapshot(_ cards: [LatelySelector.Card],
                  fingerprint: String = "f1") -> LatelyDigestState.Snapshot {
        .init(anchor: now, generatedAt: now, rulesVersion: LatelySelector.Rules.rulesVersion,
              fingerprint: fingerprint, cards: cards)
    }

    // MARK: - Fingerprint

    @Test func theFingerprintIgnoresInputOrder() {
        let saves = [save("a", daysAgo: 1, ["linux"]), save("b", daysAgo: 2, ["cooking"])]
        #expect(LatelyDigestState.fingerprint(of: saves)
            == LatelyDigestState.fingerprint(of: saves.reversed()))
    }

    @Test func theFingerprintIsAStableHexDigestNotAProcessHash() {
        // Swift's Hasher is seeded per process, so a digest built on it would appear to change
        // on every launch and rebuild a digest the user had already settled into.
        let value = LatelyDigestState.fingerprint(of: [save("a", daysAgo: 1, ["linux"])])
        #expect(value.count == 64)
        #expect(value.allSatisfy { $0.isHexDigit })
    }

    @Test func everySelectionRelevantFieldMovesTheFingerprint() {
        let base = [save("a", daysAgo: 1, ["linux"])]
        let original = LatelyDigestState.fingerprint(of: base)
        #expect(LatelyDigestState.fingerprint(of: [save("a", daysAgo: 2, ["linux"])]) != original)
        #expect(LatelyDigestState.fingerprint(of: [save("b", daysAgo: 1, ["linux"])]) != original)
        #expect(LatelyDigestState.fingerprint(of: [save("a", daysAgo: 1, ["cooking"])]) != original)
    }

    @Test func aTopicRespellingDoesNotMoveTheFingerprint() {
        // The fingerprint tracks what selection reads, and selection reads normalized topics.
        let original = LatelyDigestState.fingerprint(of: [save("a", daysAgo: 1, ["AI  Agents"])])
        #expect(LatelyDigestState.fingerprint(of: [save("a", daysAgo: 1, ["ai agents"])]) == original)
    }

    // MARK: - Dismissal

    @Test func hidingACardSuppressesItsExactSignature() {
        let card = interest("linux", ["a", "b", "c"])
        let state = LatelyDigestState().dismissing(card, at: now)
        #expect(state.isSuppressed(card))
    }

    @Test func hidingAThemeSuppressesBothOfItsKinds() {
        // One key per topic: hiding "linux" as a current interest must not leave the same
        // topic free to come back as a return a moment later.
        let state = LatelyDigestState().dismissing(interest("linux", ["a", "b", "c"]), at: now)
        #expect(state.isSuppressed(returning("linux", recent: ["a", "b", "c"],
                                             historical: ["h1", "h2"])))
    }

    @Test func aDismissedThemeSurvivesARoundTrip() throws {
        let state = LatelyDigestState().dismissing(interest("linux", ["a", "b", "c"]), at: now)
        let restored = try JSONDecoder().decode(
            LatelyDigestState.self, from: JSONEncoder().encode(state))
        #expect(restored.isSuppressed(interest("linux", ["a", "b", "c"])))
    }

    @Test func threeUnseenRecentSavesBringADismissedThemeBack() {
        let state = LatelyDigestState().dismissing(interest("linux", ["a", "b", "c"]), at: now)
        #expect(state.isSuppressed(interest("linux", ["a", "b", "c", "d", "e"])))
        #expect(state.isSuppressed(interest("linux", ["a", "b", "c", "d", "e", "f"])) == false)
    }

    @Test func losingEvidenceNeverResurrectsADismissedTheme() {
        let state = LatelyDigestState().dismissing(
            interest("linux", ["a", "b", "c", "d"]), at: now)
        #expect(state.isSuppressed(interest("linux", ["a", "b", "c"])))
    }

    @Test func aRelabelledThemeStaysDismissed() {
        // Display spelling is not identity. Only the normalized topic is.
        let state = LatelyDigestState().dismissing(interest("linux", ["a", "b", "c"]), at: now)
        let respelled = LatelySelector.Card.currentInterest(
            .init(theme: "linux", displayTheme: "Linux", evidenceIDs: ["a", "b", "c"],
                  saveCount: 3, firstDate: now, lastDate: now))
        #expect(state.isSuppressed(respelled))
    }

    @Test func onlyRecentEvidenceCountsTowardsAThemesReturn() {
        // A return card carries history as evidence. History the user already dismissed
        // around cannot be what earns the theme its way back onto the screen.
        let state = LatelyDigestState().dismissing(
            returning("linux", recent: ["r1", "r2", "r3"], historical: ["h1", "h2"]), at: now)
        let withNewHistory = returning("linux", recent: ["r1", "r2", "r3"],
                                       historical: ["h3", "h4", "h5"])
        #expect(state.isSuppressed(withNewHistory))
        let withNewRecents = returning("linux", recent: ["r1", "r4", "r5", "r6"],
                                       historical: ["h1", "h2"])
        #expect(state.isSuppressed(withNewRecents) == false)
    }

    @Test func aConnectionStaysHiddenWhicheverWayThePairIsOrdered() {
        let state = LatelyDigestState().dismissing(connection("new", "old"), at: now)
        #expect(state.isSuppressed(connection("new", "old")))
        #expect(state.isSuppressed(connection("old", "new")))
    }

    @Test func undoRestoresACardImmediately() {
        let card = interest("linux", ["a", "b", "c"])
        let state = LatelyDigestState().dismissing(card, at: now)
        #expect(state.undoingDismissal(of: card).isSuppressed(card) == false)
    }

    @Test func suppressionIsWiredIntoSelectionNotAppliedAfterwards() {
        // The end-to-end shape: hiding the winner promotes the runner-up in the same pass.
        let saves = (0..<4).map { save("c\($0)", daysAgo: Double($0) + 1, ["cooking"]) }
            + (0..<3).map { save("l\($0)", daysAgo: Double($0) + 1, ["linux"]) }
        let hidden = LatelyDigestState().dismissing(
            interest("cooking", ["c0", "c1", "c2", "c3"]), at: now)
        let digest = LatelySelector.digest(saves, now: now) { !hidden.isSuppressed($0) }
        #expect(digest?.cards.first?.themeKey == "linux")
    }

    // MARK: - Refresh decisions

    @Test func anUnchangedFingerprintChangesNothing() {
        let current = snapshot([interest("linux", ["a", "b", "c"])])
        #expect(LatelyDigestState.decide(current: current, proposed: current,
                                         isVisible: true, hasPublishedDigest: true) == .none)
    }

    @Test func aChangeOffScreenIsAcceptedWithoutAsking() {
        let current = snapshot([interest("linux", ["a", "b", "c"])])
        let proposed = snapshot([interest("cooking", ["x", "y", "z"])], fingerprint: "f2")
        #expect(LatelyDigestState.decide(current: current, proposed: proposed,
                                         isVisible: false, hasPublishedDigest: true) == .install)
    }

    @Test func aChangeUnderTheUsersEyesIsOfferedNotImposed() {
        let current = snapshot([interest("linux", ["a", "b", "c"])])
        let proposed = snapshot([interest("cooking", ["x", "y", "z"])], fingerprint: "f2")
        #expect(LatelyDigestState.decide(current: current, proposed: proposed,
                                         isVisible: true, hasPublishedDigest: true) == .offer)
    }

    @Test func theFirstDigestEverAppearsOnItsOwn() {
        let proposed = snapshot([interest("linux", ["a", "b", "c"])], fingerprint: "f2")
        #expect(LatelyDigestState.decide(current: nil, proposed: proposed,
                                         isVisible: true, hasPublishedDigest: false) == .install)
    }

    @Test func anAllDismissedDigestIsNotAFirstDigest() {
        // The user cleared the screen deliberately. Refilling it without asking would undo
        // that, so this case gets the explicit control instead.
        let proposed = snapshot([interest("linux", ["a", "b", "c"])], fingerprint: "f2")
        #expect(LatelyDigestState.decide(current: snapshot([]), proposed: proposed,
                                         isVisible: true, hasPublishedDigest: true) == .offer)
    }

    @Test func correctedFactsBehindIdenticalCardsLandWithoutAButton() {
        // Same stories, same evidence, different counts or dates: nothing for the user to
        // choose between, and leaving the stale number on screen would be a false claim.
        let current = snapshot([interest("linux", ["a", "b", "c"])])
        let corrected = LatelySelector.Card.currentInterest(
            .init(theme: "linux", displayTheme: "Linux", evidenceIDs: ["a", "b", "c"],
                  saveCount: 3, firstDate: now.addingTimeInterval(-86400), lastDate: now))
        let proposed = snapshot([corrected], fingerprint: "f2")
        #expect(LatelyDigestState.decide(current: current, proposed: proposed,
                                         isVisible: true, hasPublishedDigest: true)
            == .updateInPlace)
    }

    // MARK: - Evidence that stops existing

    @Test func deletedEvidenceLeavesTheCardButNotTheBrokenLink() {
        let current = snapshot([interest("linux", ["a", "b", "c", "d"])])
        let safe = current.revalidated(against: ["a", "b", "c"])
        if case let .currentInterest(card) = safe.cards.first {
            #expect(card.evidenceIDs == ["a", "b", "c"])
            #expect(card.saveCount == 3)
        } else {
            Issue.record("expected the card to survive with its remaining evidence")
        }
    }

    @Test func aCardFallingBelowItsThresholdIsRemovedNotShrunk() {
        let current = snapshot([interest("linux", ["a", "b", "c"])])
        #expect(current.revalidated(against: ["a", "b"]).cards.isEmpty)
    }

    @Test func aConnectionNeedsBothOfItsSaves() {
        let current = snapshot([connection("new", "old")])
        #expect(current.revalidated(against: ["new", "old"]).cards.count == 1)
        #expect(current.revalidated(against: ["new"]).cards.isEmpty)
    }

    @Test func aReturnLosingItsHistoryIsNoLongerAReturn() {
        let card = returning("linux", recent: ["r1", "r2", "r3"], historical: ["h1", "h2"])
        let current = snapshot([card])
        #expect(current.revalidated(against: ["r1", "r2", "r3", "h1", "h2"]).cards.count == 1)
        #expect(current.revalidated(against: ["r1", "r2", "r3", "h1"]).cards.isEmpty)
    }

    // MARK: - Account boundary

    @Test func storedStateRoundTripsForItsOwner() throws {
        let state = LatelyDigestState().dismissing(interest("linux", ["a", "b", "c"]), at: now)
        let data = try state.encoded(owner: "user-1")
        #expect(LatelyDigestState.decode(data, expecting: "user-1") == state)
    }

    @Test func oneAccountsDigestNeverLoadsIntoAnothersView() throws {
        // The filename scopes it, but a file can be restored from a backup or left behind by
        // a crash. Describing one person's saves to another is the failure that matters.
        let state = LatelyDigestState().dismissing(interest("linux", ["a", "b", "c"]), at: now)
        let data = try state.encoded(owner: "user-1")
        #expect(LatelyDigestState.decode(data, expecting: "user-2") == nil)
    }

    @Test func corruptOrUnknownStateFallsBackToRegenerating() throws {
        #expect(LatelyDigestState.decode(Data("not json".utf8), expecting: "user-1") == nil)
        var future = LatelyDigestState()
        future.version = LatelyDigestState.stateVersion + 1
        let data = try future.encoded(owner: "user-1")
        #expect(LatelyDigestState.decode(data, expecting: "user-1") == nil)
    }

    @Test func eachAccountGetsItsOwnFilesystemSafeFilename() {
        let one = LatelyDigestState.filename(for: "user-1")
        #expect(one != LatelyDigestState.filename(for: "user-2"))
        #expect(one == LatelyDigestState.filename(for: "user-1"))
        #expect(one.contains("user-1") == false)
        #expect(one.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." })
    }

    @Test func revalidationLeavesAnIntactDigestUntouched() {
        let current = snapshot([interest("linux", ["a", "b", "c"]), connection("new", "old")])
        #expect(current.revalidated(against: ["a", "b", "c", "new", "old"]) == current)
    }
}
