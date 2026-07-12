# Preserve and Rediscover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn every imported TikTok into a durable essence-first Stash Card, then make those cards semantically searchable, automatically connected, and calmly resurfaced on Today.

**Architecture:** Extend the existing SwiftData `Video` model with additive persisted card fields and introduce a `CardConnection` model. Keep binary assets in an app-owned filesystem store, keep ranking algorithms as pure Swift units in TikTokBrainKit, and let the SwiftUI app query those units without network dependencies. Integrate preservation into the existing best-effort pipeline through injected protocols so tests stay fixture-driven.

**Tech Stack:** Swift 6 package, SwiftData, SwiftUI, AVFoundation, Foundation, XCTest, XcodeGen, iOS 17+

## Global Constraints

- The preserved card must remain useful when the source TikTok is unavailable.
- Preserve two to four stills and a three-to-six-second muted loop only when motion is instructional.
- Asset paths stored in SwiftData are relative to Application Support.
- Model-derived values must be omitted when evidence is insufficient; never invent values.
- Today contains at most three stable items per calendar day and has no autoplay or endless feed.
- Full original-video archiving, cloud backup, notifications, chat Q&A, sharing, and task creation remain out of scope.

---

### Task 1: Persisted Stash Card model

**Files:**
- Modify: `TikTokBrainKit/Sources/TikTokBrainKit/Core/Types.swift`
- Modify: `TikTokBrainKit/Sources/TikTokBrainKit/Core/Entities.swift`
- Create: `TikTokBrainKit/Sources/TikTokBrainKit/Core/CardModels.swift`
- Create: `TikTokBrainKit/Tests/TikTokBrainKitTests/CardModelsTests.swift`

**Interfaces:**
- Produces: `PreservedAsset`, `AssetManifest`, `PreservationState`, `ExtractedEntity`, `CardRelation`, and additive `Video` card properties.
- Produces: `CardConnection(sourceVideoID:targetVideoID:relationRaw:explanation:confidence:)` with canonical pair ordering.

- [ ] **Step 1: Write failing round-trip and canonical-pair tests**

```swift
func testAssetManifestRoundTrips() throws {
    let value = AssetManifest(assets: [.init(relativePath: "cards/1/cover.jpg", kind: .cover, sourceTime: 4, byteSize: 12)])
    XCTAssertEqual(try JSONDecoder().decode(AssetManifest.self, from: JSONEncoder().encode(value)), value)
}

func testConnectionCanonicalizesPair() {
    let value = CardConnection(sourceVideoID: "z", targetVideoID: "a", relationRaw: CardRelation.sameGoal.rawValue, explanation: "Same goal", confidence: 0.9)
    XCTAssertEqual(value.sourceVideoID, "a")
    XCTAssertEqual(value.targetVideoID, "z")
}
```

- [ ] **Step 2: Run the focused tests and confirm the new types are missing**

Run: `cd TikTokBrainKit && swift test --filter CardModelsTests`

Expected: compilation fails because `AssetManifest` and `CardConnection` do not exist.

- [ ] **Step 3: Add Codable value types and additive SwiftData fields**

Implement `PreservedAsset.Kind` cases `cover`, `still`, `motion`, and `albumArtwork`; `AssetManifest.assets`; `PreservationState` cases `pending`, `partial`, `complete`, and `failed`; entity kinds `person`, `song`, `product`, `place`, `ingredient`, and `technology`; and relation cases `sameEntity`, `sameTechnique`, `sameGoal`, `complementary`, and `alternative`.

Add initialized `Video` fields `essence`, `assetManifestJSON`, `preservationStateRaw`, `embedding`, `embeddingModel`, `entitiesJSON`, `lastViewedAt`, `viewCount`, and `lastRediscoveredAt`. Seed pipeline stage keys `preserve`, `embed`, and `connect`. Add computed Codable accessors in `CardModels.swift` so UI code never decodes raw JSON.

- [ ] **Step 4: Run model and existing tests**

Run: `cd TikTokBrainKit && swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add TikTokBrainKit/Sources/TikTokBrainKit/Core TikTokBrainKit/Tests/TikTokBrainKitTests/CardModelsTests.swift
git commit -m "feat(stash): add persisted card model"
```

### Task 2: Durable asset storage

**Files:**
- Create: `TikTokBrainKit/Sources/TikTokBrainKit/AssetStore.swift`
- Create: `TikTokBrainKit/Sources/TikTokBrainKit/AssetPreserver.swift`
- Create: `TikTokBrainKit/Tests/TikTokBrainKitTests/AssetStoreTests.swift`
- Create: `TikTokBrainKit/Tests/TikTokBrainKitTests/AssetPreserverTests.swift`

**Interfaces:**
- Produces: `AssetStoring` with `save(videoID:assets:)`, `fileURL(for:)`, `delete(videoID:)`, and `removeOrphans(keeping:)`.
- Produces: `PendingAsset(sourceURL:kind:sourceTime:)`.
- Produces: `AssetPreserver.makePlan(category:keyframes:importantMoments:) -> PreservationPlan` and `exportMotion(from:range:destination:) async throws`.

- [ ] **Step 1: Write failing tests for stable relative paths and atomic replacement**

```swift
func testSaveCopiesAssetsAndReturnsRelativeManifest() throws {
    let root = temporaryDirectory()
    let source = root.appending(path: "frame.jpg")
    try Data("frame".utf8).write(to: source)
    let store = AssetStore(root: root.appending(path: "Application Support"))
    let manifest = try store.save(videoID: "123", assets: [.init(sourceURL: source, kind: .cover, sourceTime: 2)])
    XCTAssertEqual(manifest.assets.first?.relativePath, "cards/123/cover-0.jpg")
    XCTAssertTrue(FileManager.default.fileExists(atPath: try store.fileURL(for: manifest.assets[0]).path))
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd TikTokBrainKit && swift test --filter AssetStoreTests`

Expected: compilation fails because `AssetStore` does not exist.

- [ ] **Step 3: Implement filesystem storage**

Write assets into `cards/.staging-<UUID>` with deterministic names, create the manifest after every copy succeeds, then replace `cards/<videoID>` using `FileManager.replaceItemAt`. Reject path components containing `/`, `..`, or NUL. Resolve stored paths only after verifying the standardized URL remains under the configured root.

Implement `AssetPreserver` as a pure planner plus an AVFoundation exporter. The planner keeps at most four distinct stills nearest the analyzer's important timestamps, omits motion for music, and requests one motion asset only when an important moment has `requiresMotion == true`. Clamp motion to three through six seconds. Export muted H.264 MP4 with `AVAssetExportSession`, excluding audio tracks.

- [ ] **Step 4: Test replacement, deletion, traversal rejection, and orphan cleanup**

Run: `cd TikTokBrainKit && swift test --filter 'Asset(Store|Preserver)Tests'`

Expected: all asset storage and preservation tests pass.

- [ ] **Step 5: Commit**

```bash
git add TikTokBrainKit/Sources/TikTokBrainKit/AssetStore.swift TikTokBrainKit/Sources/TikTokBrainKit/AssetPreserver.swift TikTokBrainKit/Tests/TikTokBrainKitTests/AssetStoreTests.swift TikTokBrainKit/Tests/TikTokBrainKitTests/AssetPreserverTests.swift
git commit -m "feat(stash): preserve card assets offline"
```

### Task 3: Search index and embedding client

**Files:**
- Modify: `TikTokBrainKit/Sources/TikTokBrainKit/Core/Protocols.swift`
- Create: `TikTokBrainKit/Sources/TikTokBrainKit/SearchIndex.swift`
- Create: `TikTokBrainKit/Sources/TikTokBrainKit/BoxEmbeddingClient.swift`
- Create: `TikTokBrainKit/Tests/TikTokBrainKitTests/SearchIndexTests.swift`

**Interfaces:**
- Produces: `EmbeddingGenerating.embed(_:) async throws -> [Float]`.
- Produces: `SearchDocument(videoID:text:essence:structuredText:embedding:bookmarkedAt:)`.
- Produces: `SearchIndex.rank(query:queryEmbedding:documents:limit:) -> [SearchHit]`.

- [ ] **Step 1: Write ranking tests**

```swift
func testSemanticResultCanBeatRecencyWithoutExactWords() {
    let old = SearchDocument(videoID: "old", text: "meal prep", essence: "Keep lunch crisp", structuredText: "chicken rice", embedding: [1, 0], bookmarkedAt: .distantPast)
    let recent = SearchDocument(videoID: "new", text: "crispy ringtone", essence: "Music", structuredText: "", embedding: [0, 1], bookmarkedAt: .now)
    XCTAssertEqual(SearchIndex().rank(query: "lunch stays crunchy", queryEmbedding: [1, 0], documents: [recent, old], limit: 10).first?.videoID, "old")
}

func testTextFallbackWorksWithoutQueryEmbedding() {
    let document = SearchDocument(videoID: "1", text: "@chef", essence: "", structuredText: "yogurt sauce", embedding: nil, bookmarkedAt: .now)
    XCTAssertEqual(SearchIndex().rank(query: "yogurt", queryEmbedding: nil, documents: [document], limit: 10).first?.videoID, "1")
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd TikTokBrainKit && swift test --filter SearchIndexTests`

Expected: compilation fails because `SearchIndex` does not exist.

- [ ] **Step 3: Implement deterministic blended ranking**

Normalize tokens using lowercase folding, compute exact token overlap, cosine similarity for equal-length vectors, and weighted score `0.65 * semantic + 0.30 * lexical + 0.05 * recency`. Drop zero-score results. Return `SearchHit` with `videoID`, `score`, and `reason` equal to `Meaning match`, `Matched <token>`, or `Meaning and text match`.

Implement `BoxEmbeddingClient` against `POST /embeddings` with body `{"model": model, "input": text}` and decode `data[0].embedding`. Map connection errors to `BoxError.unreachable`.

- [ ] **Step 4: Run search and full tests**

Run: `cd TikTokBrainKit && swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add TikTokBrainKit/Sources/TikTokBrainKit TikTokBrainKit/Tests/TikTokBrainKitTests/SearchIndexTests.swift
git commit -m "feat(stash): add semantic search index"
```

### Task 4: Explainable connections

**Files:**
- Create: `TikTokBrainKit/Sources/TikTokBrainKit/ConnectionBuilder.swift`
- Create: `TikTokBrainKit/Tests/TikTokBrainKitTests/ConnectionBuilderTests.swift`

**Interfaces:**
- Consumes: `SearchDocument` and `CardRelation`.
- Produces: `ConnectionBuilder.build(for:candidates:) -> [ConnectionSuggestion]`.

- [ ] **Step 1: Write relation and threshold tests**

```swift
func testSharedEntityCreatesExplainableConnection() {
    let source = ConnectionDocument(videoID: "a", topics: ["meal prep"], entities: [.init(kind: .ingredient, value: "chicken")], embedding: [1, 0])
    let target = ConnectionDocument(videoID: "b", topics: ["protein"], entities: [.init(kind: .ingredient, value: "chicken")], embedding: [0.9, 0.1])
    let result = ConnectionBuilder(minimumConfidence: 0.72).build(for: source, candidates: [target])
    XCTAssertEqual(result.first?.relation, .sameEntity)
    XCTAssertEqual(result.first?.explanation, "Both mention chicken")
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd TikTokBrainKit && swift test --filter ConnectionBuilderTests`

Expected: compilation fails because `ConnectionBuilder` does not exist.

- [ ] **Step 3: Implement conservative local connection rules**

Prefer normalized shared entities, then shared topics, then semantic similarity above `0.82`. Emit `sameEntity` for entities, `sameGoal` for topics, and `complementary` for high semantic similarity. Cap output at five and exclude dismissed canonical pairs passed to the builder.

- [ ] **Step 4: Run tests**

Run: `cd TikTokBrainKit && swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add TikTokBrainKit/Sources/TikTokBrainKit/ConnectionBuilder.swift TikTokBrainKit/Tests/TikTokBrainKitTests/ConnectionBuilderTests.swift
git commit -m "feat(stash): connect related saved ideas"
```

### Task 5: Stable rediscovery selection

**Files:**
- Create: `TikTokBrainKit/Sources/TikTokBrainKit/RediscoverySelector.swift`
- Create: `TikTokBrainKit/Tests/TikTokBrainKitTests/RediscoverySelectorTests.swift`

**Interfaces:**
- Produces: `RediscoveryCandidate` and `RediscoverySelection`.
- Produces: `RediscoverySelector.select(from:on:calendar:limit:)`.

- [ ] **Step 1: Write stable, finite, diverse selection tests**

```swift
func testSelectionIsStableAndLimitedToThree() {
    let candidates = (0..<8).map { RediscoveryCandidate(videoID: "\($0)", category: $0.isMultiple(of: 2) ? "recipe" : "music", bookmarkedAt: Date(timeIntervalSince1970: Double($0)), lastViewedAt: nil, lastRediscoveredAt: nil, preservationQuality: 1) }
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let first = RediscoverySelector().select(from: candidates, on: date, calendar: .init(identifier: .gregorian), limit: 3)
    let second = RediscoverySelector().select(from: candidates, on: date, calendar: .init(identifier: .gregorian), limit: 3)
    XCTAssertEqual(first.map(\.videoID), second.map(\.videoID))
    XCTAssertEqual(first.count, 3)
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd TikTokBrainKit && swift test --filter RediscoverySelectorTests`

Expected: compilation fails because `RediscoverySelector` does not exist.

- [ ] **Step 3: Implement scoring and deterministic daily tie-breaking**

Score age, time since last view, preservation quality, and rediscovery cooldown. Greedily choose the highest score while applying a category-diversity bonus. Use `calendar.startOfDay(for:)` plus video ID through a stable FNV-1a hash for daily tie-breaking; never use Swift `Hasher`, whose seed changes between launches. Return explanations `Saved <N> days ago`, `You have not opened this yet`, or `Related to recent saves`.

- [ ] **Step 4: Run tests**

Run: `cd TikTokBrainKit && swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add TikTokBrainKit/Sources/TikTokBrainKit/RediscoverySelector.swift TikTokBrainKit/Tests/TikTokBrainKitTests/RediscoverySelectorTests.swift
git commit -m "feat(stash): select daily rediscovery cards"
```

### Task 6: Pipeline preservation integration

**Files:**
- Modify: `TikTokBrainKit/Sources/TikTokBrainKit/Core/Types.swift`
- Modify: `TikTokBrainKit/Sources/TikTokBrainKit/Core/Protocols.swift`
- Modify: `TikTokBrainKit/Sources/TikTokBrainKit/Pipeline.swift`
- Modify: `TikTokBrainKit/Tests/TikTokBrainKitTests/PipelineTests.swift`

**Interfaces:**
- Consumes: `AssetStoring`, `EmbeddingGenerating`, `Analysis`, and `MediaBundle`.
- Produces: populated `Video.essence`, asset manifest, embedding, entities, and stage states.

- [ ] **Step 1: Extend the golden pipeline test**

Assert that an analyzed recipe stores its summary as `essence`, copies its available keyframes into a manifest, stores a stub embedding, and marks `preserve`, `embed`, and `connect` done. Add a failure case proving an unavailable embedder leaves a usable preserved card and marks only `embed` as `awaitingBox`.

- [ ] **Step 2: Run and confirm failure**

Run: `cd TikTokBrainKit && swift test --filter PipelineTests`

Expected: assertions fail because the new stages are never executed.

- [ ] **Step 3: Extend injected dependencies and pipeline stages**

Add optional protocol-typed `assetStore` and `embedder` dependencies with no-op defaults to preserve source compatibility. After analysis, save up to four keyframes for non-music cards, store album artwork as remote metadata for music, embed the concatenated essence/title/summary/topics text, and store exact normalized entities returned by `Analysis`. Mark each new stage independently and delete only temporary media after preservation succeeds.

- [ ] **Step 4: Run full tests**

Run: `cd TikTokBrainKit && swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add TikTokBrainKit/Sources/TikTokBrainKit TikTokBrainKit/Tests/TikTokBrainKitTests/PipelineTests.swift
git commit -m "feat(stash): integrate card preservation pipeline"
```

### Task 7: Essence-first card and Today UI

**Files:**
- Create: `App/Sources/StashCardView.swift`
- Create: `App/Sources/TodayView.swift`
- Create: `App/Sources/SearchView.swift`
- Modify: `App/Sources/TikTokBrainApp.swift`
- Modify: `App/Sources/LibraryView.swift`
- Modify: `App/Sources/VideoDetailView.swift`
- Modify: `App/Sources/ImportView.swift`
- Modify: `App/Sources/SampleData.swift`

**Interfaces:**
- Consumes: `Video.cardManifest`, `SearchIndex`, `RediscoverySelector`, and `CardConnection`.
- Produces: four-tab shell `Today`, `Library`, `Search`, `Mind Map`; Library toolbar import sheet; essence-first card detail.

- [ ] **Step 1: Add preview data that represents preserved recipe, music, and tutorial cards**

Populate essence, preservation state, local/remote covers, embeddings, view history, and two explainable connections. Keep existing preview seeding behavior intact.

- [ ] **Step 2: Build the reusable essence-first card**

Render cover with a local-file-first loader, preservation badge, category, title, essence, category facts, and optional motion indicator. Use a neutral background and existing category colors. Never autoplay motion.

- [ ] **Step 3: Build Today**

Query preserved videos, create candidates, call `RediscoverySelector` for the current day, show up to three cards, and display the selector explanation. Show `ContentUnavailableView` with an Import action when no eligible cards exist.

- [ ] **Step 4: Build Search**

Use `.searchable`, debounce for 250 ms, build local `SearchDocument` values, request a query embedding when the box is reachable, and immediately show lexical fallback results otherwise. Render the hit reason under each card.

- [ ] **Step 5: Update navigation and detail**

Replace the three-tab root with Today, Library, Search, and Mind Map. Present `ImportView` from a Library toolbar sheet and show import progress in Library. Update detail to put preserved essence/media first, add Related saves, record view history on appearance, and disable the original link when unavailable.

- [ ] **Step 6: Generate the Xcode project and compile**

Run: `cd App && xcodegen generate && xcodebuild -project Stash.xcodeproj -scheme Stash -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO build`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add App/Sources App/Stash.xcodeproj
git commit -m "feat(stash): add essence cards and rediscovery home"
```

### Task 8: End-to-end verification

**Files:**
- Modify only files required by failures found during verification.

**Interfaces:**
- Consumes: all prior task outputs.
- Produces: verified release candidate.

- [ ] **Step 1: Run package tests**

Run: `cd TikTokBrainKit && swift test`

Expected: all tests pass with zero failures.

- [ ] **Step 2: Run the simulator build**

Run: `cd App && xcodegen generate && xcodebuild -project Stash.xcodeproj -scheme Stash -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO build`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Smoke the seeded UI**

Launch with `-STASH_SEED_SAMPLE`, verify Today is finite, open the recipe card with the original disabled, search for `lunch stays crunchy`, open a related save, and confirm Library can present Import.

- [ ] **Step 4: Confirm offline preservation manually**

Disable networking in the simulator after a fixture card is preserved. Confirm its essence, still images, structured recipe, and related saves remain visible. Confirm search falls back to lexical mode without an error screen.

- [ ] **Step 5: Commit verification fixes if any**

```bash
git add TikTokBrainKit App
git commit -m "fix(stash): close preservation verification gaps"
```
