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

public enum Category: String, Codable, Sendable { case recipe, music, coding, other }

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
    public var apiKey: String          // placeholder, default "local" (AtlasFlow pattern)
    public init(baseURL: URL, chatModel: String, whisperModel: String, apiKey: String = "local") {
        self.baseURL = baseURL
        self.chatModel = chatModel
        self.whisperModel = whisperModel
        self.apiKey = apiKey
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
