# TikTok Brain iOS Prototype Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working, tested iOS prototype that ingests a TikTok export zip, runs the enrich→transcribe→OCR→analyze pipeline (ML on the Tailscale model box), and shows Library / Mind map / Import / Video detail screens.

**Architecture:** All logic lives in a SwiftPM package `TikTokBrainKit` (builds and tests on macOS — fast `swift test`, no simulator). The iOS app is a thin SwiftUI shell generated with XcodeGen. Box clients follow AtlasFlow's DiffusionGemma pattern (OpenAI-compatible, base URL from settings, "unreachable" error).

**Tech Stack:** Swift 6.3 / SwiftUI / SwiftData, SwiftPM, XcodeGen, XCTest. No third-party Swift dependencies (stdlib + Foundation + AVFoundation + Vision only).

## Global Constraints

- Platforms: `.iOS(.v17), .macOS(.v14)` in Package.swift. Kit code must compile on both (UI code is App-only).
- English-only v1; non-English videos must never block the pipeline (transcript is optional everywhere).
- No secrets or tailnet URLs committed anywhere. Box base URL is runtime config; tests use `http://localhost:9`.
- Every pipeline stage is best-effort: a stage failure records state and later stages run with what exists.
- Agents/workers: do NOT run `git commit` (parallel workers share the repo; the orchestrator commits per phase).
- Root for all paths below: `tiktok-brain/` in the repo root.
- Copy style: sentence case, no exclamation marks (per CDS content rules in spec mockups).

## File Structure

```
tiktok-brain/
  TikTokBrainKit/
    Package.swift
    Sources/TikTokBrainKit/
      Core/Types.swift            # Task 1: Bookmark, VideoMeta, Analysis, Category, BoxConfig, BoxError, StageState
      Core/Protocols.swift        # Task 1: Enriching, MediaFetching, Transcribing, Analyzing, MusicLinkResolving
      Core/Entities.swift         # Task 1: SwiftData @Model Video, Topic (Recipe/Track/CodeNote as Codable payloads on Video)
      ExportParser.swift          # Task 2
      Enricher.swift              # Task 3
      BoxClients.swift            # Task 4: TranscriberClient + AnalyzerClient
      MusicLinkResolver.swift     # Task 5
      MediaFetcher.swift          # Task 6
      Pipeline.swift              # Task 7: PipelineRunner + InMemoryJobQueue persistence via SwiftData
    Tests/TikTokBrainKitTests/
      Fixtures/export-user_data.json
      Fixtures/video-page.html
      Fixtures/itunes-search.json
      ExportParserTests.swift
      EnricherTests.swift
      BoxClientsTests.swift
      MusicLinkResolverTests.swift
      MediaFetcherTests.swift
      PipelineTests.swift
  App/
    project.yml                   # Task 8: XcodeGen
    Sources/
      TikTokBrainApp.swift        # Task 8: @main, tab bar, SwiftData container
      Theme.swift                 # Task 8: category colors (coral/pink/teal/purple)
      LibraryView.swift           # Task 8
      MindMapView.swift           # Task 8
      ImportView.swift            # Task 8
      VideoDetailView.swift       # Task 8
      SampleData.swift            # Task 8: preview/sample content
```

---

### Task 1: Core types, protocols, SwiftData entities

**Files:**
- Create: `tiktok-brain/TikTokBrainKit/Package.swift`
- Create: `tiktok-brain/TikTokBrainKit/Sources/TikTokBrainKit/Core/Types.swift`
- Create: `tiktok-brain/TikTokBrainKit/Sources/TikTokBrainKit/Core/Protocols.swift`
- Create: `tiktok-brain/TikTokBrainKit/Sources/TikTokBrainKit/Core/Entities.swift`
- Test: compilation is the test (`swift build && swift test` with an empty test target)

**Interfaces (Produces — VERBATIM contract for all other tasks):**

```swift
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
                thumbnailURL: URL? = nil, soundTitle: String? = nil, soundArtist: String? = nil, streamURL: URL? = nil)
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
    public init(baseURL: URL, chatModel: String, whisperModel: String, apiKey: String = "local")
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
    public init(audioFileURL: URL?, keyframes: [URL])
}
```

```swift
// Protocols.swift
import Foundation

public protocol Enriching: Sendable { func enrich(_ url: URL) async throws -> VideoMeta }
public protocol MediaFetching: Sendable { func fetch(streamURL: URL) async throws -> MediaBundle }
public protocol Transcribing: Sendable { func transcribe(audioFileURL: URL) async throws -> String }
public protocol Analyzing: Sendable {
    func analyze(meta: VideoMeta, transcript: String?, ocrText: String?) async throws -> Analysis
}
public protocol MusicLinkResolving: Sendable {
    func universalLink(title: String, artist: String) async throws -> URL?
}
```

```swift
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
    public init(videoID: String, url: URL, bookmarkedAt: Date)
}
```

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TikTokBrainKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "TikTokBrainKit", targets: ["TikTokBrainKit"])],
    targets: [
        .target(name: "TikTokBrainKit"),
        .testTarget(name: "TikTokBrainKitTests", dependencies: ["TikTokBrainKit"],
                    resources: [.copy("Fixtures")]),
    ]
)
```

- [ ] **Step 1:** Write the three source files exactly as above (add public inits with all-parameter defaults where shown).
- [ ] **Step 2:** Add `Tests/TikTokBrainKitTests/Fixtures/.gitkeep` and one placeholder test file asserting `true` so the test target builds.
- [ ] **Step 3:** Run `cd tiktok-brain/TikTokBrainKit && swift build && swift test`. Expected: builds, 1 test passes.

### Task 2: ExportParser

**Files:**
- Create: `tiktok-brain/TikTokBrainKit/Sources/TikTokBrainKit/ExportParser.swift`
- Create: `tiktok-brain/TikTokBrainKit/Tests/TikTokBrainKitTests/Fixtures/export-user_data.json`
- Test: `tiktok-brain/TikTokBrainKit/Tests/TikTokBrainKitTests/ExportParserTests.swift`

**Interfaces:**
- Consumes: `Bookmark` (Task 1)
- Produces: `public struct ExportParser { public init(); public func parse(jsonData: Data) throws -> [Bookmark]; public func parse(zipAt: URL) throws -> [Bookmark] }`

Parsing rules: walk the whole JSON tree; collect every array whose parent key matches regex `(?i)favou?rite.*video` where items are objects containing keys `Date` (or `date`) and `Link` (or `link`). Date format `yyyy-MM-dd HH:mm:ss` (UTC). Video id = last path component of the link that is all digits; if none, use `url.absoluteString`. De-duplicate by id, keep newest date. `parse(zipAt:)` for the prototype: if given a directory, scan for `*.json` and merge results (real zip handling arrives with real export testing; `Process`/`unzip` is unavailable on iOS — on iOS the app passes the already-extracted JSON. Implement directory + raw-JSON paths only; zip TBD is NOT allowed — implement by shelling out is forbidden; instead document in code that callers pass extracted JSON, and `parse(zipAt:)` throws `CocoaError(.fileReadUnknown)` for actual zip files).

Fixture `export-user_data.json` (this exact shape mirrors TikTok's real export):

```json
{
  "Activity": {
    "Favorite Videos": {
      "FavoriteVideoList": [
        {"Date": "2026-07-04 12:00:00", "Link": "https://www.tiktokv.com/share/video/7234567890123456789/"},
        {"Date": "2026-07-03 09:30:00", "Link": "https://www.tiktokv.com/share/video/7234567890123456789/"},
        {"Date": "2026-06-30 08:00:00", "Link": "https://www.tiktokv.com/share/video/7111111111111111111/"}
      ]
    },
    "Like List": {"ItemFavoriteList": [{"Date": "2026-06-01 00:00:00", "Link": "https://x/should-not-appear"}]}
  }
}
```

- [ ] **Step 1: Failing tests** — `testParsesFavoritesOnly` (2 bookmarks, likes excluded), `testDedupKeepsNewest` (id `7234567890123456789` has date 2026-07-04), `testVideoIDParsing`.

```swift
func testParsesFavoritesOnly() throws {
    let url = Bundle.module.url(forResource: "Fixtures/export-user_data", withExtension: "json")!
    let bookmarks = try ExportParser().parse(jsonData: Data(contentsOf: url))
    XCTAssertEqual(bookmarks.count, 2)
    XCTAssertFalse(bookmarks.contains { $0.url.absoluteString.contains("should-not-appear") })
}
```

- [ ] **Step 2:** `swift test --filter ExportParserTests` — expected FAIL (type missing).
- [ ] **Step 3:** Implement with `JSONSerialization` recursive walk.
- [ ] **Step 4:** `swift test --filter ExportParserTests` — expected PASS.

### Task 3: Enricher

**Files:**
- Create: `tiktok-brain/TikTokBrainKit/Sources/TikTokBrainKit/Enricher.swift`
- Create: `tiktok-brain/TikTokBrainKit/Tests/TikTokBrainKitTests/Fixtures/video-page.html`
- Test: `tiktok-brain/TikTokBrainKit/Tests/TikTokBrainKitTests/EnricherTests.swift`

**Interfaces:**
- Consumes: `VideoMeta`, `Enriching` (Task 1)
- Produces: `public struct Enricher: Enriching { public init(session: URLSession = .shared, minRequestInterval: TimeInterval = 1.0); public func enrich(_ url: URL) async throws -> VideoMeta; public func parse(html: String) throws -> VideoMeta }`

`parse(html:)` extracts the `<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">…</script>` JSON, then reads `__DEFAULT_SCOPE__ → webapp.video-detail → itemInfo → itemStruct`: `desc` → caption (+ hashtags = words starting `#`, lowercased, `#` stripped), `author.uniqueId` → author, `video.cover` → thumbnailURL, `music.title` → soundTitle, `music.authorName` → soundArtist, `video.playAddr` → streamURL. Missing keys → nil/empty, never throw for partial data; throw `BoxError.malformedPayload` only when the script tag itself is absent. `enrich(_:)` fetches with a desktop Safari User-Agent and enforces `minRequestInterval` between requests (actor-guarded last-request timestamp).

Fixture `video-page.html`: a minimal page embedding that script tag with `desc: "POV: 15-minute miso ramen #recipe #ramen"`, `author.uniqueId: "noodleworship"`, `music.title: "original sound"`, `music.authorName: "noodleworship"`, `video.playAddr: "https://v16.tiktokcdn.example/play/abc.mp4"`, `video.cover: "https://p16.example/cover.jpg"`.

- [ ] **Step 1: Failing tests** — `testParsesCaptionHashtagsAuthor`, `testParsesSoundAndStream`, `testMissingScriptTagThrows` (pass `"<html></html>"`).
- [ ] **Step 2:** `swift test --filter EnricherTests` — FAIL.
- [ ] **Step 3:** Implement (string-scan for the script tag, `JSONSerialization` for drill-down).
- [ ] **Step 4:** `swift test --filter EnricherTests` — PASS.

### Task 4: Box clients (Transcriber + Analyzer)

**Files:**
- Create: `tiktok-brain/TikTokBrainKit/Sources/TikTokBrainKit/BoxClients.swift`
- Test: `tiktok-brain/TikTokBrainKit/Tests/TikTokBrainKitTests/BoxClientsTests.swift`

**Interfaces:**
- Consumes: `BoxConfig`, `BoxError`, `Transcribing`, `Analyzing`, `Analysis` (Task 1)
- Produces:
  - `public struct TranscriberClient: Transcribing { public init(config: BoxConfig, session: URLSession = .shared) }` → POST `{base}/audio/transcriptions` multipart (`file`, `model`, `language=en`, `response_format=json`), returns decoded `text`.
  - `public struct AnalyzerClient: Analyzing { public init(config: BoxConfig, session: URLSession = .shared) }` → POST `{base}/chat/completions` with `response_format: {"type":"json_object"}`, system prompt instructing the exact `Analysis` JSON shape (category one of `recipe|music|coding|other`; include `recipe`/`track`/`code` object only for the matching category), decodes `choices[0].message.content` into `Analysis` via `JSONDecoder`. Strip Markdown code fences before decoding.
  - Both: `URLError` .cannotConnectToHost/.timedOut/.dnsLookupFailed → `BoxError.unreachable("(is Tailscale up and the box online?) …")`; non-2xx → `BoxError.badResponse(code)`; 30 s request timeout.

Tests use a `URLProtocol` stub (`StubURLProtocol` registered in an ephemeral `URLSessionConfiguration`) — no network. Cases: `testAnalyzerDecodesRecipe` (canned chat response with fenced JSON), `testAnalyzerUnreachableMapsToBoxError` (stub throws `URLError(.cannotConnectToHost)`), `testTranscriberParsesText`, `testTranscriberSendsMultipart` (assert body contains `filename=` and model field).

- [ ] **Step 1:** Failing tests as above. **Step 2:** `swift test --filter BoxClientsTests` — FAIL. **Step 3:** Implement. **Step 4:** PASS.

### Task 5: MusicLinkResolver

**Files:**
- Create: `tiktok-brain/TikTokBrainKit/Sources/TikTokBrainKit/MusicLinkResolver.swift`
- Create: `tiktok-brain/TikTokBrainKit/Tests/TikTokBrainKitTests/Fixtures/itunes-search.json`
- Test: `tiktok-brain/TikTokBrainKit/Tests/TikTokBrainKitTests/MusicLinkResolverTests.swift`

**Interfaces:**
- Consumes: `MusicLinkResolving` (Task 1)
- Produces: `public struct MusicLinkResolver: MusicLinkResolving { public init(session: URLSession = .shared) }` — GET `https://itunes.apple.com/search?term={title artist}&media=music&limit=1`; if a result has `trackViewUrl`, return `https://song.link/{percent-encoded trackViewUrl}`; no results → nil. Skip resolution (return nil) when title is empty or looks like an original sound (`(?i)original sound`).

Fixture: real-shaped iTunes response with one result, `trackViewUrl: "https://music.apple.com/us/album/example/123?i=456"`.

- [ ] **Step 1:** Failing tests: `testResolvesToSongLink` (URLProtocol stub returns fixture; expect `https://song.link/https%3A%2F%2Fmusic.apple.com%2F...`), `testOriginalSoundReturnsNil` (no request issued). **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS.

### Task 6: MediaFetcher

**Files:**
- Create: `tiktok-brain/TikTokBrainKit/Sources/TikTokBrainKit/MediaFetcher.swift`
- Test: `tiktok-brain/TikTokBrainKit/Tests/TikTokBrainKitTests/MediaFetcherTests.swift`

**Interfaces:**
- Consumes: `MediaFetching`, `MediaBundle` (Task 1)
- Produces: `public struct MediaFetcher: MediaFetching { public init(session: URLSession = .shared, keyframeCount: Int = 6) }` — downloads `streamURL` to a temp `.mp4`, exports mono 16 kHz `.m4a` audio via `AVAssetExportSession`, samples `keyframeCount` evenly-spaced frames via `AVAssetImageGenerator` to temp PNGs. Also produce `public struct FrameReader { public init(); public func recognizeText(in imageURLs: [URL]) async throws -> String }` using Vision `VNRecognizeTextRequest` (accurate, en-US), joining unique lines.
- Test strategy (no network, no real TikTok): generate a 2-second test video in-test with `AVAssetWriter` (solid color frames + silent audio), serve it via `URLProtocol` stub, assert bundle has audio + 6 keyframes. `FrameReader` test: render the word "PASTA" into a CGImage-backed PNG, expect OCR output to contain "PASTA".

- [ ] **Step 1:** Failing tests `testFetchProducesAudioAndKeyframes`, `testOCRReadsRenderedText`. **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. (If `AVAssetWriter` in tests proves flaky on macOS CI, mark the fetch test with a generated-file fallback: write the asset once into Fixtures and load it — but attempt in-test generation first.)

### Task 7: Pipeline

**Files:**
- Create: `tiktok-brain/TikTokBrainKit/Sources/TikTokBrainKit/Pipeline.swift`
- Test: `tiktok-brain/TikTokBrainKit/Tests/TikTokBrainKitTests/PipelineTests.swift`

**Interfaces:**
- Consumes: everything above (protocols only — concrete deps injected).
- Produces:

```swift
public struct PipelineDeps: Sendable {
    public var enricher: any Enriching
    public var media: any MediaFetching
    public var transcriber: any Transcribing
    public var analyzer: any Analyzing
    public var musicResolver: any MusicLinkResolving
    public var ocr: @Sendable ([URL]) async throws -> String
    public init(...)
}
public actor PipelineRunner {
    public init(deps: PipelineDeps, container: ModelContainer)
    public func ingest(bookmarks: [Bookmark]) async throws -> Int   // inserts new Videos (dedup by videoID), returns new count
    public func processNext() async throws -> Bool                  // one video through all stages; false when queue empty
    public func processAll(progress: @Sendable (Int, Int) -> Void) async
}
```

Stage semantics: per stage try/catch; on `BoxError.unreachable` set that stage `awaitingBox` and continue to next video (do NOT mark failed); other errors → `failed`. After analyze: set category/title/summary/topics; encode payloads to `recipeJSON`/`trackJSON`/`codeJSON`; for music, call `musicResolver` and store the link inside `TrackData.universalLink`. Video with all-empty meta (enrich failed) → `unavailable = true`.

Golden-path test with fakes (all in-memory, `ModelContainer(for:configurations:)` with `isStoredInMemoryOnly: true`): 3 bookmarks — one recipe (analyzer fake returns recipe payload), one music (fake resolver returns link), one where enricher throws (expect `unavailable`). Assert stage states, categories, payload round-trip decode. Second test: transcriber throws `BoxError.unreachable` → stage `awaitingBox`, analyze still ran with `transcript == nil`.

- [ ] **Step 1:** Failing tests. **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS — full suite: `swift test` all green.

### Task 8: SwiftUI app shell

**Files:**
- Create: `tiktok-brain/App/project.yml`, all files under `tiktok-brain/App/Sources/` (see File Structure)

**Interfaces:**
- Consumes: Kit public API (Tasks 1–7). No new Kit API may be invented here — if the UI needs something missing, add a computed helper in the App layer.

`project.yml`:

```yaml
name: TikTokBrain
options: { bundleIdPrefix: dev.dmitryschab }
packages: { TikTokBrainKit: { path: ../TikTokBrainKit } }
targets:
  TikTokBrain:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources: [Sources]
    dependencies: [{ package: TikTokBrainKit }]
    settings: { INFOPLIST_KEY_UILaunchScreen_Generation: YES, GENERATE_INFOPLIST_FILE: YES }
```

Screens per spec/mockups (approved 2026-07-10): TabView with Library (segmented Recipes/Music/Code/Other; recipe cards; music rows with song.link button via `Link`; "needs a look" section = `unavailable || categoryRaw.isEmpty`), Mind map (radial layout in `Canvas`: center → 4 category nodes → up to 8 topic nodes each → video dots; static layout is fine for prototype), Import (`fileImporter` for JSON, progress via `processAll` callback, box status row = result of a lightweight `analyzer` ping guarded by try?), Video detail (thumbnail `AsyncImage`, badge, payload sections, transcript DisclosureGroup, Open in TikTok `Link`, Re-run button). `Theme.swift`: `Color` extensions — coral `#D85A30`, pink `#D4537E`, teal `#1D9E75`, purple `#7F77DD`, keyed by `Category`. Settings for box config: a simple `@AppStorage`-backed sheet off Import (baseURL string, chat model, whisper model). `SampleData.swift` seeds 6 videos across categories when the store is empty AND `CommandLine.arguments.contains("-seedSample")` (used by the simulator smoke run).

- [ ] **Step 1:** Write all App sources compiling against the Kit.
- [ ] **Step 2:** `cd tiktok-brain/App && xcodegen generate` (install first if missing: `brew install xcodegen`).
- [ ] **Step 3:** `xcodebuild -project TikTokBrain.xcodeproj -scheme TikTokBrain -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` — expected: BUILD SUCCEEDED.

### Task 9: Simulator smoke test

- [ ] **Step 1:** `xcrun simctl boot "iPhone 17 Pro"` (ok if already booted), `xcrun simctl install booted <path to built .app>`, `xcrun simctl launch booted dev.dmitryschab.TikTokBrain -seedSample`.
- [ ] **Step 2:** `xcrun simctl io booted screenshot tiktok-brain/docs/smoke-library.png` — verify the Library renders seeded content (inspect the png).
- [ ] **Step 3:** Full verification: `cd tiktok-brain/TikTokBrainKit && swift test` (all green) + BUILD SUCCEEDED + screenshot showing seeded UI. Commit everything.

## Execution notes for the orchestrator

- Task 1 first (foundation). Tasks 2–6 are fully parallel (disjoint files, contract from Task 1). Task 7 needs 1 only (uses protocols + fakes) but run it after 2–6 land to compile against the real package state. Task 8 needs 1–7 built; Task 9 needs 8.
- Workers must not commit; orchestrator commits after each phase.
- Workers run `swift test --filter <TheirTests>` before reporting done, and report the test output.
