// Types.swift
import Foundation

public struct Bookmark: Equatable, Sendable {
    public let id: String          // TikTok video id parsed from URL (last numeric path component), else the full URL
    public let url: URL
    public let date: Date
    public init(id: String, url: URL, date: Date) { self.id = id; self.url = url; self.date = date }
}

public struct VideoMeta: Equatable, Sendable {
    public var caption: String
    public var hashtags: [String]
    public var author: String
    public var thumbnailURL: URL?
    public var soundTitle: String?
    public var soundArtist: String?
    public var streamURL: URL?
    public init(caption: String = "", hashtags: [String] = [], author: String = "",
                thumbnailURL: URL? = nil, soundTitle: String? = nil, soundArtist: String? = nil, streamURL: URL? = nil) {
        self.caption = caption
        self.hashtags = hashtags
        self.author = author
        self.thumbnailURL = thumbnailURL
        self.soundTitle = soundTitle
        self.soundArtist = soundArtist
        self.streamURL = streamURL
    }
}

public enum Category: String, Codable, Sendable {
    case recipe, fitness, style, travel, home, learning, comedy, music, coding, film, dining,
         wellness, other

    /// Tolerate an unknown or near-miss category from the model instead of throwing and
    /// failing the whole analysis decode — anything off-list falls back to `.other`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Category(rawValue: raw) ?? .other
    }
}

public struct RecipeData: Codable, Equatable, Sendable { public var name: String; public var ingredients: [String]; public var steps: [String] }
/// Legacy single-track shape. Superseded by `MusicPick`; kept only so saves written before
/// multi-pick extraction, and any in-flight model response still using the old key, still read.
public struct TrackData: Codable, Equatable, Sendable { public var title: String; public var artist: String; public var universalLink: URL? }
/// The coding payload. `kind` and `items` arrived with the shaped Code screen; saves analyzed
/// before then decode with `kind == nil` and no items and keep rendering as the plain note.
public struct CodeData: Codable, Equatable, Sendable {
    public static let maxItems = 25

    public var summary: String
    public var links: [URL]
    public var techTags: [String]
    /// The shape of the post, or nil for a legacy save or an off-list answer from the model.
    public var kind: Kind?
    /// One entry per point the post makes, in source order, cleaned by `CodeItem.cleaned`.
    public var items: [CodeItem]

    private enum CodingKeys: String, CodingKey { case summary, links, techTags, kind, items }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        links = try values.decodeIfPresent([URL].self, forKey: .links) ?? []
        techTags = try values.decodeIfPresent([String].self, forKey: .techTags) ?? []
        kind = (try? values.decode(String.self, forKey: .kind)).flatMap(Kind.init(rawValue:))
        items = CodeItem.cleaned((try? values.decode([CodeItem].self, forKey: .items)) ?? [])
    }
}

/// One release a video recommends.
///
/// A video that names a single song produces one of these; one that runs through five albums
/// produces five. The count is the only difference between the two cases — there is no separate
/// "list" type to keep in step with this one.
public struct MusicPick: Codable, Equatable, Sendable {
    /// Which iTunes entity to search, and what the link should point at. A "top 5 albums" video
    /// and a "top 5 songs" video need different queries, and only the video knows which it is.
    public enum Kind: String, Codable, Sendable { case album, track }

    /// Bounds the model's output. No real recommendation video lists more than this, and an
    /// unbounded array is an unbounded number of iTunes lookups.
    public static let maxPerVideo = 12

    public var kind: Kind
    public var title: String
    /// Empty when the video does not name one. Never guessed — an invented artist is how the
    /// wrong release gets linked.
    public var artist: String
    /// Resolved streaming link, or nil when nothing matched confidently. A nil link is a
    /// deliberate outcome, not a missing value: the name still shows, unlinked.
    public var link: URL?

    public init(kind: Kind, title: String, artist: String = "", link: URL? = nil) {
        self.kind = kind
        self.title = title
        self.artist = artist
        self.link = link
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // An unrecognised kind is a track: the narrower query, and the one that fails visibly
        // rather than silently linking a whole album for a single song.
        kind = (try? values.decode(Kind.self, forKey: .kind)) ?? .track
        title = (try values.decodeIfPresent(String.self, forKey: .title) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        artist = (try values.decodeIfPresent(String.self, forKey: .artist) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        link = try values.decodeIfPresent(URL.self, forKey: .link)
    }
}

/// One thing a video is plainly trying to make you buy.
///
/// Cross-cutting on purpose, and this is the only payload that is. A save is filed under exactly
/// one `Category`, but the sneakers in a style video, the lens in a travel vlog and the standing
/// desk in a home tour are all the same note — *you wanted this*. Filing them by category would
/// scatter one shopping list across four shelves, so picks hang off every analysis instead and
/// the Haul shelf is a query, not a segment.
public struct BuyPick: Codable, Equatable, Sendable {
    /// A haul video runs through a bagful; a review covers one. Past this the model has stopped
    /// listing recommendations and started listing props.
    public static let maxPerVideo = 8

    /// Brand and model as the video says them — "Nike Vomero 5", not "running shoes". This is
    /// what gets typed into a store's search box, so a vague name is a useless pick.
    public var name: String
    /// Short lowercase noun the shelf groups by: "sneakers", "phone", "serum". Empty when the
    /// video never makes the kind clear.
    public var kind: String
    /// The price exactly as stated ("€39", "under $20"). Empty rather than estimated — of
    /// everything in this struct, an invented price is the one that could cost somebody money.
    public var price: String
    /// A link the video itself gave. Usually nil; `Shop.searchURL` is how the rest reach a store.
    public var link: URL?

    public init(name: String, kind: String = "", price: String = "", link: URL? = nil) {
        self.name = name
        self.kind = kind
        self.price = price
        self.link = link
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = (try values.decodeIfPresent(String.self, forKey: .name) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        kind = (try values.decodeIfPresent(String.self, forKey: .kind) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        price = (try values.decodeIfPresent(String.self, forKey: .price) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        link = try values.decodeIfPresent(URL.self, forKey: .link)
    }
}

/// Where a pick can be looked up. No affiliate tags, no product API, no price scraping: a search
/// URL is a link, and a link needs no key, no quota and no privacy policy of its own.
public enum Shop: String, CaseIterable, Codable, Sendable {
    case amazon, google

    public var label: String {
        switch self {
        case .amazon: "Amazon"
        case .google: "Google"
        }
    }

    /// Amazon by region. Defaults to `.de` because there is no worldwide amazon.com search that
    /// ships anywhere useful, and a European reader sent to the US store gets a store that will
    /// not sell to them — a wrong-but-nearby storefront beats a right-but-unreachable one.
    static func amazonHost(region: String?) -> String {
        let domains = [
            "US": "com", "CA": "ca", "MX": "com.mx", "BR": "com.br",
            "GB": "co.uk", "IE": "co.uk", "FR": "fr", "ES": "es", "IT": "it",
            "NL": "nl", "BE": "com.be", "SE": "se", "PL": "pl", "TR": "com.tr",
            "JP": "co.jp", "AU": "com.au", "IN": "in", "SG": "sg", "AE": "ae",
        ]
        return "www.amazon." + (region.flatMap { domains[$0] } ?? "de")
    }

    public func searchURL(for query: String, region: String? = Locale.current.region?.identifier) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        switch self {
        case .amazon:
            components.host = Self.amazonHost(region: region)
            components.path = "/s"
            components.queryItems = [URLQueryItem(name: "k", value: trimmed)]
        case .google:
            components.host = "www.google.com"
            components.path = "/search"
            // `tbm=shop` is Google's shopping tab: results are products with prices rather than
            // ten reviews of the product.
            components.queryItems = [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "tbm", value: "shop"),
            ]
        }
        return components.url
    }
}

public struct Analysis: Codable, Equatable, Sendable {
    public var category: Category
    public var title: String
    public var summary: String
    public var topics: [String]
    public var recipe: RecipeData?
    /// Every release the video recommends, in the order it showed them. Empty for non-music.
    public var music: [MusicPick]
    /// Every movie explicitly named or shown, in source order. Empty for non-film analyses.
    public var films: [FilmPick]
    /// Whether the decoded response actually carried `films`. This is deliberately not encoded:
    /// it only distinguishes legacy responses from an explicit empty array while persisting.
    public var hasFilmPayload: Bool
    public var code: CodeData?
    /// Everything the video is selling, whatever it was filed under. Empty for the vast majority.
    public var buys: [BuyPick]

    public init(category: Category, title: String, summary: String, topics: [String] = [],
                recipe: RecipeData? = nil, music: [MusicPick] = [], code: CodeData? = nil,
                buys: [BuyPick] = [], films: [FilmPick] = []) {
        self.category = category
        self.title = title
        self.summary = summary
        self.topics = topics
        self.recipe = recipe
        self.music = music
        self.films = FilmPick.cleaned(films)
        self.hasFilmPayload = true
        self.code = code
        self.buys = buys
    }

    private enum CodingKeys: String, CodingKey {
        case category, title, summary, topics, recipe, music, films, code, buys
    }
    /// Read-only: the pre-multi-pick key. Declared separately so `encode(to:)` stays synthesized
    /// and nothing ever writes the old shape back out.
    private enum LegacyKeys: String, CodingKey { case track }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        category = try values.decode(Category.self, forKey: .category)
        title = try values.decode(String.self, forKey: .title)
        summary = try values.decode(String.self, forKey: .summary)
        topics = try values.decodeIfPresent([String].self, forKey: .topics) ?? []
        recipe = try values.decodeIfPresent(RecipeData.self, forKey: .recipe)
        code = try values.decodeIfPresent(CodeData.self, forKey: .code)
        hasFilmPayload = values.contains(.films)
            && ((try? values.decodeNil(forKey: .films)) == false)
        films = hasFilmPayload ? values.decodeFilmPicksIfPresent(forKey: .films) : []
        // A nameless pick is a pick nothing can be searched for; drop it here rather than
        // letting the shelf render a blank row.
        buys = Array((try values.decodeIfPresent([BuyPick].self, forKey: .buys) ?? [])
            .filter { !$0.name.isEmpty }.prefix(BuyPick.maxPerVideo))

        if let picks = try values.decodeIfPresent([MusicPick].self, forKey: .music) {
            music = Array(picks.filter { !$0.title.isEmpty }.prefix(MusicPick.maxPerVideo))
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent(TrackData.self, forKey: .track), !legacy.title.isEmpty {
            music = [MusicPick(kind: .track, title: legacy.title,
                               artist: legacy.artist, link: legacy.universalLink)]
        } else {
            music = []
        }
    }
}

public struct BoxConfig: Sendable {
    public var baseURL: URL            // e.g. http://box:8000/v1  (runtime config; never committed)
    public var chatModel: String
    public var whisperModel: String
    /// Per-user auth, asked for the token on every request: a bearer captured once when the
    /// runner was built goes stale the moment the session refreshes mid-drain, and leaves no
    /// seam for the refresh-on-401 retry.
    public var auth: StashAuthProvider
    public init(baseURL: URL, chatModel: String, whisperModel: String,
                auth: StashAuthProvider = .fixed({ "local" })) {
        self.baseURL = baseURL
        self.chatModel = chatModel
        self.whisperModel = whisperModel
        self.auth = auth
    }
}

public enum BoxError: Error, Equatable {
    case unreachable(String)           // connection refused / timeout — "is Tailscale up and the box online?"
    case badResponse(Int)
    case malformedPayload(String)
}

public enum StageState: String, Codable, Sendable { case pending, running, done, failed, awaitingBox, skipped }

public struct MediaBundle: Sendable {
    public let audioFileURL: URL?
    public let keyframes: [URL]        // temp png files
    public init(audioFileURL: URL?, keyframes: [URL]) {
        self.audioFileURL = audioFileURL
        self.keyframes = keyframes
    }
}
