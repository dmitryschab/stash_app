import XCTest
@testable import TikTokBrainKit

/// The rules that decide what a recognised track is allowed to change. ShazamKit itself needs a
/// real recording and the network; these are the decisions made after it answers, which is where
/// every way of getting this wrong lives.
final class AudioMatchMergeTests: XCTestCase {

    private let polaris = AudioMatch(title: "Polaris", artist: "KMC")

    /// The reason this work exists: ~71 saves carry a title and `artist: ""`, because the prompt
    /// forbids the model from guessing one. The audio knows.
    func testFillsTheArtistTheModelWasForbiddenToGuess() {
        let merged = polaris.merged(
            into: [MusicPick(kind: .track, title: "Polaris", artist: "")], category: .music)
        XCTAssertEqual(merged, [MusicPick(kind: .track, title: "Polaris", artist: "KMC")])
    }

    /// A countdown of twelve albums matches exactly one track — the sound playing over the video,
    /// not the twelve records it recommends. Rewriting artists from that one match would invent
    /// eleven wrong ones, so a pick the model named is never touched.
    func testNeverOverwritesAnArtistTheModelNamed() {
        let list = (1...12).map { MusicPick(kind: .album, title: "Release \($0)", artist: "Act \($0)") }
        XCTAssertNil(polaris.merged(into: list, category: .music))

        // Not even when the match is one of them by name.
        let exact = [MusicPick(kind: .track, title: "Polaris", artist: "Someone Else")]
        XCTAssertNil(polaris.merged(into: exact, category: .music))
    }

    /// "What song is this" saves: the model has nothing to say and says nothing, so the match is
    /// the whole answer. Apple's own URL seeds the link, wrapped the way every other pick's is.
    func testAMusicVideoWithNoPicksGetsTheMatchAsItsOnly() throws {
        let apple = "https://music.apple.com/us/album/polaris/1"
        let match = AudioMatch(title: "Polaris", artist: "KMC", appleMusicURL: URL(string: apple))
        XCTAssertEqual(try XCTUnwrap(match.merged(into: [], category: .music)),
                       [MusicPick(kind: .track, title: "Polaris", artist: "KMC",
                                  link: MusicPickResolver.songLink(for: apple))])
    }

    /// Every other category is a video with a soundtrack. A recipe does not recommend the song
    /// playing behind it, and filing one under its music would be a lie about what was saved.
    func testANonMusicVideoWithNoPicksIsLeftAlone() {
        XCTAssertNil(polaris.merged(into: [], category: .recipe))
        XCTAssertNil(polaris.merged(into: [], category: .other))
    }

    /// The same confidence gate the catalogue lookups face: shared words, not edit distance. A
    /// match that is not plausibly this pick fills nothing — an artist attached to the wrong
    /// title is exactly the invented-artist failure this replaces.
    func testATitleThatDoesNotAgreeChangesNothing() {
        let unrelated = [MusicPick(kind: .album, title: "Dreamcore, Vol. 1", artist: "")]
        XCTAssertNil(polaris.merged(into: unrelated, category: .music))
    }

    /// Only the picks that agree are filled; the rest of the list survives untouched.
    func testOnlyTheAgreeingPickIsFilled() {
        let picks = [MusicPick(kind: .album, title: "Dreamcore, Vol. 1", artist: ""),
                     MusicPick(kind: .track, title: "Polaris", artist: "")]
        XCTAssertEqual(polaris.merged(into: picks, category: .music),
                       [MusicPick(kind: .album, title: "Dreamcore, Vol. 1", artist: ""),
                        MusicPick(kind: .track, title: "Polaris", artist: "KMC")])
    }

    /// The cap is a guarantee about what gets stored, not an arithmetic accident of the rules
    /// above — a payload that already exceeds it is trimmed on the way back out.
    func testTheStoredListStaysWithinTheCap() {
        let overlong = Array(repeating: MusicPick(kind: .track, title: "Polaris", artist: ""),
                             count: MusicPick.maxPerVideo + 1)
        XCTAssertEqual(polaris.merged(into: overlong, category: .music)?.count,
                       MusicPick.maxPerVideo)
    }

    /// Half a match is no match: a title with no artist fills nothing, and naming a music video
    /// after an artist-less recognition is how a blank pick gets stored.
    func testAHalfEmptyMatchChangesNothing() {
        let noArtist = AudioMatch(title: "Polaris", artist: "")
        XCTAssertNil(noArtist.merged(into: [MusicPick(kind: .track, title: "Polaris", artist: "")],
                                     category: .music))
        XCTAssertNil(noArtist.merged(into: [], category: .music))
        XCTAssertNil(AudioMatch(title: "", artist: "KMC").merged(into: [], category: .music))
    }
}
