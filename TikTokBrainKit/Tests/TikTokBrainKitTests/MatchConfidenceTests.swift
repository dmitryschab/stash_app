import XCTest
@testable import TikTokBrainKit

final class MatchConfidenceTests: XCTestCase {

    /// The exact failure this gate exists for. A jungle-genre list theme was matched to a real
    /// album that appears nowhere in the video, and the app then showed its tracklist as fact.
    func testRejectsTheAlbumThatCausedThisWork() {
        XCTAssertFalse(MatchConfidence.accepts(
            askedTitle: "jungle selection vol 1", askedArtist: "",
            returnedTitle: "Jungle Skeletons: Fire Various Selection, Vol. 1",
            returnedArtist: "Silent Monkz"))
    }

    /// A catalogue title that extends what was asked for is the same release when the artist
    /// agrees — the artist is the independent evidence that buys the lower title bar.
    func testAcceptsAShorterCatalogueTitleWhenTheArtistAgrees() {
        XCTAssertTrue(MatchConfidence.accepts(
            askedTitle: "Reflections / Secret Portraits", askedArtist: "New Balance",
            returnedTitle: "Reflections", returnedArtist: "New Balance"))
    }

    /// The same pair without a named artist has only the titles to go on, and one word in three
    /// is not enough. Refusing here is the cost of refusing the jungle album above — the two are
    /// structurally identical once the artist is gone, and a wrong link is worse than none.
    func testRefusesTheSamePairWhenNoArtistCorroboratesIt() {
        XCTAssertFalse(MatchConfidence.accepts(
            askedTitle: "Reflections", askedArtist: "",
            returnedTitle: "Reflections / Secret Portraits", returnedArtist: "New Balance"))
    }

    func testAcceptsAnExactMatchWithPunctuationDifferences() {
        XCTAssertTrue(MatchConfidence.accepts(
            askedTitle: "Atlantis (I Need You)", askedArtist: "LTJ Bukem",
            returnedTitle: "Atlantis - I Need You", returnedArtist: "LTJ Bukem"))
    }

    /// Volume-numbered releases have to stay comparable — "Vol." and "vol" are one token.
    func testVolumeNumberingSurvivesTokenising() {
        XCTAssertEqual(MatchConfidence.tokens("Dreamcore, Vol. 1"), ["dreamcore", "vol", "1"])
        XCTAssertTrue(MatchConfidence.accepts(
            askedTitle: "Dreamcore, Vol. 1", askedArtist: "",
            returnedTitle: "Dreamcore Vol 1", returnedArtist: "dreamstation"))
    }

    /// A named artist is a hard constraint. "Genesis" is a title many acts share, and linking the
    /// wrong one is the same error as matching the wrong album.
    func testANamedArtistMustAgreeEvenOnAPerfectTitle() {
        XCTAssertFalse(MatchConfidence.accepts(
            askedTitle: "Genesis", askedArtist: "Nedaj",
            returnedTitle: "Genesis", returnedArtist: "Phil Collins"))
        XCTAssertTrue(MatchConfidence.accepts(
            askedTitle: "Genesis", askedArtist: "Nedaj",
            returnedTitle: "Genesis", returnedArtist: "Nedaj"))
    }

    /// An artist the video never named cannot contradict anything.
    func testAnAbsentArtistConstrainsNothing() {
        XCTAssertTrue(MatchConfidence.accepts(
            askedTitle: "Polaris", askedArtist: "",
            returnedTitle: "Polaris", returnedArtist: "Some Other Act"))
    }

    func testEmptyInputScoresZeroRatherThanDividingByZero() {
        XCTAssertEqual(MatchConfidence.score("", "anything"), 0)
        XCTAssertEqual(MatchConfidence.score("anything", ""), 0)
        XCTAssertEqual(MatchConfidence.score("!!!", "???"), 0)
        XCTAssertFalse(MatchConfidence.accepts(
            askedTitle: "", askedArtist: "", returnedTitle: "Whatever", returnedArtist: ""))
    }

    /// Guards the thresholds themselves. The first version of `score` divided by the smaller
    /// token set, which scored the jungle pair 1.0 — a short vague phrase is a perfect subset of
    /// any long title containing its words. If this ever passes again, the gate is open.
    func testAVagueThemeIsNotASubsetMatchForALongTitle() {
        let bad = MatchConfidence.score(
            "jungle selection vol 1", "Jungle Skeletons: Fire Various Selection, Vol. 1")
        XCTAssertLessThan(bad, MatchConfidence.threshold)

        let corroborated = MatchConfidence.score("Reflections / Secret Portraits", "Reflections")
        XCTAssertGreaterThanOrEqual(corroborated, MatchConfidence.corroboratedThreshold)
        XCTAssertLessThan(corroborated, MatchConfidence.threshold,
                          "this pair must need its artist — otherwise the artist rule is untested")
    }
}
