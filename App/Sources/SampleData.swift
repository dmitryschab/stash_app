// SampleData.swift
//
// Seed content for three callers: the simulator smoke run (`-seedSample`), SwiftUI previews,
// and the App Review demo library. Real data arrives through the Import screen; a reviewer has
// no TikTok export, so an account created from a `--demo` invite comes back `"demo": true` and
// seeds this same content once (see StashSession.isDemoAccount and RootView).
//
// ponytail: one body of sample content for all three, seeded on the client. The library is
// local SwiftData, so seeding it server-side would mean inventing a whole discovery path for
// imports the client never created — this is one flag on the invite and no new data pipeline.
// The ceiling is that the demo library is obviously demo content: invented handles, URLs that
// do not resolve, no thumbnails.
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

    private static let demoSeedKey = "demoLibrarySeededFor"

    /// Seeds the App Review demo library. Keyed on the user id rather than a bare "done" bool:
    /// a relaunch must not duplicate it, and a second demo account signing in on the same
    /// device has had the previous library wiped (RootView.discardForeignLibrary) so it needs
    /// its own copy.
    static func seedDemoLibrary(into context: ModelContext, userID: String) {
        guard UserDefaults.standard.string(forKey: demoSeedKey) != userID else { return }
        for video in makeSampleVideos() { context.insert(video) }
        try? context.save()
        UserDefaults.standard.set(userID, forKey: demoSeedKey)
    }

    /// Forgets that marker. Deleting the account wipes the library but not the user id, so a
    /// reviewer who exercises guideline 5.1.1(v) and then signs back in would otherwise land
    /// in the empty app the demo library exists to prevent.
    static func forgetDemoSeed() {
        UserDefaults.standard.removeObject(forKey: demoSeedKey)
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

    /// Twenty analyzed videos covering all ten library segments — Cook, Music, Today, Search
    /// and the mind map each need real content of their own — plus one "needs a look" entry.
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
                id: "7234567890000000008",
                url: "https://www.tiktok.com/@panfriday/video/7234567890000000008",
                daysAgo: 7,
                author: "panfriday",
                caption: "one pan lemon orzo, nothing to drain #recipe #dinner",
                hashtags: ["recipe", "dinner"],
                category: .recipe,
                title: "One-pan lemon orzo",
                summary: "Orzo cooked straight in the stock with lemon and spinach — one pan, no draining.",
                topics: ["one pan", "quick dinners"],
                transcript: "The orzo cooks in the stock, so the starch stays in the pan and thickens the sauce.",
                recipeJSON: json([
                    "name": "One-pan lemon orzo",
                    "ingredients": ["300g orzo", "700ml chicken stock", "1 lemon", "2 cloves garlic", "100g spinach", "parmesan"],
                    "steps": ["Soften the garlic in oil", "Add the orzo and the stock", "Simmer 9 minutes, stirring", "Fold in the spinach, lemon and parmesan"],
                ])
            ),
            make(
                id: "7234567890000000009",
                url: "https://www.tiktok.com/@picklejar/video/7234567890000000009",
                daysAgo: 9,
                author: "picklejar",
                caption: "smashed cucumbers, five minutes, no cooking #recipe",
                hashtags: ["recipe", "sides"],
                category: .recipe,
                title: "Smashed cucumber salad",
                summary: "Cucumbers smashed so the dressing sticks, salted first to draw the water out.",
                topics: ["salads", "quick dinners"],
                transcript: "Smash them instead of slicing — the torn edges hold about twice as much dressing.",
                recipeJSON: json([
                    "name": "Smashed cucumber salad",
                    "ingredients": ["4 mini cucumbers", "1 tsp salt", "2 tbsp rice vinegar", "1 tbsp soy sauce", "1 tsp chilli oil", "1 clove garlic"],
                    "steps": ["Smash and tear the cucumbers", "Salt them and rest 15 minutes", "Pour off the water", "Toss with the dressing just before serving"],
                ])
            ),
            make(
                id: "7234567890000000010",
                url: "https://www.tiktok.com/@sweetlab/video/7234567890000000010",
                daysAgo: 12,
                author: "sweetlab",
                caption: "two ingredient chocolate mousse, no eggs #recipe #dessert",
                hashtags: ["recipe", "dessert"],
                category: .recipe,
                title: "Two-ingredient chocolate mousse",
                summary: "Chocolate and water whipped over ice — no eggs, no cream.",
                topics: ["dessert", "baking"],
                transcript: "It is only chocolate and water. Whipping it over ice is what turns it into mousse.",
                recipeJSON: json([
                    "name": "Two-ingredient chocolate mousse",
                    "ingredients": ["200g dark chocolate", "200ml water", "pinch of salt"],
                    "steps": ["Melt the chocolate into the hot water", "Set the bowl over ice", "Whisk until it thickens", "Stop the moment it holds a peak"],
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
                id: "7234567890000000011",
                url: "https://www.tiktok.com/@vinylhours/video/7234567890000000011",
                daysAgo: 19,
                author: "vinylhours",
                caption: "the bassline that owns every slow motion edit",
                hashtags: ["music", "funk"],
                category: .music,
                title: "Redbone",
                summary: "Funk-soul slow burn used as the backing track.",
                topics: ["funk", "soul"],
                transcript: nil,
                trackJSON: json([
                    "title": "Redbone",
                    "artist": "Childish Gambino",
                ])
            ),
            make(
                id: "7234567890000000012",
                url: "https://www.tiktok.com/@lateshiftfm/video/7234567890000000012",
                daysAgo: 11,
                author: "lateshiftfm",
                caption: "when the beat switches at 3:00",
                hashtags: ["music", "rnb"],
                category: .music,
                title: "Nights",
                summary: "The mid-song beat switch everyone clips, used as the backing track.",
                topics: ["r&b"],
                transcript: nil,
                trackJSON: json([
                    "title": "Nights",
                    "artist": "Frank Ocean",
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
                id: "7234567890000000013",
                url: "https://www.tiktok.com/@terminalhabits/video/7234567890000000013",
                daysAgo: 13,
                author: "terminalhabits",
                caption: "stop stashing, start worktreeing #git #devtools",
                hashtags: ["git", "devtools"],
                category: .coding,
                title: "git worktree instead of git stash",
                summary: "Check the other branch out into its own directory instead of putting work in progress down.",
                topics: ["git", "developer tools"],
                transcript: "A worktree gives the other branch its own folder, so nothing has to be stashed first.",
                codeJSON: json([
                    "summary": "git worktree add ../hotfix main checks a branch out beside the repo and leaves the current tree untouched.",
                    "links": ["https://git-scm.com/docs/git-worktree"],
                    "techTags": ["git", "cli"],
                ])
            ),
            make(
                id: "7234567890000000014",
                url: "https://www.tiktok.com/@gridwitch/video/7234567890000000014",
                daysAgo: 15,
                author: "gridwitch",
                caption: "subgrid is why your cards finally line up #css #webdev",
                hashtags: ["css", "webdev"],
                category: .coding,
                title: "CSS subgrid in one minute",
                summary: "Subgrid lets a child inherit the parent's tracks, so every card's title lands on one line.",
                topics: ["css", "layout"],
                transcript: "Without subgrid each card lays itself out alone, which is why the titles never agree.",
                codeJSON: json([
                    "summary": "grid-template-rows: subgrid makes a nested grid use its parent's track lines instead of its own.",
                    "links": ["https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_grid_layout/Subgrid"],
                    "techTags": ["css", "layout", "frontend"],
                ])
            ),
            make(
                id: "7234567890000000015",
                url: "https://www.tiktok.com/@slowmileclub/video/7234567890000000015",
                daysAgo: 14,
                author: "slowmileclub",
                caption: "if it feels too easy you are doing zone 2 right #running",
                hashtags: ["running", "fitness"],
                category: .fitness,
                title: "Zone 2 is meant to feel slow",
                summary: "Why most easy runs get run too hard, and the talk test that fixes it.",
                topics: ["running", "endurance"],
                transcript: "If you cannot hold a full sentence while you run, that is not zone two any more."
            ),
            make(
                id: "7234567890000000016",
                url: "https://www.tiktok.com/@closetmath/video/7234567890000000016",
                daysAgo: 16,
                author: "closetmath",
                caption: "three colours, that is the whole rule #style",
                hashtags: ["style", "outfits"],
                category: .style,
                title: "The three-colour rule",
                summary: "Hold an outfit to three colours and let texture carry the rest.",
                topics: ["outfits", "colour"],
                transcript: "Three colours maximum. Past that it reads as busy no matter how good the pieces are."
            ),
            make(
                id: "7234567890000000017",
                url: "https://www.tiktok.com/@slowtrains/video/7234567890000000017",
                daysAgo: 18,
                author: "slowtrains",
                caption: "Lisbon in a day, no car, no queues #travel",
                hashtags: ["travel", "lisbon"],
                category: .travel,
                title: "Lisbon in a day on foot",
                summary: "A walking route that takes the viewpoints downhill and skips the tram queue entirely.",
                topics: ["lisbon", "city walks"],
                transcript: "Start at the top and walk down — every viewpoint on this route is below the last one."
            ),
            make(
                id: "7234567890000000018",
                url: "https://www.tiktok.com/@rentersfix/video/7234567890000000018",
                daysAgo: 20,
                author: "rentersfix",
                caption: "a shelf that holds 20kg and leaves zero holes #home #renting",
                hashtags: ["home", "diy"],
                category: .home,
                title: "A shelf with no drilling",
                summary: "Two tension rods and a plank: a shelf that comes down without patching the wall.",
                topics: ["renting", "storage"],
                transcript: "The load sits on the rods, not the wall, which is the whole point when you are renting."
            ),
            make(
                id: "7234567890000000019",
                url: "https://www.tiktok.com/@factminute/video/7234567890000000019",
                daysAgo: 22,
                author: "factminute",
                caption: "Greenland is not that big #maps",
                hashtags: ["maps", "learning"],
                category: .learning,
                title: "Why the Mercator map lies",
                summary: "A projection that keeps angles honest has to stretch area, and it stretches most at the poles.",
                topics: ["maps", "geography"],
                transcript: "Greenland looks about the size of Africa on a wall map. It is roughly fourteen times smaller."
            ),
            make(
                id: "7234567890000000020",
                url: "https://www.tiktok.com/@deskjob/video/7234567890000000020",
                daysAgo: 17,
                author: "deskjob",
                caption: "every standup, every morning #comedy #wfh",
                hashtags: ["comedy", "work"],
                category: .comedy,
                title: "Every standup meeting ever",
                summary: "The nine-minute status round that could have been one line in a channel.",
                topics: ["work", "meetings"],
                transcript: "Yesterday I was in meetings. Today I am in meetings. No blockers."
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
