// SampleData.swift
//
// Seed content for the simulator smoke run and SwiftUI previews. Real data arrives through
// the Import screen; this only runs when launched with `-seedSample` and the store is empty.
//
// The category payloads (RecipeData / TrackData / CodeData) expose public fields but no public
// memberwise init, so we build the same JSON the pipeline would have encoded onto `Video` and
// store it directly — no invented Kit API.

import Foundation
import SwiftData
import TikTokBrainKit

enum SampleData {
    /// Seeds the sample videos when launched with `-seedSample` and the store is empty.
    static func seedIfRequested(_ container: ModelContainer) {
        let context = ModelContext(container)
        // `-seedFile <path>`: load a pre-processed dataset (simulator testing with real data).
        if let i = CommandLine.arguments.firstIndex(of: "-seedFile"), i + 1 < CommandLine.arguments.count {
            try? context.delete(model: Video.self)
            for video in loadSeedFile(CommandLine.arguments[i + 1]) { context.insert(video) }
            try? context.save()
            return
        }
        guard CommandLine.arguments.contains("-seedSample") else { return }
        let existing = (try? context.fetchCount(FetchDescriptor<Video>())) ?? 0
        guard existing == 0 else { return }
        for video in makeSampleVideos() { context.insert(video) }
        try? context.save()
    }

    /// Parses a JSON array of processed videos (see scratchpad pipeline) into `Video` rows.
    static func loadSeedFile(_ path: String) -> [Video] {
        guard let data = FileManager.default.contents(atPath: path),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        let seedDir = URL(fileURLWithPath: path).deletingLastPathComponent()
        let formatter = makeSeedDateFormatter()
        return items.enumerated().compactMap { index, item in
            guard let id = item["videoID"] as? String,
                  let urlString = item["url"] as? String,
                  let url = URL(string: urlString) else { return nil }
            // Real save date from the export when present; fabricated spacing otherwise.
            let date = (item["date"] as? String).flatMap(formatter.date(from:))
                ?? Date().addingTimeInterval(-Double(index) * 14_400) // 4h apart, newest first
            let video = Video(videoID: id, url: url, bookmarkedAt: date)
            // Thumbnail path relative to the seed file (pipeline downloads the jpgs).
            if let thumb = item["thumbnail"] as? String {
                video.thumbnailURL = seedDir.appendingPathComponent(thumb)
            }
            video.author = item["author"] as? String ?? ""
            video.caption = item["caption"] as? String ?? ""
            video.title = item["title"] as? String ?? ""
            video.summary = item["summary"] as? String ?? ""
            video.topics = item["topics"] as? [String] ?? []
            video.transcript = item["transcript"] as? String
            video.categoryRaw = (item["category"] as? String).flatMap { Category(rawValue: $0) }?.rawValue ?? ""
            if let recipe = item["recipe"] as? [String: Any] { video.recipeJSON = json(recipe) }
            if let track = item["track"] as? [String: Any] { video.trackJSON = json(track) }
            if let code = item["code"] as? [String: Any] { video.codeJSON = json(code) }
            let done: [String: StageState] = [
                "enrich": .done, "media": .done,
                "transcribe": video.transcript == nil ? .skipped : .done,
                "ocr": .skipped, "analyze": .done,
            ]
            video.stageStatesJSON = (try? JSONEncoder().encode(done)) ?? video.stageStatesJSON
            return video
        }
    }

    /// Eight videos spanning the categories plus one "needs a look" pile entry.
    static func makeSampleVideos() -> [Video] {
        [
            make(
                id: "7234567890123456789",
                url: "https://www.tiktok.com/@noodleworship/video/7234567890123456789",
                daysAgo: 1,
                author: "noodleworship",
                caption: "POV: 15-minute miso ramen #recipe #ramen",
                hashtags: ["recipe", "ramen"],
                category: .recipe,
                title: "15-minute miso ramen",
                summary: "A fast weeknight ramen built on instant dashi and white miso.",
                topics: ["ramen", "noodles", "quick dinners"],
                transcript: "Today we're making a quick weeknight miso ramen you can pull together in about fifteen minutes.",
                recipeJSON: json([
                    "name": "15-minute miso ramen",
                    "ingredients": ["2 cups dashi", "2 tbsp white miso", "1 pack ramen noodles", "1 soft-boiled egg", "2 scallions, sliced"],
                    "steps": ["Warm the dashi", "Whisk in the miso off the heat", "Cook the noodles separately", "Combine and top with the egg and scallions"],
                ])
            ),
            make(
                id: "7234567890000000001",
                url: "https://www.tiktok.com/@breadhead/video/7234567890000000001",
                daysAgo: 3,
                author: "breadhead",
                caption: "No-knead focaccia, minimum effort #recipe #bread",
                hashtags: ["recipe", "bread"],
                category: .recipe,
                title: "No-knead rosemary focaccia",
                summary: "An overnight, no-knead focaccia with a rosemary and flaky-salt top.",
                topics: ["bread", "baking"],
                transcript: "This focaccia is basically no work, you just have to plan a day ahead.",
                recipeJSON: json([
                    "name": "No-knead rosemary focaccia",
                    "ingredients": ["500g bread flour", "400g water", "10g salt", "5g instant yeast", "olive oil", "rosemary", "flaky salt"],
                    "steps": ["Mix and rest overnight in the fridge", "Dimple with oiled fingers", "Top with rosemary and flaky salt", "Bake at 220C for about 20 minutes"],
                ])
            ),
            make(
                id: "7234567890000000002",
                url: "https://www.tiktok.com/@nightdrive/video/7234567890000000002",
                daysAgo: 5,
                author: "nightdrive",
                caption: "this song on a night drive hits different",
                hashtags: ["music", "synthwave"],
                category: .music,
                title: "Midnight City",
                summary: "Synth anthem used as the backing track — resolved to a universal link.",
                topics: ["synthwave", "night drive"],
                transcript: nil,
                trackJSON: json([
                    "title": "Midnight City",
                    "artist": "M83",
                    "universalLink": "https://song.link/https%3A%2F%2Fmusic.apple.com%2Fus%2Falbum%2Fmidnight-city%2F1440843425%3Fi%3D1440843426",
                ])
            ),
            make(
                id: "7234567890000000006",
                url: "https://www.tiktok.com/@basslinediaries/video/7234567890000000006",
                daysAgo: 4,
                author: "basslinediaries",
                caption: "that bassline never misses",
                hashtags: ["music", "psychrock"],
                category: .music,
                title: "The Less I Know the Better",
                summary: "Psych-pop staple used as the backing track.",
                topics: ["psych pop"],
                transcript: nil,
                trackJSON: json([
                    "title": "The Less I Know the Better",
                    "artist": "Tame Impala",
                ])
            ),
            make(
                id: "7234567890000000007",
                url: "https://www.tiktok.com/@psychpopdaily/video/7234567890000000007",
                daysAgo: 2,
                author: "psychpopdaily",
                caption: "the drop at 1:52 is unreal",
                hashtags: ["music", "psychrock"],
                category: .music,
                title: "Let It Happen",
                summary: "Eight-minute opener condensed into a fifteen-second edit.",
                topics: ["psych pop"],
                transcript: nil,
                trackJSON: json([
                    "title": "Let It Happen",
                    "artist": "Tame Impala",
                ])
            ),
            make(
                id: "7234567890000000003",
                url: "https://www.tiktok.com/@swiftbits/video/7234567890000000003",
                daysAgo: 6,
                author: "swiftbits",
                caption: "actors explained in 60 seconds #swift #ios",
                hashtags: ["swift", "ios"],
                category: .coding,
                title: "Swift actors in 60 seconds",
                summary: "Why actors serialize access to their state and how that prevents data races.",
                topics: ["swift", "concurrency"],
                transcript: "An actor protects its own state by letting only one task touch it at a time.",
                codeJSON: json([
                    "summary": "Actors serialize access to mutable state, so cross-task access is race-free by construction.",
                    "links": ["https://developer.apple.com/documentation/swift/actor", "https://www.swift.org/documentation/concurrency/"],
                    "techTags": ["swift", "concurrency", "actors"],
                ])
            ),
            make(
                id: "7234567890000000004",
                url: "https://www.tiktok.com/@wandernotes/video/7234567890000000004",
                daysAgo: 8,
                author: "wandernotes",
                caption: "the one train pass that pays for itself in Japan #travel",
                hashtags: ["travel", "japan"],
                category: .other,
                title: "The train pass worth buying in Japan",
                summary: "When a regional rail pass beats paying per ride, with a quick break-even rule.",
                topics: ["travel", "japan"],
                transcript: "If you're doing more than two long trips, the regional pass basically pays for itself."
            ),
            unavailableSample(
                id: "7234567890000000005",
                url: "https://www.tiktok.com/@unknown/video/7234567890000000005",
                daysAgo: 10
            ),
        ]
    }

    // MARK: - Builders

    private static func make(
        id: String,
        url: String,
        daysAgo: Int,
        author: String,
        caption: String,
        hashtags: [String],
        category: Category,
        title: String,
        summary: String,
        topics: [String],
        transcript: String?,
        recipeJSON: Data? = nil,
        trackJSON: Data? = nil,
        codeJSON: Data? = nil
    ) -> Video {
        let video = Video(
            videoID: id,
            url: URL(string: url)!,
            bookmarkedAt: Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        )
        video.author = author
        video.caption = caption
        video.hashtags = hashtags
        video.categoryRaw = category.rawValue
        video.title = title
        video.summary = summary
        video.topics = topics
        video.transcript = transcript
        video.recipeJSON = recipeJSON
        video.trackJSON = trackJSON
        video.codeJSON = codeJSON

        let done: [String: StageState] = [
            "enrich": .done,
            "media": .done,
            "transcribe": transcript == nil ? .skipped : .done,
            "ocr": .done,
            "analyze": .done,
        ]
        video.stageStatesJSON = (try? JSONEncoder().encode(done)) ?? video.stageStatesJSON
        return video
    }

    private static func unavailableSample(id: String, url: String, daysAgo: Int) -> Video {
        let video = Video(
            videoID: id,
            url: URL(string: url)!,
            bookmarkedAt: Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        )
        video.unavailable = true
        let states: [String: StageState] = [
            "enrich": .failed, "media": .skipped, "transcribe": .skipped, "ocr": .skipped, "analyze": .skipped,
        ]
        video.stageStatesJSON = (try? JSONEncoder().encode(states)) ?? video.stageStatesJSON
        return video
    }

    /// Encodes a JSON object the same way the pipeline would store a category payload.
    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// Same date format the TikTok export uses (and `ExportParser` parses).
    private static func makeSeedDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}

extension SampleData {
    /// In-memory container populated with the sample videos, for SwiftUI previews.
    @MainActor
    static var previewContainer: ModelContainer {
        let container = try! ModelContainer(
            for: Video.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        for video in makeSampleVideos() { container.mainContext.insert(video) }
        return container
    }
}
