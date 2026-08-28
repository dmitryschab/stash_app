import XCTest
@testable import TikTokBrainKit

/// What the analyzer may send back in `buys`, and where a pick can be looked up.
final class BuyPickTests: XCTestCase {
    private func analysis(_ json: String) throws -> Analysis {
        try JSONDecoder().decode(Analysis.self, from: Data(json.utf8))
    }

    /// The point of the whole field: picks do not follow the category, so a style save carries
    /// them exactly as a haul does.
    func testPicksRideAlongWithAnyCategory() throws {
        let decoded = try analysis("""
        {"category":"style","title":"three colours","summary":"...","topics":["outfits"],
         "recipe":null,"code":null,"music":[],
         "buys":[
           {"name":"Levi's 501 '93 straight","kind":"Jeans","price":"€110"},
           {"name":"Uniqlo U crew neck tee"}
         ]}
        """)
        XCTAssertEqual(decoded.category, .style)
        XCTAssertEqual(decoded.buys.map(\.name), ["Levi's 501 '93 straight", "Uniqlo U crew neck tee"])
        XCTAssertEqual(decoded.buys[0].kind, "jeans")   // normalised for the shelf's chips
        XCTAssertEqual(decoded.buys[1].price, "")       // never estimated
    }

    func testNamelessPicksAreDroppedAndTheListIsBounded() throws {
        let items = ([#"{"name":""}"#, #"{"name":"   "}"#]
            + (0..<20).map { #"{"name":"item \#($0)"}"# }).joined(separator: ",")
        let decoded = try analysis("""
        {"category":"other","title":"t","summary":"s","recipe":null,"code":null,"music":[],
         "buys":[\(items)]}
        """)
        XCTAssertEqual(decoded.buys.count, BuyPick.maxPerVideo)
        XCTAssertTrue(decoded.buys.allSatisfy { !$0.name.isEmpty })
    }

    /// A save analyzed before `buys` existed decodes to an empty list, not a failure — the whole
    /// library would go blank otherwise.
    func testAnalysisWithoutBuysStillDecodes() throws {
        let decoded = try analysis("""
        {"category":"comedy","title":"t","summary":"s","recipe":null,"code":null,"music":[]}
        """)
        XCTAssertEqual(decoded.buys, [])
    }

    func testAmazonFollowsTheRegionAndFallsBackToGermany() {
        XCTAssertEqual(Shop.amazonHost(region: "NL"), "www.amazon.nl")
        XCTAssertEqual(Shop.amazonHost(region: "US"), "www.amazon.com")
        XCTAssertEqual(Shop.amazonHost(region: "LV"), "www.amazon.de")   // no local store
        XCTAssertEqual(Shop.amazonHost(region: nil), "www.amazon.de")
    }

    func testSearchURLsEscapeTheQueryAndRefuseAnEmptyOne() {
        let amazon = Shop.amazon.searchURL(for: "Levi's 501 '93", region: "DE")
        XCTAssertEqual(amazon?.absoluteString, "https://www.amazon.de/s?k=Levi's%20501%20'93")

        let google = Shop.google.searchURL(for: "Keychron K3 Pro", region: "DE")
        XCTAssertEqual(google?.absoluteString,
                       "https://www.google.com/search?q=Keychron%20K3%20Pro&tbm=shop")

        XCTAssertNil(Shop.amazon.searchURL(for: "   ", region: "DE"))
    }
}
