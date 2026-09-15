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
    /// Legacy single track. Nothing writes this any more; `music` reads it when `musicJSON` is
    /// nil so a library saved before multi-pick extraction is not blank until re-analysis runs.
    public var trackJSON: Data?
    public var musicJSON: Data?           // JSONEncoder-encoded [MusicPick]
    public var codeJSON: Data?
    /// JSONEncoder-encoded [BuyPick]. Optional with a default, so adding it is a SwiftData
    /// lightweight migration and an existing library opens unchanged — it simply has no picks
    /// until the analysis that fills them runs again.
    public var buysJSON: Data?
    /// Local product choices, separate from replaceable analysis. Optional for existing stores;
    /// deleting the video or clearing the account's library also removes these choices.
    public var haulStatesJSON: Data? = nil
    public var stageStatesJSON: Data      // [String: StageState] encoded; keys: enrich, media, transcribe, ocr, analyze
    public var unavailable: Bool
    public var cloudAnalysisRevision: Int = 0
    /// Search's meaning half: `EmbeddingVector.pack`ed Float32, nil until the backfill fills it.
    /// Optional with a default, so this is a SwiftData lightweight migration and an existing
    /// library opens unchanged.
    public var embedding: Data?
    /// Which generation of embeddings `embedding` came from; 0 = none yet. See
    /// `BoxEmbeddingClient.revision`.
    public var embeddingRevision: Int = 0
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
        self.musicJSON = nil
        self.codeJSON = nil
        self.buysJSON = nil
        let initialStages: [String: StageState] = [
            "enrich": .pending, "media": .pending, "transcribe": .pending, "ocr": .pending, "analyze": .pending,
        ]
        self.stageStatesJSON = (try? JSONEncoder().encode(initialStages)) ?? Data()
        self.unavailable = false
        self.cloudAnalysisRevision = 0
        self.embedding = nil
        self.embeddingRevision = 0
    }
}

public extension Video {
    /// What gets embedded: everything the analysis produced, then as much of the raw text as is
    /// worth paying for.
    ///
    /// The transcript and OCR text are truncated because they are the long ones and the front of
    /// them is the part about the video — a five-minute transcript's tail is outro and sign-off,
    /// and it would crowd the title and topics out of one 256-dimension vector.
    var embeddingText: String {
        [
            title,
            topics.joined(separator: " "),
            summary,
            caption,
            String((transcript ?? "").prefix(1000)),
            String((ocrText ?? "").prefix(500)),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
}
