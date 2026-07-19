// Entities.swift — SwiftData
import Foundation
import SwiftData

@Model public final class Video {
    @Attribute(.unique) public var videoID: String
    public var url: URL
    public var bookmarkedAt: Date
    public var author: String
    public var caption: String
    public var hashtags: [String]
    public var thumbnailURL: URL?
    public var transcript: String?
    public var ocrText: String?
    public var categoryRaw: String        // Category.rawValue; "" = not yet analyzed
    public var title: String
    public var summary: String
    public var topics: [String]
    public var recipeJSON: Data?          // JSONEncoder-encoded RecipeData
    public var trackJSON: Data?
    public var codeJSON: Data?
    public var stageStatesJSON: Data      // [String: StageState] encoded; keys: enrich, media, transcribe, ocr, analyze
    public var unavailable: Bool
    public var cloudAnalysisRevision: Int = 0
    // Filename under Application Support/OfflineVideos, relative because absolute
    // container URLs break across reinstalls. nil = not kept offline.
    public var offlineVideoFilename: String?
    public init(videoID: String, url: URL, bookmarkedAt: Date) {
        self.videoID = videoID
        self.url = url
        self.bookmarkedAt = bookmarkedAt
        self.author = ""
        self.caption = ""
        self.hashtags = []
        self.thumbnailURL = nil
        self.transcript = nil
        self.ocrText = nil
        self.categoryRaw = ""
        self.title = ""
        self.summary = ""
        self.topics = []
        self.recipeJSON = nil
        self.trackJSON = nil
        self.codeJSON = nil
        let initialStages: [String: StageState] = [
            "enrich": .pending, "media": .pending, "transcribe": .pending, "ocr": .pending, "analyze": .pending,
        ]
        self.stageStatesJSON = (try? JSONEncoder().encode(initialStages)) ?? Data()
        self.unavailable = false
        self.cloudAnalysisRevision = 0
        self.offlineVideoFilename = nil
    }
}
