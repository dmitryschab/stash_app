import XCTest
@testable import TikTokBrainKit

/// Searching by what a save is about: which words count, when meaning alone is enough, and the
/// order the survivors come back in. Cosines are expressed against `SearchIndex`'s constants
/// rather than as literals, so retuning a threshold does not break the tests that are about the
/// ordering rule and not about the number.
final class SearchRankingTests: XCTestCase {

    // MARK: Fixtures

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func day(_ offset: Int) -> Date {
        epoch.addingTimeInterval(Double(offset) * 86_400)
    }

    /// Query `[1, 0]` against `[c, sqrt(1 - c*c)]` is a cosine of exactly `c`.
    private let query: [Float] = [1, 0]

    private func stored(_ cosine: Double) -> [Float] {
        let c = Float(cosine)
        return [c, (1 - c * c).squareRoot()]
    }

    private func entry(
        _ id: String,
        about: String,
        at date: Date,
        cosine: Double? = nil,
        hasAbout: Bool = true
    ) -> SearchEntry {
        SearchEntry(
            videoID: id,
            bookmarkedAt: date,
            words: SearchIndex.words(about),
            hasAbout: hasAbout,
            embedding: cosine.map(stored))
    }

    private func ids(_ matches: [SearchMatch]) -> [String] { matches.map(\.videoID) }

    private func makeVideo(_ id: String = "1") -> Video {
        Video(videoID: id, url: URL(string: "https://tiktok.com/x/\(id)")!, bookmarkedAt: epoch)
    }

    // MARK: Words

    func testWholeWordsOnly() {
        let entries = [entry("party", about: "a party at the start", at: epoch)]
        XCTAssertEqual(SearchIndex.rank(entries, query: "art", embedding: nil), [])
        XCTAssertEqual(ids(SearchIndex.rank(entries, query: "party", embedding: nil)), ["party"])
    }

    func testPluralsMatchBothWays() {
        let plural = entry("plural", about: "two pastas tonight", at: epoch)
        let singular = entry("singular", about: "pasta bake", at: epoch)
        XCTAssertEqual(ids(SearchIndex.rank([plural], query: "pasta", embedding: nil)), ["plural"])
        XCTAssertEqual(ids(SearchIndex.rank([singular], query: "pastas", embedding: nil)), ["singular"])
        // The "es" ending folds too.
        XCTAssertEqual(SearchIndex.stem("dishes"), SearchIndex.stem("dish"))
    }

    func testCakesAndRecipesMeetTheirSingulars() {
        // Only "s" comes off a word that is not a sibilant plural: "cakes" -> "cake", not "cak".
        let cakes = entry("cakes", about: "two cakes", at: epoch)
        let recipes = entry("recipes", about: "easy recipes", at: epoch)
        let dishes = entry("dishes", about: "quick dishes", at: epoch)
        XCTAssertEqual(ids(SearchIndex.rank([cakes], query: "cake", embedding: nil)), ["cakes"])
        XCTAssertEqual(ids(SearchIndex.rank([recipes], query: "recipe", embedding: nil)), ["recipes"])
        XCTAssertEqual(ids(SearchIndex.rank([dishes], query: "dish", embedding: nil)), ["dishes"])
        // And the other way round.
        XCTAssertEqual(ids(SearchIndex.rank([cakes], query: "cakes", embedding: nil)), ["cakes"])
        XCTAssertEqual(ids(SearchIndex.rank([recipes], query: "recipes", embedding: nil)), ["recipes"])
    }

    func testStemRules() {
        let cases: [(String, String)] = [
            ("dishes", "dish"), ("boxes", "box"), ("glasses", "glass"), ("churches", "church"),
            ("buses", "bus"),
            ("cakes", "cake"), ("recipes", "recipe"), ("pastas", "pasta"),
            ("glass", "glass"), ("class", "class"),
            ("bus", "bus"), ("gas", "gas"), ("pasta", "pasta"),
        ]
        for (word, stem) in cases {
            XCTAssertEqual(SearchIndex.stem(word), stem, word)
        }
    }

    func testAWordEndingInSSKeepsBothLetters() {
        XCTAssertEqual(SearchIndex.words("glass"), ["glass"])
        XCTAssertEqual(SearchIndex.words("glasses"), ["glass"])
    }

    func testApostrophesJoinInsteadOfSplitting() {
        XCTAssertEqual(SearchIndex.words("dog's"), SearchIndex.words("dog"))
        XCTAssertEqual(SearchIndex.words("dog\u{2019}s"), SearchIndex.words("dog"))
        XCTAssertEqual(SearchIndex.words("don't"), ["dont"])
    }

    func testPossessivesDoNotMatchOnTheLetterS() {
        // "dog's bed" used to share the stray token "s" with "Alice's garden".
        let alice = entry("alice", about: "Alice's garden", at: epoch)
        XCTAssertEqual(SearchIndex.rank([alice], query: "dog's bed", embedding: nil), [])
        let toy = entry("toy", about: "my dog's toy", at: epoch)
        XCTAssertEqual(ids(SearchIndex.rank([toy], query: "dog", embedding: nil)), ["toy"])
    }

    func testSingleCharacterTokensAreDropped() {
        XCTAssertEqual(SearchIndex.words("vitamin c 5 x"), ["vitamin"])
    }

    func testStopWordsAreIgnored() {
        let entries = [
            entry("bike", about: "how to fix a bike", at: epoch),
            entry("bread", about: "bake bread", at: epoch),
        ]
        XCTAssertEqual(ids(SearchIndex.rank(entries, query: "how to bake", embedding: nil)), ["bread"])
    }

    func testOnlyStopWordsOfflineFindsNothing() {
        let entries = [entry("bike", about: "how to fix a bike", at: epoch)]
        XCTAssertEqual(SearchIndex.rank(entries, query: "how to", embedding: nil), [])
    }

    func testPunctuationAndAccentsFold() {
        let entries = [entry("cafe", about: "best cafe in riga", at: epoch)]
        XCTAssertEqual(ids(SearchIndex.rank(entries, query: "Café!", embedding: nil)), ["cafe"])
        XCTAssertEqual(ids(SearchIndex.rank(entries, query: "RIGA, cafe", embedding: nil)), ["cafe"])
    }

    // MARK: Meaning

    func testMeaningOnlyMatchIsIncluded() {
        let near = entry("near", about: "a dog skates", at: epoch,
                         cosine: SearchIndex.meaningFloor + 0.05)
        let far = entry("far", about: "a dog skates", at: epoch,
                        cosine: SearchIndex.meaningFloor - 0.05)
        // Neither shares a word with the query: meaning is the only way in.
        XCTAssertEqual(ids(SearchIndex.rank([near, far], query: "puppy", embedding: query)), ["near"])
    }

    func testAStoredVectorIsIgnoredWithoutAQueryVector() {
        let near = entry("near", about: "a dog skates", at: epoch,
                         cosine: SearchIndex.meaningFloor + 0.05)
        XCTAssertEqual(SearchIndex.rank([near], query: "puppy", embedding: nil), [])
    }

    func testSayingTheWordOutranksTheSameMeaning() {
        let cosine = SearchIndex.meaningFloor + 0.15
        let said = entry("said", about: "pasta for two", at: day(0), cosine: cosine)
        let meant = entry("meant", about: "noodles with sauce", at: day(10), cosine: cosine)
        let ranked = SearchIndex.rank([meant, said], query: "pasta", embedding: query)
        XCTAssertEqual(ids(ranked), ["said", "meant"])
    }

    func testCloseScoresGoNewestFirst() {
        // Two cosines inside one tie bucket, wherever the bucket edges currently fall.
        let band = SearchIndex.tieBand
        let bucket = (SearchIndex.meaningFloor + 2 * band) / band
        let low = (bucket.rounded(.down) + 0.25) * band
        let high = low + 0.5 * band
        let older = entry("old", about: "a dog skates", at: day(0), cosine: low)
        let newer = entry("new", about: "a dog skates", at: day(1), cosine: high)
        XCTAssertEqual(ids(SearchIndex.rank([older, newer], query: "puppy", embedding: query)),
                       ["new", "old"])
        // Regardless of the order they arrive in.
        XCTAssertEqual(ids(SearchIndex.rank([newer, older], query: "puppy", embedding: query)),
                       ["new", "old"])
    }

    func testClearlyCloserWinsOverNewer() {
        let band = SearchIndex.tieBand
        let low = SearchIndex.meaningFloor + 2 * band
        let high = low + 5 * band
        let closer = entry("closer", about: "a dog skates", at: day(0), cosine: high)
        let newer = entry("newer", about: "a dog skates", at: day(1), cosine: low)
        XCTAssertEqual(ids(SearchIndex.rank([newer, closer], query: "puppy", embedding: query)),
                       ["closer", "newer"])
    }

    // MARK: Offline

    func testSavesWithoutAboutComeLast() {
        let about = entry("about", about: "pasta for two", at: day(0))
        let fallback = entry("fallback", about: "pasta for two", at: day(5), hasAbout: false)
        XCTAssertEqual(ids(SearchIndex.rank([fallback, about], query: "pasta", embedding: nil)),
                       ["about", "fallback"])
    }

    func testMoreWordHitsComeFirstOffline() {
        let one = entry("one", about: "pasta for two", at: day(5))
        let two = entry("two", about: "pasta with garlic", at: day(0))
        XCTAssertEqual(ids(SearchIndex.rank([one, two], query: "garlic pasta", embedding: nil)),
                       ["two", "one"])
    }

    func testEmbeddedSavesRankAheadOfUnembeddedOnes() {
        // Online, a save with a vector is judged on meaning; one without can only be found by
        // word, and sits below every save that was.
        let embedded = entry("embedded", about: "noodles", at: day(0),
                             cosine: SearchIndex.meaningFloor + 0.05)
        let unembedded = entry("unembedded", about: "pasta for two", at: day(5))
        XCTAssertEqual(ids(SearchIndex.rank([unembedded, embedded], query: "pasta", embedding: query)),
                       ["embedded", "unembedded"])
    }

    // MARK: Build

    func testBuildIgnoresTitleTopicsAndCaption() {
        let video = makeVideo()
        video.title = "pasta night"
        video.topics = ["pasta"]
        video.caption = "#pasta"
        video.hashtags = ["pasta"]
        video.ocrText = "pasta"
        video.about = "a dog skates"
        let entries = SearchIndex.build([video])
        XCTAssertEqual(SearchIndex.rank(entries, query: "pasta", embedding: nil), [])
        XCTAssertEqual(ids(SearchIndex.rank(entries, query: "dog", embedding: nil)), ["1"])
        XCTAssertTrue(entries[0].hasAbout)
    }

    func testBuildFallsBackToSummaryAndTranscript() {
        let video = makeVideo()
        video.about = nil
        video.transcript = "boil the pasta"
        video.embedding = EmbeddingVector.pack([1, 0])
        video.embeddingRevision = BoxEmbeddingClient.revision
        let entries = SearchIndex.build([video])
        XCTAssertEqual(ids(SearchIndex.rank(entries, query: "pasta", embedding: nil)), ["1"])
        XCTAssertFalse(entries[0].hasAbout)
        XCTAssertNil(entries[0].embedding)
    }

    func testBuildFallbackReadsTheSummaryToo() {
        let video = makeVideo()
        video.about = ""
        video.summary = "a quick lasagne"
        let entries = SearchIndex.build([video])
        XCTAssertEqual(ids(SearchIndex.rank(entries, query: "lasagne", embedding: nil)), ["1"])
        XCTAssertFalse(entries[0].hasAbout)
    }

    func testBuildKeepsTheVectorOfTheCurrentRevision() {
        let video = makeVideo()
        video.about = "a dog skates"
        video.embedding = EmbeddingVector.pack([1, 0])
        video.embeddingRevision = BoxEmbeddingClient.revision
        XCTAssertEqual(SearchIndex.build([video])[0].embedding, [1, 0])
    }

    func testBuildIgnoresAVectorFromBeforeTheAbout() {
        // Built from title and hashtags, so it describes the creator's reach and not the save.
        let video = makeVideo()
        video.about = "a dog skates"
        video.embedding = EmbeddingVector.pack([1, 0])
        video.embeddingRevision = 1
        let entries = SearchIndex.build([video])
        XCTAssertTrue(entries[0].hasAbout)
        XCTAssertNil(entries[0].embedding)
    }

    func testBuildKeepsDateAndIdentity() {
        let video = makeVideo("42")
        video.bookmarkedAt = day(3)
        video.about = "a dog skates"
        let built = SearchIndex.build([video])[0]
        XCTAssertEqual(built.videoID, "42")
        XCTAssertEqual(built.bookmarkedAt, day(3))
    }
}
