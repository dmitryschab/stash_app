// What the offers wire promises the app: up to three ranked offers, each with a merchant, a
// concrete product URL, a display price and a slot kind. The ranking itself is the server's
// job and tested there — these tests are about the decode surviving the wire.

import Foundation
import Testing
@testable import TikTokBrainKit

@Suite("Haul offers decode")
struct HaulOffersClientTests {

    @Test func aFullPayloadDecodesInServerOrder() throws {
        let payload = """
        {"offers": [
            {"merchant": "Amazon.de", "url": "https://www.amazon.de/dp/B0ABC12345",
             "price": "€94.99", "amount": 94.99, "currency": "EUR", "kind": "amazon"},
            {"merchant": "1a.lv", "url": "https://www.1a.lv/p/mx-master-4",
             "price": "€96.90", "amount": 96.9, "currency": "EUR", "kind": "other"},
            {"merchant": "Logitech", "url": "https://www.logitech.com/products/mx-master-4",
             "price": "€99.00", "amount": 99.0, "currency": "EUR", "kind": "brand"}
        ], "checkedAt": "2026-08-30T00:14:33.123456+00:00", "cached": false}
        """
        let offers = try HaulOffersClient.decodeOffers(Data(payload.utf8))

        #expect(offers.map(\.merchant) == ["Amazon.de", "1a.lv", "Logitech"])
        #expect(offers.map(\.kind) == [.amazon, .other, .brand])
        #expect(offers[0].amount == 94.99)
        #expect(offers[0].price == "€94.99")
        #expect(offers[0].url.host() == "www.amazon.de")
    }

    @Test func anOfferMayCarryTheProductPicture() throws {
        // The server reads the shop page's og:image for at most one offer; the rest have none,
        // and an old cache file written before the field existed must still decode.
        let payload = """
        {"offers": [
            {"merchant": "Amazon.de", "url": "https://www.amazon.de/dp/B0ABC12345",
             "price": "€94.99", "amount": 94.99, "currency": "EUR", "kind": "amazon"},
            {"merchant": "Logitech", "url": "https://www.logitech.com/products/mx-master-4",
             "price": "€99.00", "amount": 99.0, "currency": "EUR", "kind": "brand",
             "imageURL": "https://cdn.logitech.com/mx-master-4.png"}
        ], "cached": false}
        """
        let offers = try HaulOffersClient.decodeOffers(Data(payload.utf8))
        #expect(offers[0].imageURL == nil)
        #expect(offers[1].imageURL == URL(string: "https://cdn.logitech.com/mx-master-4.png"))
    }

    @Test func anUnknownKindReadsAsOther() throws {
        // A future server may rank new slots; an old app must keep showing the offer rather
        // than failing the whole screen over a word it has not learned.
        let payload = """
        {"offers": [{"merchant": "X", "url": "https://x.example/p/1", "price": "€5",
                     "amount": 5.0, "currency": "EUR", "kind": "sponsored"}], "cached": true}
        """
        let offers = try HaulOffersClient.decodeOffers(Data(payload.utf8))
        #expect(offers.map(\.kind) == [.other])
    }

    @Test func anEmptyAnswerIsAnEmptyList() throws {
        let offers = try HaulOffersClient.decodeOffers(
            Data(#"{"offers": [], "checkedAt": "2026-08-30T00:14:33+00:00", "cached": true}"#.utf8))
        #expect(offers.isEmpty)
    }

    @Test func garbageIsAMalformedPayloadNotACrash() {
        #expect(throws: BoxError.self) {
            try HaulOffersClient.decodeOffers(Data("shops are closed".utf8))
        }
    }
}
