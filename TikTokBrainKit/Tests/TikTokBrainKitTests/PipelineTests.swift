import XCTest
import SwiftData
@testable import TikTokBrainKit

final class PipelineTests: XCTestCase {

    // MARK: - In-memory container

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Video.self, configurations: configuration)
    }

    private func fetchVideo(_ id: String, in container: ModelContainer) throws -> Video? {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<Video>(predicate: #Predicate<Video> { $0.videoID == id })).first
    }

    private func stages(_ video: Video) throws -> [String: StageState] {
        try JSONDecoder().decode([String: StageState].self, from: video.stageStatesJSON)
    }

    // MARK: - Golden path: recipe + music + unavailable

    func testGoldenPathProcessesRecipeMusicAndUnavailable() async throws {
        let container = try makeContainer()

        let recipeURL = URL(string: "https://www.tiktok.com/@noodleworship/video/7000000000000000001")!
        let musicURL = URL(string: "https://www.tiktok.com/@dj/video/7000000000000000002")!
        let deadURL = URL(string: "https://www.tiktok.com/@ghost/video/7000000000000000003")!
        let streamURL = URL(string: "https://v16.example/play/abc.mp4")!
        let songLink = URL(string: "https://song.link/https%3A%2F%2Fmusic.apple.com%2Fus%2Fexample")!

        let recipeMeta = VideoMeta(
            caption: "POV 15-minute miso ramen",
            hashtags: ["recipe", "ramen"],
            author: "noodleworship",
            thumbnailURL: URL(string: "https://p16.example/cover.jpg"),
            streamURL: streamURL)
        let musicMeta = VideoMeta(
            caption: "this song is stuck in my head",
            hashtags: ["music"],
            author: "dj",
            soundTitle: "Example Song",
            soundArtist: "Example Artist",
            streamURL: streamURL)

        let bundle = MediaBundle(
            audioFileURL: URL(fileURLWithPath: "/tmp/tiktokbrain-test-audio.m4a"),
            keyframes: [URL(fileURLWithPath: "/tmp/tiktokbrain-test-frame.png")])

        let deps = PipelineDeps(
            enricher: StubEnricher(
                metasByURL: [recipeURL.absoluteString: recipeMeta,
                             musicURL.absoluteString: musicMeta],
                failingURLs: [deadURL.absoluteString]),
            media: StubMedia(bundle: bundle),
            transcriber: StubTranscriber(transcript: "boil the noodles"),
            analyzer: StubAnalyzer(),
            musicResolver: StubMusicResolver(link: songLink),
            ocr: { _ in "MISO RAMEN" })

        let runner = PipelineRunner(deps: deps, container: container)

        let bookmarks = [
            Bookmark(id: "7000000000000000001", url: recipeURL, date: Date(timeIntervalSince1970: 300)),
            Bookmark(id: "7000000000000000002", url: musicURL, date: Date(timeIntervalSince1970: 200)),
            Bookmark(id: "7000000000000000003", url: deadURL, date: Date(timeIntervalSince1970: 100)),
        ]

        let inserted = try await runner.ingest(bookmarks: bookmarks)
        XCTAssertEqual(inserted, 3)

        let recorder = ProgressRecorder()
        await runner.processAll(progress: { done, total in recorder.record(done, total) })
        // Fast pass + transcript backfill = at least one progress call per video;
        // exact counts depend on worker pipelining, so assert the floor and bounds.
        XCTAssertGreaterThanOrEqual(recorder.calls.count, 3)
        for (done, total) in recorder.calls { XCTAssertLessThanOrEqual(done, total) }

        // Recipe video: fully processed, recipe payload round-trips.
        let recipe = try XCTUnwrap(fetchVideo("7000000000000000001", in: container))
        XCTAssertFalse(recipe.unavailable)
        XCTAssertEqual(recipe.categoryRaw, Category.recipe.rawValue)
        XCTAssertEqual(recipe.author, "noodleworship")
        XCTAssertEqual(recipe.transcript, "boil the noodles")
        XCTAssertNil(recipe.ocrText)  // OCR cut for the cloud release
        let recipeStages = try stages(recipe)
        XCTAssertEqual(recipeStages["enrich"], .done)
        XCTAssertEqual(recipeStages["media"], .skipped)  // box owns media now
        XCTAssertEqual(recipeStages["transcribe"], .done)
        XCTAssertEqual(recipeStages["ocr"], .skipped)
        XCTAssertEqual(recipeStages["analyze"], .done)
        let recipeData = try JSONDecoder().decode(RecipeData.self, from: XCTUnwrap(recipe.recipeJSON))
        XCTAssertEqual(recipeData,
                       RecipeData(name: "Miso Ramen",
                                  ingredients: ["miso paste", "noodles"],
                                  steps: ["boil water", "serve"]))
        XCTAssertNil(recipe.musicJSON)

        // Music video: the pick list carries the resolved universal link.
        let music = try XCTUnwrap(fetchVideo("7000000000000000002", in: container))
        XCTAssertFalse(music.unavailable)
        XCTAssertEqual(music.categoryRaw, Category.music.rawValue)
        let picks = try JSONDecoder().decode([MusicPick].self, from: XCTUnwrap(music.musicJSON))
        XCTAssertEqual(picks, [MusicPick(kind: .track, title: "Example Song",
                                         artist: "Example Artist", link: songLink)])
        XCTAssertNil(music.recipeJSON)

        // Enrich threw: video is flagged unavailable and its later stages are skipped.
        let dead = try XCTUnwrap(fetchVideo("7000000000000000003", in: container))
        XCTAssertTrue(dead.unavailable)
        XCTAssertEqual(dead.categoryRaw, "")
        let deadStages = try stages(dead)
        XCTAssertEqual(deadStages["enrich"], .failed)
        XCTAssertEqual(deadStages["media"], .skipped)
        XCTAssertEqual(deadStages["transcribe"], .skipped)
        XCTAssertEqual(deadStages["ocr"], .skipped)
        XCTAssertEqual(deadStages["analyze"], .skipped)

        // Queue drained.
        let more = try await runner.processNext()
        XCTAssertFalse(more)
    }

    // MARK: - Box unreachable during transcribe

    func testTranscriberUnreachableParksStageButStillAnalyzes() async throws {
        let container = try makeContainer()

        let url = URL(string: "https://www.tiktok.com/@x/video/7000000000000000009")!
        let meta = VideoMeta(
            caption: "some clip",
            hashtags: [],
            author: "x",
            streamURL: URL(string: "https://v16.example/s.mp4")!)
        let bundle = MediaBundle(
            audioFileURL: URL(fileURLWithPath: "/tmp/tiktokbrain-test-a.m4a"),
            keyframes: [URL(fileURLWithPath: "/tmp/tiktokbrain-test-f.png")])

        let deps = PipelineDeps(
            enricher: StubEnricher(metasByURL: [url.absoluteString: meta]),
            media: StubMedia(bundle: bundle),
            transcriber: StubTranscriber(unreachable: true),
            analyzer: StubAnalyzer(),
            musicResolver: StubMusicResolver(link: nil),
            ocr: { _ in "SCREEN TEXT" })

        let runner = PipelineRunner(deps: deps, container: container)
        _ = try await runner.ingest(bookmarks: [Bookmark(id: "7000000000000000009", url: url, date: Date())])

        let processed = try await runner.processNext()
        XCTAssertTrue(processed)

        let video = try XCTUnwrap(fetchVideo("7000000000000000009", in: container))
        let s = try stages(video)
        XCTAssertEqual(s["media"], .skipped)
        XCTAssertEqual(s["transcribe"], .awaitingBox)   // parked, not failed
        XCTAssertEqual(s["ocr"], .skipped)
        XCTAssertEqual(s["analyze"], .done)             // analysis still ran
        XCTAssertNil(video.transcript)                  // no transcript captured
        XCTAssertNil(video.ocrText)
        // StubAnalyzer echoes the transcript it received, proving analyze saw `nil`.
        XCTAssertEqual(video.title, "no-transcript")
        XCTAssertEqual(video.categoryRaw, Category.other.rawValue)
    }

    // MARK: - Progress reflects the whole imported library

    func testProgressReportsClassifiedOfTotalImported() async throws {
        let container = try makeContainer()
        let liveURL = URL(string: "https://www.tiktok.com/@a/video/7000000000000000010")!
        let deadURL = URL(string: "https://www.tiktok.com/@b/video/7000000000000000011")!
        let deps = PipelineDeps(
            enricher: StubEnricher(
                metasByURL: [liveURL.absoluteString: VideoMeta(caption: "clip", author: "a")],
                failingURLs: [deadURL.absoluteString]),
            media: StubMedia(bundle: MediaBundle(audioFileURL: nil, keyframes: [])),
            transcriber: StubTranscriber(transcript: nil),
            analyzer: StubAnalyzer(),
            musicResolver: StubMusicResolver(link: nil),
            ocr: { _ in "" })
        let runner = PipelineRunner(deps: deps, container: container)
        _ = try await runner.ingest(bookmarks: [
            Bookmark(id: "7000000000000000010", url: liveURL, date: Date(timeIntervalSince1970: 20)),
            Bookmark(id: "7000000000000000011", url: deadURL, date: Date(timeIntervalSince1970: 10)),
        ])

        let recorder = ProgressRecorder()
        await runner.processAll(progress: { d, t in recorder.record(d, t) })

        // Total is always the imported count, never the shrinking pending count.
        XCTAssertFalse(recorder.calls.isEmpty)
        for (_, total) in recorder.calls { XCTAssertEqual(total, 2) }
        // Both are terminal: the live video is classified, the dead one hard-failed.
        let counts = try await runner.processedCounts()
        XCTAssertEqual(counts.done, 2)
        XCTAssertEqual(counts.total, 2)
        XCTAssertEqual(recorder.calls.last?.0, 2)
    }

    func testProgressStaysCumulativeAcrossRelaunch() async throws {
        let container = try makeContainer()
        let firstURL = URL(string: "https://www.tiktok.com/@a/video/7000000000000000020")!
        let secondURL = URL(string: "https://www.tiktok.com/@b/video/7000000000000000021")!
        let deps = PipelineDeps(
            enricher: StubEnricher(metasByURL: [
                firstURL.absoluteString: VideoMeta(caption: "one", author: "a"),
                secondURL.absoluteString: VideoMeta(caption: "two", author: "b"),
            ]),
            media: StubMedia(bundle: MediaBundle(audioFileURL: nil, keyframes: [])),
            transcriber: StubTranscriber(transcript: nil),
            analyzer: StubAnalyzer(),
            musicResolver: StubMusicResolver(link: nil),
            ocr: { _ in "" })
        let runner = PipelineRunner(deps: deps, container: container)

        // First import + drain.
        _ = try await runner.ingest(bookmarks: [
            Bookmark(id: "7000000000000000020", url: firstURL, date: Date(timeIntervalSince1970: 20))])
        await runner.processAll(progress: { _, _ in })
        let afterFirst = try await runner.processedCounts()
        XCTAssertEqual(afterFirst.done, 1)
        XCTAssertEqual(afterFirst.total, 1)

        // Relaunch: importing more must not reset the done count to zero.
        _ = try await runner.ingest(bookmarks: [
            Bookmark(id: "7000000000000000021", url: secondURL, date: Date(timeIntervalSince1970: 10))])
        let recorder = ProgressRecorder()
        await runner.processAll(progress: { d, t in recorder.record(d, t) })

        let first = try XCTUnwrap(recorder.calls.first)
        XCTAssertEqual(first.1, 2)                // total = full imported count
        XCTAssertGreaterThanOrEqual(first.0, 1)   // already-processed video still counts
        XCTAssertEqual(recorder.calls.last?.0, 2) // both done at the end
    }

    // MARK: - Ingest de-duplication

    func testIngestDeduplicatesByVideoID() async throws {
        let container = try makeContainer()
        let deps = PipelineDeps(
            enricher: StubEnricher(),
            media: StubMedia(bundle: MediaBundle(audioFileURL: nil, keyframes: [])),
            transcriber: StubTranscriber(),
            analyzer: StubAnalyzer(),
            musicResolver: StubMusicResolver(link: nil),
            ocr: { _ in "" })
        let runner = PipelineRunner(deps: deps, container: container)

        let url = URL(string: "https://www.tiktok.com/@a/video/111")!
        let first = try await runner.ingest(bookmarks: [Bookmark(id: "111", url: url, date: Date())])
        XCTAssertEqual(first, 1)

        // Re-ingesting the same id (across calls and within a batch) inserts nothing new.
        let second = try await runner.ingest(bookmarks: [
            Bookmark(id: "111", url: url, date: Date()),
            Bookmark(id: "111", url: url, date: Date()),
        ])
        XCTAssertEqual(second, 0)

        let all = try ModelContext(container).fetch(FetchDescriptor<Video>())
        XCTAssertEqual(all.count, 1)
    }
}

// MARK: - Fakes

private struct StubEnricher: Enriching {
    var metasByURL: [String: VideoMeta] = [:]
    var failingURLs: Set<String> = []
    func enrich(_ url: URL) async throws -> VideoMeta {
        if failingURLs.contains(url.absoluteString) { throw StubError.enrichFailed }
        return metasByURL[url.absoluteString] ?? VideoMeta()
    }
}

private struct StubMedia: MediaFetching {
    var bundle: MediaBundle
    func fetch(streamURL: URL) async throws -> MediaBundle { bundle }
}

private struct StubTranscriber: Transcribing {
    var transcript: String? = "transcript"
    var unreachable: Bool = false
    func transcript(for videoURL: URL) async throws -> String? {
        if unreachable { throw BoxError.unreachable("(is Tailscale up and the box online?) stub") }
        return transcript
    }
}

/// Records how many transcript calls are in flight at the same moment.
private actor ConcurrencyWatcher {
    private var current = 0
    private(set) var peak = 0

    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

/// Holds each call open long enough for its siblings to start, so a serial queue and a
/// parallel one give measurably different peaks.
private struct WatchingTranscriber: Transcribing {
    let watcher: ConcurrencyWatcher
    func transcript(for videoURL: URL) async throws -> String? {
        await watcher.enter()
        try? await Task.sleep(nanoseconds: 20_000_000)
        await watcher.leave()
        return "boil the noodles"
    }
}

private struct StubMusicResolver: MusicLinkResolving {
    var link: URL?
    func resolve(_ picks: [MusicPick]) async -> [MusicPick] {
        picks.map { var pick = $0; pick.link = link; return pick }
    }
}

extension PipelineTests {
    /// Re-analysis re-buckets an already-classified video from its STORED fields, with no
    /// enrich/transcribe — the enricher/transcriber here would fatal if the pass touched them.
    /// On-screen text is stored and drives a re-analysis, and a second run finds nothing left.
    func testBackfillVisualTextStoresOCRAndReanalyzes() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let video = Video(
            videoID: "7000000000000000012",
            url: URL(string: "https://www.tiktok.com/@x/video/7000000000000000012")!,
            bookmarkedAt: Date(timeIntervalSince1970: 700))
        video.caption = ""                                // no caption at all…
        video.hashtags = ["recipe"]
        video.categoryRaw = Category.other.rawValue
        context.insert(video)
        try context.save()

        let deps = PipelineDeps(
            enricher: StubEnricher(metasByURL: [:], failingURLs: []),
            media: StubMedia(bundle: MediaBundle(
                audioFileURL: URL(fileURLWithPath: "/dev/null"), keyframes: [])),
            transcriber: StubTranscriber(transcript: "unused"),
            analyzer: StubAnalyzer(),
            musicResolver: StubMusicResolver(link: nil),
            ocr: { _ in "" })
        let runner = PipelineRunner(deps: deps, container: container)

        // …the words on screen are the only real signal.
        let first = await runner.backfillVisualText(
            deepPass: { _, _ in DeepPass(visualText: "MISO RAMEN\n2 eggs\nboil 4 minutes") },
            progress: { _, _ in })
        XCTAssertEqual(first.filled, 1)
        XCTAssertFalse(first.stoppedEarly)

        let updated = try XCTUnwrap(fetchVideo("7000000000000000012", in: container))
        // Stored in the frame-marked format so the legacy re-read cannot pick it up again.
        XCTAssertEqual(updated.ocrText, "[1] MISO RAMEN\n2 eggs\nboil 4 minutes")
        XCTAssertEqual(updated.categoryRaw, Category.recipe.rawValue)

        let second = await runner.backfillVisualText(
            deepPass: { _, _ in DeepPass(visualText: "should not be called") }, progress: { _, _ in })
        XCTAssertEqual(second.attempted, 0)
    }

    /// The other half of the same download: a save whose artist the model refused to guess gets
    /// one from the audio, even though there is not a word on screen — and the filled pick goes
    /// back through the catalogue, because a title with an artist can be looked up properly and a
    /// title without one could not.
    func testTheAudioMatchFillsAMissingArtistAndReResolvesThePick() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let video = Video(
            videoID: "7000000000000000051",
            url: URL(string: "https://www.tiktok.com/@x/video/7000000000000000051")!,
            bookmarkedAt: Date(timeIntervalSince1970: 1100))
        video.categoryRaw = Category.music.rawValue
        video.musicJSON = try JSONEncoder().encode(
            [MusicPick(kind: .track, title: "Polaris", artist: "")])
        context.insert(video)
        try context.save()

        let seen = SeenPicks()
        let deps = PipelineDeps(
            enricher: StubEnricher(metasByURL: [:], failingURLs: []),
            media: StubMedia(bundle: MediaBundle(audioFileURL: nil, keyframes: [])),
            transcriber: StubTranscriber(transcript: ""),
            analyzer: StubAnalyzer(),
            musicResolver: RecordingMusicResolver(seen: seen),
            ocr: { _ in "" })
        let runner = PipelineRunner(deps: deps, container: container)

        let result = await runner.backfillVisualText(deepPass: { _, _ in
            DeepPass(audioMatch: AudioMatch(title: "Polaris", artist: "KMC"))
        }) { _, _ in }
        XCTAssertEqual(result.attempted, 1)

        let stored = try XCTUnwrap(fetchVideo("7000000000000000051", in: container))
        XCTAssertNil(stored.ocrText, "there was nothing to read, so nothing was stored")
        XCTAssertEqual(stored.categoryRaw, Category.music.rawValue, "no text, no re-analysis")
        let picks = try JSONDecoder().decode([MusicPick].self, from: XCTUnwrap(stored.musicJSON))
        XCTAssertEqual(picks, [MusicPick(kind: .track, title: "Polaris", artist: "KMC")])
        XCTAssertEqual(seen.titles, ["Polaris"], "the filled pick was offered to the catalogue")
    }

    /// The backfill fills a missing transcript, re-analyzes with it, and — crucially — does not
    /// pick the same video up again on a second run (otherwise a no-speech save loops forever).
    func testBackfillTranscriptsFillsThenStopsRepeating() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let video = Video(
            videoID: "7000000000000000011",
            url: URL(string: "https://www.tiktok.com/@x/video/7000000000000000011")!,
            bookmarkedAt: Date(timeIntervalSince1970: 600))
        video.caption = "POV miso ramen"
        video.hashtags = ["recipe"]
        video.categoryRaw = Category.other.rawValue
        context.insert(video)
        try context.save()

        let deps = PipelineDeps(
            enricher: StubEnricher(metasByURL: [:], failingURLs: []),
            media: StubMedia(bundle: MediaBundle(
                audioFileURL: URL(fileURLWithPath: "/dev/null"), keyframes: [])),
            transcriber: StubTranscriber(transcript: "boil the noodles"),
            analyzer: StubAnalyzer(),
            musicResolver: StubMusicResolver(link: nil),
            ocr: { _ in "" })
        let runner = PipelineRunner(deps: deps, container: container)

        let first = await runner.backfillTranscripts { _, _ in }
        XCTAssertEqual(first.filled, 1)
        XCTAssertFalse(first.stoppedEarly)

        let updated = try XCTUnwrap(fetchVideo("7000000000000000011", in: container))
        XCTAssertEqual(updated.transcript, "boil the noodles")
        XCTAssertEqual(updated.categoryRaw, Category.recipe.rawValue)  // re-analyzed with audio

        // Second run finds nothing left to do — resumable, not repeating.
        let second = await runner.backfillTranscripts { _, _ in }
        XCTAssertEqual(second.attempted, 0)
    }

    /// The point of the backfill rewrite: the queue overlaps instead of running one at a time.
    /// Guards the regression that matters — a change that quietly serialises this again turns a
    /// half-hour library re-run back into a multi-hour one, and every other test still passes.
    func testBackfillTranscriptsRunsVideosInParallel() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        for index in 0..<16 {
            let id = "70000000000000001\(String(format: "%02d", index))"
            let video = Video(videoID: id,
                              url: URL(string: "https://www.tiktok.com/@x/video/\(id)")!,
                              bookmarkedAt: Date(timeIntervalSince1970: TimeInterval(600 + index)))
            video.caption = "POV miso ramen"
            context.insert(video)
        }
        try context.save()

        let watcher = ConcurrencyWatcher()
        let deps = PipelineDeps(
            enricher: StubEnricher(metasByURL: [:], failingURLs: []),
            media: StubMedia(bundle: MediaBundle(
                audioFileURL: URL(fileURLWithPath: "/dev/null"), keyframes: [])),
            transcriber: WatchingTranscriber(watcher: watcher),
            analyzer: StubAnalyzer(),
            musicResolver: StubMusicResolver(link: nil),
            ocr: { _ in "" })
        let runner = PipelineRunner(deps: deps, container: container)

        let result = await runner.backfillTranscripts { _, _ in }
        XCTAssertEqual(result.filled, 16)
        XCTAssertFalse(result.stoppedEarly)

        let peak = await watcher.peak
        XCTAssertGreaterThan(peak, 1, "backfill ran one video at a time")
        XCTAssertLessThanOrEqual(peak, 8, "backfill exceeded its concurrency cap")
    }

    /// A shared TikTok needs its transcript and on-screen text immediately, but the library
    /// behind it is usually full of saves missing both. Without `only`, saving one video would
    /// drag the whole backlog along and spend the month's budget on the first share.
    func testBackfillsHonourTheOnlyFilter() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        for (index, id) in ["7000000000000000021", "7000000000000000022"].enumerated() {
            let video = Video(
                videoID: id,
                url: URL(string: "https://www.tiktok.com/@x/video/\(id)")!,
                bookmarkedAt: Date(timeIntervalSince1970: TimeInterval(800 + index)))
            video.caption = "POV miso ramen"
            video.categoryRaw = Category.other.rawValue
            context.insert(video)
        }
        try context.save()

        let deps = PipelineDeps(
            enricher: StubEnricher(metasByURL: [:], failingURLs: []),
            media: StubMedia(bundle: MediaBundle(
                audioFileURL: URL(fileURLWithPath: "/dev/null"), keyframes: [])),
            transcriber: StubTranscriber(transcript: "boil the noodles"),
            analyzer: StubAnalyzer(),
            musicResolver: StubMusicResolver(link: nil),
            ocr: { _ in "" })
        let runner = PipelineRunner(deps: deps, container: container)

        let transcripts = await runner.backfillTranscripts(only: ["7000000000000000021"]) { _, _ in }
        XCTAssertEqual(transcripts.filled, 1)
        XCTAssertEqual(transcripts.attempted, 1, "the unnamed video must not be touched")

        let visual = await runner.backfillVisualText(
            only: ["7000000000000000021"],
            deepPass: { _, _ in DeepPass(visualText: "MISO RAMEN") },
            progress: { _, _ in })
        XCTAssertEqual(visual.filled, 1)
        XCTAssertEqual(visual.attempted, 1)

        let named = try XCTUnwrap(fetchVideo("7000000000000000021", in: container))
        XCTAssertEqual(named.transcript, "boil the noodles")
        XCTAssertEqual(named.ocrText, "[1] MISO RAMEN")

        let untouched = try XCTUnwrap(fetchVideo("7000000000000000022", in: container))
        XCTAssertNil(untouched.transcript)
        XCTAssertNil(untouched.ocrText)
        XCTAssertEqual(try stages(untouched)[PipelineStage.transcribe.rawValue], .pending)

        // …and the same runner without the filter still sees the one that was skipped.
        let rest = await runner.backfillTranscripts { _, _ in }
        XCTAssertEqual(rest.attempted, 1)
    }

    /// The end of the chain this change exists for: a video recommending five releases stores
    /// five, in order, and every one of them was offered to the resolver.
    func testAFiveReleaseVideoStoresFivePicksAndResolvesEach() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let video = Video(
            videoID: "7666837555224136981",
            url: URL(string: "https://www.tiktok.com/@reznikmusic/video/7666837555224136981")!,
            bookmarkedAt: Date(timeIntervalSince1970: 900))
        video.caption = "5 jungle projects"
        video.categoryRaw = Category.other.rawValue
        context.insert(video)
        try context.save()

        let picks = ["Dreamcore, Vol. 1", "Atlantis (I Need You)",
                     "Reflections / Secret Portraits", "Genesis", "Polaris"]
            .map { MusicPick(kind: .album, title: $0) }
        let seen = SeenPicks()
        let deps = PipelineDeps(
            enricher: StubEnricher(metasByURL: [:], failingURLs: []),
            media: StubMedia(bundle: MediaBundle(
                audioFileURL: URL(fileURLWithPath: "/dev/null"), keyframes: [])),
            transcriber: StubTranscriber(transcript: ""),
            analyzer: FixedAnalyzer(analysis: Analysis(
                category: .music, title: "5 jungle projects", summary: "Jungle picks.",
                topics: ["jungle"], music: picks)),
            musicResolver: RecordingMusicResolver(seen: seen),
            ocr: { _ in "" })
        let runner = PipelineRunner(deps: deps, container: container)

        await runner.reanalyzeAll { _, _ in }

        let stored = try XCTUnwrap(fetchVideo("7666837555224136981", in: container))
        let decoded = try JSONDecoder().decode([MusicPick].self, from: XCTUnwrap(stored.musicJSON))
        XCTAssertEqual(decoded.map(\.title), picks.map(\.title))
        XCTAssertEqual(seen.titles, picks.map(\.title), "every pick reached the resolver")
        XCTAssertNil(stored.trackJSON, "the legacy single-track copy is cleared, not left stale")
    }

    /// A library saved before multi-pick extraction must not go blank between this shipping and
    /// the re-analysis pass finishing.
    func testALegacyTrackOnlyVideoStillDecodesAsOnePick() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let video = Video(
            videoID: "7000000000000000031",
            url: URL(string: "https://www.tiktok.com/@x/video/7000000000000000031")!,
            bookmarkedAt: Date(timeIntervalSince1970: 100))
        video.trackJSON = try JSONEncoder().encode(
            TrackData(title: "Example Song", artist: "Example Artist",
                      universalLink: URL(string: "https://song.link/x")))
        context.insert(video)
        try context.save()

        // Mirrors the app's `Video.music` accessor: musicJSON first, legacy trackJSON after.
        let stored = try XCTUnwrap(fetchVideo("7000000000000000031", in: container))
        XCTAssertNil(stored.musicJSON)
        let legacy = try JSONDecoder().decode(TrackData.self, from: XCTUnwrap(stored.trackJSON))
        XCTAssertEqual(legacy.title, "Example Song")
        XCTAssertEqual(legacy.universalLink?.absoluteString, "https://song.link/x")
    }

    /// On-screen text read before frame grouping is a flat pool with no sense of which title
    /// goes with which artist — the thing that made the analyzer pair "Polaris" with "M". It is
    /// worth one unit to read again. Text already in the marked format is not.
    func testLegacyFlatOCRIsReReadExactlyOnce() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        for (id, stored) in [("7000000000000000041", "Polaris\nM\nKMC"),
                             ("7000000000000000042", "[1] Polaris | KMC")] {
            let video = Video(videoID: id,
                              url: URL(string: "https://www.tiktok.com/@x/video/\(id)")!,
                              bookmarkedAt: Date(timeIntervalSince1970: 1000))
            video.categoryRaw = Category.music.rawValue
            video.ocrText = stored
            context.insert(video)
        }
        try context.save()

        let read = SeenPicks()
        let deps = PipelineDeps(
            enricher: StubEnricher(metasByURL: [:], failingURLs: []),
            media: StubMedia(bundle: MediaBundle(audioFileURL: nil, keyframes: [])),
            transcriber: StubTranscriber(transcript: ""),
            analyzer: StubAnalyzer(),
            musicResolver: StubMusicResolver(link: nil),
            ocr: { _ in "" })
        let runner = PipelineRunner(deps: deps, container: container)
        let extractor: @Sendable (String, URL) async throws -> DeepPass = { id, _ in
            read.record([id])
            return DeepPass(visualText: "[1] Polaris | KMC")
        }

        let first = await runner.backfillVisualText(deepPass: extractor) { _, _ in }
        XCTAssertEqual(first.attempted, 1)
        XCTAssertEqual(read.titles, ["7000000000000000041"],
                       "only the flat one is re-read; the marked one is left alone")

        // Terminates: the re-read stored marked text, so a second run finds nothing.
        let second = await runner.backfillVisualText(deepPass: extractor) { _, _ in }
        XCTAssertEqual(second.attempted, 0, "re-reading must not repeat every run")
    }

    /// A reader that returns unmarked text still gets stored marked, or the check above would
    /// re-read it forever — an unbounded spend with no visible cause.
    func testUnmarkedReaderOutputIsStoredMarked() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let video = Video(videoID: "7000000000000000043",
                          url: URL(string: "https://www.tiktok.com/@x/video/7000000000000000043")!,
                          bookmarkedAt: Date(timeIntervalSince1970: 1000))
        video.categoryRaw = Category.music.rawValue
        context.insert(video)
        try context.save()

        let deps = PipelineDeps(
            enricher: StubEnricher(metasByURL: [:], failingURLs: []),
            media: StubMedia(bundle: MediaBundle(audioFileURL: nil, keyframes: [])),
            transcriber: StubTranscriber(transcript: ""),
            analyzer: StubAnalyzer(),
            musicResolver: StubMusicResolver(link: nil),
            ocr: { _ in "" })
        let runner = PipelineRunner(deps: deps, container: container)

        _ = await runner.backfillVisualText(
            deepPass: { _, _ in DeepPass(visualText: "no markers here") }) { _, _ in }
        let stored = try XCTUnwrap(fetchVideo("7000000000000000043", in: container))
        XCTAssertEqual(stored.ocrText, "[1] no markers here")

        let second = await runner.backfillVisualText(
            deepPass: { _, _ in DeepPass(visualText: "unused") }) { _, _ in }
        XCTAssertEqual(second.attempted, 0)
    }

    func testReanalyzeAllRebucketsFromStoredFields() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let video = Video(
            videoID: "7000000000000000010",
            url: URL(string: "https://www.tiktok.com/@x/video/7000000000000000010")!,
            bookmarkedAt: Date(timeIntervalSince1970: 500))
        video.caption = "POV miso ramen"
        video.hashtags = ["recipe"]           // StubAnalyzer classifies recipe from this
        video.categoryRaw = Category.other.rawValue  // stale bucket from an older taxonomy
        video.title = "old title"
        context.insert(video)
        try context.save()

        let deps = PipelineDeps(
            enricher: StubEnricher(metasByURL: [:], failingURLs: []),
            media: StubMedia(bundle: MediaBundle(
                audioFileURL: URL(fileURLWithPath: "/dev/null"), keyframes: [])),
            transcriber: StubTranscriber(transcript: "unused"),
            analyzer: StubAnalyzer(),
            musicResolver: StubMusicResolver(link: nil),
            ocr: { _ in "" })
        let runner = PipelineRunner(deps: deps, container: container)

        await runner.reanalyzeAll { _, _ in }

        let updated = try XCTUnwrap(fetchVideo("7000000000000000010", in: container))
        XCTAssertEqual(updated.categoryRaw, Category.recipe.rawValue)  // re-bucketed
        XCTAssertEqual(updated.title, "Miso Ramen")                    // re-analyzed
    }

    func testFilmAnalysisPersistsAnExplicitEmptyPickList() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let video = Video(
            videoID: "film-empty",
            url: URL(string: "https://www.tiktok.com/@x/video/film-empty")!,
            bookmarkedAt: Date(timeIntervalSince1970: 1))
        video.categoryRaw = Category.film.rawValue
        context.insert(video)
        try context.save()

        let runner = PipelineRunner(
            deps: PipelineDeps(
                enricher: StubEnricher(metasByURL: [:], failingURLs: []),
                media: StubMedia(bundle: MediaBundle(audioFileURL: nil, keyframes: [])),
                transcriber: StubTranscriber(transcript: ""),
                analyzer: FixedAnalyzer(analysis: Analysis(
                    category: .film, title: "Films", summary: "", films: [])),
                musicResolver: StubMusicResolver(link: nil),
                ocr: { _ in "" }),
            container: container)

        await runner.reanalyzeAll { _, _ in }

        let stored = try XCTUnwrap(fetchVideo("film-empty", in: container))
        XCTAssertNotNil(stored.filmsJSON)
        XCTAssertEqual(stored.films, [])
    }

    func testLegacyFilmAnalysisWithoutFilmsFieldPreservesNilMigrationMarker() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let video = Video(
            videoID: "film-legacy-response",
            url: URL(string: "https://www.tiktok.com/@x/video/film-legacy-response")!,
            bookmarkedAt: Date(timeIntervalSince1970: 1))
        video.categoryRaw = Category.film.rawValue
        context.insert(video)
        try context.save()
        let legacy = try JSONDecoder().decode(
            Analysis.self,
            from: #"{"category":"film","title":"Films","summary":"","topics":[]}"#.data(using: .utf8)!
        )
        let runner = PipelineRunner(
            deps: PipelineDeps(
                enricher: StubEnricher(metasByURL: [:], failingURLs: []),
                media: StubMedia(bundle: MediaBundle(audioFileURL: nil, keyframes: [])),
                transcriber: StubTranscriber(transcript: ""),
                analyzer: FixedAnalyzer(analysis: legacy),
                musicResolver: StubMusicResolver(link: nil),
                ocr: { _ in "" }),
            container: container)

        await runner.reanalyzeAll { _, _ in }

        let stored = try XCTUnwrap(fetchVideo("film-legacy-response", in: container))
        XCTAssertNil(stored.filmsJSON)
    }

    func testReanalysisAwayFromFilmClearsStalePicks() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let video = Video(
            videoID: "film-reclassified",
            url: URL(string: "https://www.tiktok.com/@x/video/film-reclassified")!,
            bookmarkedAt: Date(timeIntervalSince1970: 1))
        video.categoryRaw = Category.film.rawValue
        video.filmsJSON = try JSONEncoder().encode([FilmPick(title: "Arrival", year: 2016)])
        context.insert(video)
        try context.save()

        let runner = PipelineRunner(
            deps: PipelineDeps(
                enricher: StubEnricher(metasByURL: [:], failingURLs: []),
                media: StubMedia(bundle: MediaBundle(audioFileURL: nil, keyframes: [])),
                transcriber: StubTranscriber(transcript: ""),
                analyzer: FixedAnalyzer(analysis: Analysis(
                    category: .other, title: "Not a film list", summary: "")),
                musicResolver: StubMusicResolver(link: nil),
                ocr: { _ in "" }),
            container: container)

        await runner.reanalyzeAll { _, _ in }

        let stored = try XCTUnwrap(fetchVideo("film-reclassified", in: container))
        XCTAssertEqual(stored.categoryRaw, Category.other.rawValue)
        XCTAssertNil(stored.filmsJSON)
        XCTAssertEqual(stored.films, [])
    }
}

/// Classifies from the stub metadata; for anything uncategorised it echoes the transcript
/// it received (or "no-transcript") so tests can assert what `analyze` was handed.
private struct StubAnalyzer: Analyzing {
    func analyze(meta: VideoMeta, transcript: String?, ocrText: String?) async throws -> Analysis {
        if meta.hashtags.contains("recipe") {
            return Analysis(
                category: .recipe,
                title: "Miso Ramen",
                summary: "Quick miso ramen.",
                topics: ["ramen", "noodles"],
                recipe: RecipeData(name: "Miso Ramen",
                                   ingredients: ["miso paste", "noodles"],
                                   steps: ["boil water", "serve"]),
                music: [],
                code: nil)
        }
        if meta.hashtags.contains("music") {
            return Analysis(
                category: .music,
                title: "Example Song",
                summary: "A catchy track.",
                topics: ["pop"],
                recipe: nil,
                music: [MusicPick(kind: .track, title: "Example Song", artist: "Example Artist")],
                code: nil)
        }
        return Analysis(
            category: .other,
            title: transcript ?? "no-transcript",
            summary: "",
            topics: [],
            recipe: nil,
            music: [],
            code: nil)
    }
}

private enum StubError: Error { case enrichFailed }

/// Thread-safe recorder for `processAll` progress callbacks (the closure is `@Sendable`).
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(Int, Int)] = []
    var calls: [(Int, Int)] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func record(_ done: Int, _ total: Int) {
        lock.lock(); defer { lock.unlock() }
        storage.append((done, total))
    }
}

/// Returns one canned analysis regardless of input — for asserting what the pipeline does with
/// the model's answer, rather than what the model answers.
private struct FixedAnalyzer: Analyzing {
    let analysis: Analysis
    func analyze(meta: VideoMeta, transcript: String?, ocrText: String?) async throws -> Analysis {
        analysis
    }
}

/// Records which picks were offered for resolution, so the test can assert none was dropped
/// on the way from the model's answer to the catalogue lookup.
final class SeenPicks: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func record(_ values: [String]) { lock.lock(); stored.append(contentsOf: values); lock.unlock() }
    var titles: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

private struct RecordingMusicResolver: MusicLinkResolving {
    let seen: SeenPicks
    func resolve(_ picks: [MusicPick]) async -> [MusicPick] {
        seen.record(picks.map(\.title))
        return picks
    }
}

final class PipelineRerunTests: XCTestCase {
    /// The detail screen's "Re-run pipeline" must touch exactly its own video: `processAll`
    /// drains every pending save in the library, which on a half-imported library is hundreds
    /// of TikTok fetches for one tap.
    func testProcessOneVideoLeavesTheRestOfTheQueueAlone() async throws {
        let container = try ModelContainer(
            for: Video.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let tapped = URL(string: "https://www.tiktok.com/@a/video/7000000000000000011")!
        let other = URL(string: "https://www.tiktok.com/@b/video/7000000000000000012")!
        let meta = VideoMeta(caption: "POV 15-minute miso ramen", hashtags: ["recipe"], author: "a")
        let deps = PipelineDeps(
            enricher: StubEnricher(metasByURL: [tapped.absoluteString: meta, other.absoluteString: meta]),
            media: StubMedia(bundle: MediaBundle(audioFileURL: URL(fileURLWithPath: "/tmp/x.m4a"), keyframes: [])),
            transcriber: StubTranscriber(transcript: "boil"),
            analyzer: StubAnalyzer(),
            musicResolver: StubMusicResolver(link: nil),
            ocr: { _ in "" })
        let runner = PipelineRunner(deps: deps, container: container)
        _ = try await runner.ingest(bookmarks: [
            Bookmark(id: "7000000000000000011", url: tapped, date: Date(timeIntervalSince1970: 200)),
            Bookmark(id: "7000000000000000012", url: other, date: Date(timeIntervalSince1970: 100)),
        ])
        // The screen's own instance, held before the run — what SwiftUI is looking at.
        let ui = ModelContext(container)
        let held = try XCTUnwrap(ui.fetch(FetchDescriptor<Video>(
            predicate: #Predicate<Video> { $0.videoID == "7000000000000000011" })).first)

        await runner.process(videoID: "7000000000000000011")

        let fresh = ModelContext(container)
        let all = try fresh.fetch(FetchDescriptor<Video>(sortBy: [SortDescriptor(\.videoID)]))
        let states = try all.map { try JSONDecoder().decode([String: StageState].self, from: $0.stageStatesJSON) }
        XCTAssertEqual(states[0]["enrich"], .done)
        XCTAssertEqual(all[0].recipeJSON != nil, true)
        XCTAssertEqual(states[1]["enrich"], .pending, "the other pending save must not have been touched")
        // The runner writes on its own context, so an instance another context already holds
        // stays stale until that context fetches again — which is what the screen's @Query does.
        XCTAssertNil(held.recipeJSON)
        _ = try ui.fetch(FetchDescriptor<Video>(predicate: #Predicate<Video> { $0.videoID == "7000000000000000011" }))
        XCTAssertNotNil(held.recipeJSON, "a fetch on the holding context refreshes the held instance")
    }
}
