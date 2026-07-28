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
    case recipe, fitness, style, travel, home, learning, comedy, music, coding, other

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
public struct CodeData: Codable, Equatable, Sendable { public var summary: String; public var links: [URL]; public var techTags: [String] }

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

public struct Analysis: Codable, Equatable, Sendable {
    public var category: Category
    public var title: String
    public var summary: String
    public var topics: [String]
    public var recipe: RecipeData?
    /// Every release the video recommends, in the order it showed them. Empty for non-music.
    public var music: [MusicPick]
    public var code: CodeData?

    public init(category: Category, title: String, summary: String, topics: [String] = [],
                recipe: RecipeData? = nil, music: [MusicPick] = [], code: CodeData? = nil) {
        self.category = category
        self.title = title
        self.summary = summary
        self.topics = topics
        self.recipe = recipe
        self.music = music
        self.code = code
    }

    private enum CodingKeys: String, CodingKey {
        case category, title, summary, topics, recipe, music, code
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
