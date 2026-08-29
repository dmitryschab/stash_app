// HaulOffers.swift
//
// The wire behind the pick page's "Where to buy": POST {base}/haul/offers with a pick's name
// and the buyer's country; back come up to three offers the server already ranked — the
// country's own Amazon storefront pinned first when it has the item, the brand's own store
// when it doesn't, the rest cheapest-first. services/webhook/haul_offers_api.py owns those
// rules and its tests are where they are proven; this client's whole job is carrying the
// answer, so nothing here re-sorts, re-filters or re-prices.

import Foundation

/// One place a pick can be bought right now: a shop, a concrete product page, and the price
/// that page showed. `kind` names the slot the server put it in; the page renders the list
/// in the order it arrived.
public struct HaulOffer: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case amazon, brand, other

        /// A slot this build has not learned yet still names a real shop with a real price —
        /// read it as `other` rather than failing the whole screen over a new word.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .other
        }
    }

    public var merchant: String
    public var url: URL
    /// The price as the shop displays it ("€94.99") — the string the row shows.
    public var price: String
    /// The same price as a number. The server sorted by it; the app never re-computes it.
    public var amount: Double
    public var currency: String
    public var kind: Kind

    public init(merchant: String, url: URL, price: String, amount: Double,
                currency: String = "", kind: Kind = .other) {
        self.merchant = merchant
        self.url = url
        self.price = price
        self.amount = amount
        self.currency = currency
        self.kind = kind
    }
}

/// Fourth of the box clients, same shape as the other three: base URL + per-request JWT via
/// `BoxConfig.auth`, transport failures mapped to `BoxError`, 401/402 handled inside StashHTTP.
public struct HaulOffersClient {
    private let config: BoxConfig
    private let session: URLSession
    /// A live web search runs behind this call; it is the slow kind of request.
    private static let lookupTimeout: TimeInterval = 100

    public init(config: BoxConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// The ranked offers for one pick — empty is the honest "nothing ships there" answer.
    public func offers(name: String, kind: String, country: String) async throws -> [HaulOffer] {
        let url = config.baseURL.appendingPathComponent("haul/offers")
        var request = URLRequest(url: url, timeoutInterval: Self.lookupTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["name": name, "kind": kind, "country": country])
        let data = try await BoxHTTP.send(request, on: session, auth: config.auth)
        return try Self.decodeOffers(data)
    }

    /// Split from the request so the decode — the part with rules of its own — tests dry.
    static func decodeOffers(_ data: Data) throws -> [HaulOffer] {
        struct OffersResponse: Decodable { let offers: [HaulOffer] }
        do {
            return try JSONDecoder().decode(OffersResponse.self, from: data).offers
        } catch {
            throw BoxError.malformedPayload("offers response: \(error.localizedDescription)")
        }
    }
}
