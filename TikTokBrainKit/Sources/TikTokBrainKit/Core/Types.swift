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
public struct TrackData: Codable, Equatable, Sendable { public var title: String; public var artist: String; public var universalLink: URL? }
public struct CodeData: Codable, Equatable, Sendable { public var summary: String; public var links: [URL]; public var techTags: [String] }

public struct Analysis: Codable, Equatable, Sendable {
    public var category: Category
    public var title: String
    public var summary: String
    public var topics: [String]
    public var recipe: RecipeData?
    public var track: TrackData?
    public var code: CodeData?
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
