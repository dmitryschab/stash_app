// Which desk shelf a save belongs to. Intent is the Library's new unit — "why you saved it"
// instead of "what it is about" — and these tests pin the rules, because a misfiled save is
// much louder on a shelf that claims to know your intent than it ever was under a category.

import Testing
@testable import TikTokBrainKit

@Suite("Save intent")
struct SaveIntentTests {

    func intent(_ category: Category?, _ topics: [String] = [],
                buys: Bool = false, includeBuy: Bool = true) -> SaveIntent {
        SaveIntent.classify(category: category, topics: topics,
                            hasBuys: buys, includeBuy: includeBuy)
    }

    @Test func aSaveSellingSomethingIsToBuy() {
        #expect(intent(.coding, ["ai"], buys: true) == .buy)
        #expect(intent(.film, ["cinema"], buys: true) == .buy)
    }

    @Test func theBuyShelfCanBeHandedBackToHaul() {
        // When the Haul tab is on the pill it owns the buys, exactly the way Cook owns
        // recipes — the save then files by its next intent instead of vanishing.
        #expect(intent(.film, ["cinema"], buys: true, includeBuy: false) == .watch)
    }

    @Test func filmComedyAndTheirTopicsAreToWatch() {
        #expect(intent(.film) == .watch)
        #expect(intent(.comedy) == .watch)
        #expect(intent(.other, ["anime"]) == .watch)
        #expect(intent(.other, ["sci-fi", "recommendations"]) == .watch)
    }

    @Test func howToShapedSavesAreToTry() {
        #expect(intent(.coding, ["automation"]) == .tryIt)
        #expect(intent(.other, ["productivity"]) == .tryIt)
        #expect(intent(.travel) == .tryIt)
        #expect(intent(.fitness) == .tryIt)
    }

    @Test func aestheticSavesAreMood() {
        #expect(intent(.style) == .mood)
        #expect(intent(.home, ["interior design"]) == .mood)
        #expect(intent(.other, ["aesthetic"]) == .mood)
    }

    @Test func homeSplitsByDoingVersusLooking() {
        // "hidden cable wall" is something you do; "warm minimalism" is something you look at.
        #expect(intent(.home, ["diy"]) == .tryIt)
        #expect(intent(.home, ["home decor"]) == .mood)
        #expect(intent(.home) == .mood)
    }

    @Test func watchOutranksTry() {
        // A film list that mentions productivity is still a film list.
        #expect(intent(.film, ["productivity"]) == .watch)
    }

    @Test func everythingElseIsReference() {
        #expect(intent(.coding, ["webdev"]) == .reference)
        #expect(intent(.learning, ["history"]) == .reference)
        #expect(intent(nil) == .reference)
        #expect(intent(.other) == .reference)
    }

    @Test func topicCaseDoesNotMatter() {
        #expect(intent(.other, ["Anime"]) == .watch)
        #expect(intent(.other, ["PRODUCTIVITY"]) == .tryIt)
    }
}
