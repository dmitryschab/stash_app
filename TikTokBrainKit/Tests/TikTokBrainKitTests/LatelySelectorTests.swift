// LatelySelectorTests.swift
//
// Pins the Lately rules from the 2026-09-18 spec. Lately makes claims about the user's own
// collection ("5 saves about AI agents", "4 saves after 72 days"), so every number on screen
// has to be reconstructable from the evidence behind it. These tests exist to stop a threshold
// drifting quietly and turning an honest claim into an invented one.
//
// Every case uses an injected clock and a hand-built fixture: the rules must never depend on a
// developer's personal library. Dates are exact 86,400-second days, matching the selector.

import Foundation
import Testing
@testable import TikTokBrainKit

@Suite("Lately selector")
struct LatelySelectorTests {

    let now = Date(timeIntervalSince1970: 1_780_000_000)

    func save(_ id: String, daysAgo: Double, _ topics: [String] = ["placeholder"])
        -> LatelySelector.Save {
        .init(id: id, date: now.addingTimeInterval(-daysAgo * 86400), topics: topics)
    }

    func digest(_ saves: [LatelySelector.Save], at when: Date? = nil) -> LatelySelector.Digest? {
        LatelySelector.digest(saves, now: when ?? now)
    }

    // MARK: - Eligibility

    @Test func anEmptyLibraryHasNoDigest() {
        #expect(digest([]) == nil)
    }

    @Test func savesWithoutATopicAreNotEvidence() {
        // A save still in the pipeline has no topics yet. It cannot support a claim, so it is
        // not eligible input at all — not merely unranked.
        let saves = [save("a", daysAgo: 0, []), save("b", daysAgo: 1, ["  ", ""])]
        #expect(digest(saves) == nil)
    }

    @Test func savesDatedAfterTheClockAreIgnored() {
        let saves = [save("future", daysAgo: -5, ["ai"]), save("real", daysAgo: 1, ["ai"])]
        #expect(digest(saves)?.anchor == saves[1].date)
    }

    @Test func duplicateIDsCollapseToTheNewestRecord() {
        // Defensive: storage should already hold one record per video. If it does not, the
        // count on the card must not double-count the same save.
        let saves = [
            save("dup", daysAgo: 9, ["linux"]), save("dup", daysAgo: 1, ["linux"]),
            save("b", daysAgo: 2, ["linux"]), save("c", daysAgo: 3, ["linux"]),
        ]
        let card = digest(saves)?.cards.first
        #expect(card?.evidenceIDs.sorted() == ["b", "c", "dup"])
        if case let .currentInterest(interest) = card {
            #expect(interest.saveCount == 3)
            #expect(interest.lastDate == saves[1].date) // the newest of the two duplicates
        } else {
            Issue.record("expected a current-interest card")
        }
    }

    // MARK: - Normalization

    @Test func topicsAreTrimmedCollapsedAndLowercasedBeforeCounting() {
        let saves = [
            save("a", daysAgo: 0, ["  AI   Agents "]),
            save("b", daysAgo: 1, ["ai agents"]),
            save("c", daysAgo: 2, ["Ai\tAgents"]),
        ]
        if case let .currentInterest(interest) = digest(saves)?.cards.first {
            #expect(interest.theme == "ai agents")
            #expect(interest.saveCount == 3)
        } else {
            Issue.record("expected the three spellings to count as one topic")
        }
    }

    @Test func aTopicRepeatedInsideOneSaveCountsOnce() {
        // Counts are of distinct saves, never of tags.
        let saves = [
            save("a", daysAgo: 0, ["linux", "Linux", " linux "]),
            save("b", daysAgo: 1, ["linux", "LINUX"]),
        ]
        #expect(digest(saves)?.cards.isEmpty == true)
    }

    @Test func genericTopicsNeverBecomeATheme() {
        let saves = (0..<4).map { save("s\($0)", daysAgo: Double($0), ["viral", "fyp", "other"]) }
        #expect(digest(saves)?.cards.isEmpty == true)
    }

    @Test func theDisplaySpellingIsDeterministicAcrossInputOrder() {
        let saves = [
            save("a", daysAgo: 0, ["AI Agents"]),
            save("b", daysAgo: 1, ["ai agents"]),
            save("c", daysAgo: 2, ["Ai agents"]),
        ]
        let forward = digest(saves)
        let backward = digest(saves.reversed())
        #expect(forward == backward)
        if case let .currentInterest(interest) = forward?.cards.first {
            #expect(interest.displayTheme == "AI Agents")
        } else {
            Issue.record("expected a current-interest card")
        }
    }

    // MARK: - Current interest

    @Test func threeSavesOnATopicQualifyAsACurrentInterest() {
        let saves = (0..<3).map { save("s\($0)", daysAgo: Double($0), ["ai agents"]) }
        #expect(digest(saves)?.cards.first?.kind == .currentInterest)
    }

    @Test func twoSavesOnATopicDoNotQualify() {
        let saves = (0..<2).map { save("s\($0)", daysAgo: Double($0), ["ai agents"]) }
        #expect(digest(saves)?.cards.isEmpty == true)
    }

    @Test func currentInterestEvidenceMaySpanSeparateSessions() {
        // Deliberately unlike the old Recents threads: no four-hour session requirement, so an
        // interest returned to across three weeks still reads as one current interest.
        let saves = [save("a", daysAgo: 0, ["linux"]), save("b", daysAgo: 9, ["linux"]),
                     save("c", daysAgo: 20, ["linux"])]
        if case let .currentInterest(interest) = digest(saves)?.cards.first {
            #expect(interest.saveCount == 3)
            #expect(interest.firstDate == saves[2].date)
            #expect(interest.lastDate == saves[0].date)
        } else {
            Issue.record("expected one current-interest card spanning the window")
        }
    }

    @Test func aSaveExactlyThirtyDaysBeforeTheAnchorIsStillRecent() {
        let saves = [save("a", daysAgo: 0, ["linux"]), save("b", daysAgo: 15, ["linux"]),
                     save("c", daysAgo: 30, ["linux"])]
        #expect(digest(saves)?.cards.first?.kind == .currentInterest)
    }

    @Test func aSaveOneSecondOlderThanThirtyDaysIsOutsideTheWindow() {
        let older = LatelySelector.Save(
            id: "c", date: now.addingTimeInterval(-30 * 86400 - 1), topics: ["linux"])
        let saves = [save("a", daysAgo: 0, ["linux"]), save("b", daysAgo: 15, ["linux"]), older]
        #expect(digest(saves)?.cards.isEmpty == true)
    }

    @Test func theStrongestInterestLeads() {
        let saves = (0..<3).map { save("c\($0)", daysAgo: Double($0), ["cooking"]) }
            + (0..<5).map { save("l\($0)", daysAgo: Double($0) + 5, ["linux"]) }
        if case let .currentInterest(interest) = digest(saves)?.cards.first {
            #expect(interest.theme == "linux")
        } else {
            Issue.record("expected the five-save interest to win")
        }
    }

    // MARK: - Recent-to-older connection

    /// One recent save and one old save sharing a rare topic, padded with old saves so the
    /// rare topic's document frequency is controllable.
    func connectionFixture(rareCopies: Int) -> [LatelySelector.Save] {
        var saves = [save("recent", daysAgo: 1, ["common", "resin printing"]),
                     save("older", daysAgo: 80, ["common", "resin printing"])]
        for index in 0..<8 {
            let extra = index < (rareCopies - 2) ? ["common", "resin printing"] : ["common"]
            saves.append(save("pad\(index)", daysAgo: Double(90 + index), extra))
        }
        return saves
    }

    @Test func aRareSharedTopicConnectsARecentSaveToAnOldOne() {
        // "resin printing" sits in 2 of 10 eligible saves — exactly the 20% ceiling.
        let card = digest(connectionFixture(rareCopies: 2))?.cards.first
        if case let .connection(connection) = card {
            #expect(connection.recentID == "recent")
            #expect(connection.olderID == "older")
            #expect(connection.sharedTopics.count == 2)
            #expect(connection.sharedTopics.first == "resin printing")
        } else {
            Issue.record("expected a connection card")
        }
    }

    @Test func aTopicCommonerThanTwentyPercentCannotCarryAConnection() {
        // 3 of 10 eligible saves is 30%: both shared topics are now ubiquitous labels.
        #expect(digest(connectionFixture(rareCopies: 3))?.cards.isEmpty == true)
    }

    @Test func oneSharedTopicIsNotAConnection() {
        // "resin printing" is rare enough (2 of 10) to be enumerated, so this fails on the
        // two-topic rule rather than on rarity.
        let saves = [save("recent", daysAgo: 1, ["resin printing"]),
                     save("older", daysAgo: 80, ["resin printing"])]
            + (0..<8).map { save("pad\($0)", daysAgo: Double(90 + $0), ["common"]) }
        #expect(digest(saves)?.cards.isEmpty == true)
    }

    @Test func bothHalvesOfAConnectionMustStraddleTheWindow() {
        // Two recent saves sharing two rare topics are an interest, not a connection.
        let saves = [save("a", daysAgo: 1, ["resin printing", "miniatures"]),
                     save("b", daysAgo: 4, ["resin printing", "miniatures"])]
        #expect(digest(saves)?.cards.isEmpty == true)
    }

    @Test func aConnectionNamesItsTwoRarestSharedTopics() {
        var saves = [save("recent", daysAgo: 1, ["common", "resin printing", "miniatures"]),
                     save("older", daysAgo: 80, ["common", "resin printing", "miniatures"])]
        // Push "miniatures" to 4 of 12 saves so "resin printing" is the rarer of the two.
        for index in 0..<10 {
            let extra = index < 2 ? ["common", "miniatures"] : ["common"]
            saves.append(save("pad\(index)", daysAgo: Double(90 + index), extra))
        }
        if case let .connection(connection) = digest(saves)?.cards.first {
            #expect(connection.sharedTopics == ["resin printing", "miniatures"])
        } else {
            Issue.record("expected a connection card naming both rare topics")
        }
    }

    // MARK: - Returning interest

    /// Three recent saves on a topic plus two historical ones, with the gap under the caller's
    /// control via the latest historical save.
    func returningFixture(latestHistoricalDaysAgo: Double) -> [LatelySelector.Save] {
        (0..<3).map { save("r\($0)", daysAgo: Double($0) + 1, ["fermentation"]) }
            + [save("h0", daysAgo: latestHistoricalDaysAgo, ["fermentation"]),
               save("h1", daysAgo: latestHistoricalDaysAgo + 30, ["fermentation"])]
    }

    @Test func aSixtyDayGapExactlyQualifiesAsAReturn() {
        // Earliest recent save is 3 days before the anchor; 63 − 3 = 60 days of silence.
        if case let .returningInterest(returning) = digest(returningFixture(
            latestHistoricalDaysAgo: 63))?.cards.first {
            #expect(returning.theme == "fermentation")
            #expect(returning.recentCount == 3)
            #expect(returning.gapDays == 60)
            #expect(returning.historicalIDs == ["h0", "h1"])
        } else {
            Issue.record("expected a returning-interest card")
        }
    }

    @Test func aGapOneSecondShortOfSixtyDaysIsNotAReturn() {
        var saves = returningFixture(latestHistoricalDaysAgo: 63)
        saves[3] = .init(id: "h0", date: now.addingTimeInterval(-63 * 86400 + 1),
                         topics: ["fermentation"])
        #expect(digest(saves)?.cards.contains { $0.kind == .returningInterest } == false)
    }

    @Test func aContinuouslySavedTopicNeverReturns() {
        let steady = (0..<12).map { save("s\($0)", daysAgo: Double($0) * 10, ["fermentation"]) }
        #expect(digest(steady)?.cards.contains { $0.kind == .returningInterest } == false)
    }

    @Test func aReturnNeedsMoreThanOneHistoricalSave() {
        var saves = returningFixture(latestHistoricalDaysAgo: 90)
        saves.removeLast()
        #expect(digest(saves)?.cards.contains { $0.kind == .returningInterest } == false)
    }

    @Test func returningEvidenceKeepsRecentAndHistoricalSavesSeparate() {
        if case let .returningInterest(returning) = digest(returningFixture(
            latestHistoricalDaysAgo: 100))?.cards.first {
            #expect(returning.recentIDs == ["r0", "r1", "r2"])
            #expect(returning.historicalIDs == ["h0", "h1"])
            #expect(returning.recentCount == 3) // the face count excludes history
        } else {
            Issue.record("expected a returning-interest card")
        }
    }

    // MARK: - Composition

    /// One qualifying candidate of each kind, on disjoint topics and disjoint evidence.
    var threeCardFixture: [LatelySelector.Save] {
        (0..<3).map { save("c\($0)", daysAgo: Double($0) + 1, ["cooking"]) }
            + (0..<4).map { save("l\($0)", daysAgo: Double($0) + 1, ["linux"]) }
            + [save("l4", daysAgo: 70, ["linux"]), save("l5", daysAgo: 100, ["linux"])]
            + [save("n1", daysAgo: 2, ["3d printing", "resin"]),
               save("o1", daysAgo: 80, ["3d printing", "resin"])]
    }

    @Test func aFullDigestShowsInterestThenConnectionThenReturn() {
        let cards = digest(threeCardFixture)?.cards ?? []
        #expect(cards.map(\.kind) == [.currentInterest, .connection, .returningInterest])
    }

    @Test func noSaveIsEvidenceOnTwoCards() {
        let cards = digest(threeCardFixture)?.cards ?? []
        let all = cards.flatMap(\.evidenceIDs)
        #expect(all.count == Set(all).count)
    }

    @Test func aReturningTopicIsNotAlsoShownAsACurrentInterest() {
        // "linux" has four recent saves to cooking's three, so it outranks cooking as a
        // current interest. Its return is the more specific story, so it is reserved for the
        // returning slot and the weaker interest leads instead.
        let cards = digest(threeCardFixture)?.cards ?? []
        if case let .currentInterest(interest) = cards.first {
            #expect(interest.theme == "cooking")
        } else {
            Issue.record("expected cooking to take the current-interest slot")
        }
        if case let .returningInterest(returning) = cards.last {
            #expect(returning.theme == "linux")
        } else {
            Issue.record("expected linux to take the returning slot")
        }
    }

    @Test func aDigestWithNoQualifyingCandidatesIsEmptyRatherThanPadded() {
        let saves = [save("a", daysAgo: 0, ["linux"]), save("b", daysAgo: 1, ["cooking"])]
        #expect(digest(saves)?.cards.isEmpty == true)
    }

    @Test func suppressionIsAppliedBeforeCompositionNotAfter() {
        // Hiding the winning card promotes the runner-up rather than leaving the slot empty.
        let saves = (0..<4).map { save("c\($0)", daysAgo: Double($0) + 1, ["cooking"]) }
            + (0..<3).map { save("l\($0)", daysAgo: Double($0) + 1, ["linux"]) }
        let full = LatelySelector.digest(saves, now: now)
        let hidden = LatelySelector.digest(saves, now: now) { card in
            card.themeKey != "cooking"
        }
        #expect(full?.cards.first?.themeKey == "cooking")
        #expect(hidden?.cards.first?.themeKey == "linux")
    }

    // MARK: - Determinism and time

    @Test func reorderedInputYieldsAnIdenticalDigest() {
        let saves = threeCardFixture
        #expect(digest(saves) == digest(saves.reversed()))
        #expect(digest(saves) == digest(saves.sorted { $0.id < $1.id }))
    }

    @Test func advancingTheClockNeverRotatesTheDigest() {
        let saves = threeCardFixture
        let today = digest(saves)
        let inAWeek = digest(saves, at: now.addingTimeInterval(7 * 86400))
        #expect(today?.cards == inAWeek?.cards)
    }

    @Test func aLibraryUntouchedForOverThirtyDaysReadsAsHistorical() {
        // Measured from the newest save, not from the clock the fixture was built with.
        let saves = threeCardFixture
        let anchor = digest(saves)?.anchor ?? now
        #expect(digest(saves, at: anchor.addingTimeInterval(30 * 86400))?.isHistorical == false)
        #expect(digest(saves, at: anchor.addingTimeInterval(30 * 86400 + 1))?.isHistorical == true)
    }

    @Test func theAnchorIsTheNewestSaveNotTheClock() {
        let stale = (0..<3).map { save("s\($0)", daysAgo: 200 + Double($0), ["linux"]) }
        let result = digest(stale)
        #expect(result?.anchor == stale[0].date)
        #expect(result?.cards.first?.kind == .currentInterest)
    }

    // MARK: - Signatures

    @Test func aCardSignatureIgnoresRankingButNotEvidence() {
        let saves = (0..<3).map { save("s\($0)", daysAgo: Double($0), ["linux"]) }
        let extra = saves + [save("s3", daysAgo: 4, ["linux"])]
        #expect(digest(saves)?.cards.first?.signature == digest(saves.reversed())?
            .cards.first?.signature)
        #expect(digest(saves)?.cards.first?.signature != digest(extra)?.cards.first?.signature)
    }

    // MARK: - Scale

    @Test func aTenThousandSaveLibrarySelectsWithoutPairExplosion() {
        // The spec's reference size: 10,000 saves, up to five topics each. The failure this
        // guards is algorithmic, not cosmetic — connections are pairs, so a topic spanning
        // both halves of the window goes quadratic unless the walk stays counting-only.
        //
        // Measured on an Apple M5 Pro, macOS 27.0, release build, selection only:
        //   10,000 saves over 3,000 topics (a real library's shape)  66 ms
        //   10,000 saves over   400 topics (this fixture)           204 ms
        //   normalization floor, every topic distinct                63 ms
        // The spec's 100 ms target is met at a realistic topic spread; this fixture is the
        // adversarial end, where 25 saves share an identical five-topic set. It stays bounded
        // rather than exploding, which is the property worth pinning. The assertion is loose
        // on purpose — it runs in debug on unknown hardware (487 ms here) and is there to
        // catch a return to quadratic behaviour, not to time a laptop.
        var saves: [LatelySelector.Save] = []
        for index in 0..<10_000 {
            let topics = (0..<5).map { "topic \((index &* 7 &+ $0 &* 131) % 400)" }
            saves.append(save("v\(index)", daysAgo: Double(index) / 40, topics))
        }
        let started = Date()
        let result = LatelySelector.digest(saves, now: now)
        let elapsed = Date().timeIntervalSince(started)
        #expect(result != nil)
        #expect(elapsed < 2.0, "selection took \(elapsed)s on 10,000 saves")
    }

    @Test func signaturesCarryTheRulesVersion() {
        let saves = (0..<3).map { save("s\($0)", daysAgo: Double($0), ["linux"]) }
        let signature = digest(saves)?.cards.first?.signature ?? ""
        #expect(signature.hasPrefix("\(LatelySelector.Rules.rulesVersion)|"))
    }
}
