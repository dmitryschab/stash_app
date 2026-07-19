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
        XCTAssertNil(recipe.trackJSON)

        // Music video: track payload carries the resolved universal link.
        let music = try XCTUnwrap(fetchVideo("7000000000000000002", in: container))
        XCTAssertFalse(music.unavailable)
        XCTAssertEqual(music.categoryRaw, Category.music.rawValue)
        let trackData = try JSONDecoder().decode(TrackData.self, from: XCTUnwrap(music.trackJSON))
        XCTAssertEqual(trackData.title, "Example Song")
        XCTAssertEqual(trackData.artist, "Example Artist")
        XCTAssertEqual(trackData.universalLink, songLink)
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

private struct StubMusicResolver: MusicLinkResolving {
    var link: URL?
    func universalLink(title: String, artist: String) async throws -> URL? { link }
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
                track: nil,
                code: nil)
        }
        if meta.hashtags.contains("music") {
            return Analysis(
                category: .music,
                title: "Example Song",
                summary: "A catchy track.",
                topics: ["pop"],
                recipe: nil,
                track: TrackData(title: "Example Song", artist: "Example Artist", universalLink: nil),
                code: nil)
        }
        return Analysis(
            category: .other,
            title: transcript ?? "no-transcript",
            summary: "",
            topics: [],
            recipe: nil,
            track: nil,
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
