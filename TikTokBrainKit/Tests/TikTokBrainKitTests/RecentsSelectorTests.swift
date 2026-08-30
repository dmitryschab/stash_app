// RecentsSelectorTests.swift
//
// Pins the Recents rules from the 2026-08-30 spec: the count-based, time-clamped window;
// thread detection over <4h sessions; hero-only-when-loose; and the deterministic
// resurface pick. The numbers in the rules came from the real 855-save library, so a rule
// drifting here means the screen stops matching the analysis that justified it.

import Foundation
import Testing
@testable import TikTokBrainKit

@Suite("Recents selector")
struct RecentsSelectorTests {

    let now = Date(timeIntervalSince1970: 1_780_000_000)

    func save(_ id: String, hoursAgo: Double, _ topics: [String] = []) -> RecentsSelector.Save {
        .init(id: id, date: now.addingTimeInterval(-hoursAgo * 3600), topics: topics)
    }

    func save(_ id: String, daysAgo: Double, _ topics: [String] = []) -> RecentsSelector.Save {
        save(id, hoursAgo: daysAgo * 24, topics)
    }

    @Test func anEmptyLibraryHasNoBoard() {
        #expect(RecentsSelector.board([], now: now) == nil)
    }

    @Test func theWindowAnchorsOnTheNewestSaveNotTheClock() {
        // Nothing saved for 51 days (the real library's own state in August) — the board
        // still shows the last burst instead of an empty screen.
        let stale = (0..<8).map { save("s\($0)", daysAgo: 51 + Double($0)) }
        let board = RecentsSelector.board(stale, now: now)
        #expect(board?.saveCount == 8)
    }

    @Test func aBingeClampsTheWindowUpToThreeDays() {
        // 20 saves inside one day: the reach to the 8th save is under the 3-day floor, so
        // the floor applies and everything qualifies — then the display cap holds it at 12.
        let binge = (0..<20).map { save("s\($0)", hoursAgo: Double($0)) }
        let board = RecentsSelector.board(binge, now: now)
        #expect(board?.saveCount == 12)
    }

    @Test func aSparseLibraryClampsTheWindowDownToThirtyDays() {
        let sparse = [save("a", daysAgo: 0), save("b", daysAgo: 5), save("c", daysAgo: 10),
                      save("d", daysAgo: 40), save("e", daysAgo: 100)]
        let board = RecentsSelector.board(sparse, now: now)
        #expect(board?.saveCount == 3)
        #expect(board?.looseIDs.contains("d") == false)
    }

    @Test func theWindowStartIsTheOldestShownSaveForTheHonestLabel() {
        let sparse = [save("a", daysAgo: 0), save("b", daysAgo: 5), save("c", daysAgo: 10)]
        let board = RecentsSelector.board(sparse, now: now)
        #expect(board?.windowStart == sparse[2].date)
    }

    @Test func aThematicSessionBecomesAThread() {
        let saves = [
            save("a1", hoursAgo: 1, ["ai agents", "automation"]),
            save("a2", hoursAgo: 2, ["ai agents", "chatbots"]),
            save("a3", hoursAgo: 3, ["low-code", "ai agents"]),
            save("x", hoursAgo: 30, ["cooking"]),
        ]
        let board = RecentsSelector.board(saves, now: now)
        #expect(board?.threads == [.init(theme: "ai agents", saveIDs: ["a1", "a2", "a3"])])
        #expect(board?.looseIDs == ["x"])
        #expect(board?.heroID == nil) // the newest save sits in the thread, so no hero
    }

    @Test func aMixedSessionStaysLoose() {
        let saves = [
            save("a", hoursAgo: 1, ["cooking"]),
            save("b", hoursAgo: 2, ["linux"]),
            save("c", hoursAgo: 3, ["travel"]),
        ]
        let board = RecentsSelector.board(saves, now: now)
        #expect(board?.threads.isEmpty == true)
        #expect(board?.heroID == "a")
        #expect(board?.looseIDs == ["b", "c"])
    }

    @Test func aFourHourGapSplitsSessions() {
        // Same topic on both sides of the gap, but each side has only 2 saves — neither
        // half reaches the 3-member floor, so no thread forms.
        let saves = [
            save("a", hoursAgo: 1, ["linux"]), save("b", hoursAgo: 2, ["linux"]),
            save("c", hoursAgo: 7, ["linux"]), save("d", hoursAgo: 8, ["linux"]),
        ]
        #expect(RecentsSelector.board(saves, now: now)?.threads.isEmpty == true)
    }

    @Test func theHeroLeadsOnlyWhenItIsTheNewestSave() {
        let saves = [
            save("hero", hoursAgo: 1, ["travel"]),
            save("t1", hoursAgo: 10, ["linux"]), save("t2", hoursAgo: 11, ["linux"]),
            save("t3", hoursAgo: 12, ["linux", "privacy"]),
        ]
        let board = RecentsSelector.board(saves, now: now)
        #expect(board?.heroID == "hero")
        #expect(board?.looseIDs == [])
        #expect(board?.threads.first?.theme == "linux")
    }

    @Test func resurfacePrefersAnOldSaveSharingAWindowTopic() {
        let saves = [
            save("new", daysAgo: 0, ["self-hosting"]),
            save("oldRelated", daysAgo: 90, ["self-hosting", "privacy"]),
            save("oldOther", daysAgo: 120, ["cooking"]),
        ]
        #expect(RecentsSelector.board(saves, now: now)?.resurfaceID == "oldRelated")
    }

    @Test func resurfaceNeedsAPast() {
        let saves = [save("a", daysAgo: 0, ["ai"]), save("b", daysAgo: 20, ["ai"])]
        #expect(RecentsSelector.board(saves, now: now)?.resurfaceID == nil)
    }

    @Test func resurfaceIsStableWithinADay() {
        let saves = [save("new", daysAgo: 0, ["x"])]
            + (0..<7).map { save("old\($0)", daysAgo: 70 + Double($0), ["y"]) }
        let a = RecentsSelector.board(saves, now: now)?.resurfaceID
        let b = RecentsSelector.board(saves, now: now.addingTimeInterval(120))?.resurfaceID
        #expect(a != nil)
        #expect(a == b)
    }
}
