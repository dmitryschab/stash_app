# Search by What It's About — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Search matches each save against one "about" text (what is said, else what is shown, music by genre only), ranks by meaning with a word-hit boost, and shows no percentage.

**Architecture:** A new server route `POST /v1/about` writes the about-text with Gemma (text) or a vision model (cover image of a save with no speech). The app's existing embedding drain gains an about phase in front of it and embeds the about-text alone. The ranker moves out of the view into TikTokBrainKit, where it is unit-tested and measured by a scorecard over the owner's 855-save library.

**Tech Stack:** Python 3.11 / FastAPI (services/webhook), Swift 6 / SwiftData / SwiftUI (TikTokBrainKit, App), Bedrock Gemma + Titan v2, OpenRouter Gemini Flash.

**Spec:** `docs/superpowers/specs/2026-10-19-search-by-what-its-about-design.md`

## Global Constraints

- `/v1/about` charges **no monthly quota**; every item charges one daily deep-pass unit up front via `api_v1.charge_deep_pass(store)` (429 before any model call).
- Per-account compute stays near **~$0.20**. If the measured cost per silent save × 167 (a third of a 500-save account) exceeds $0.20, stop and ask the owner.
- `summary`, `title`, `topics` keep their current meaning everywhere else; `ANALYSIS_SYSTEM_PROMPT` is not changed.
- Title, topics, caption and hashtags never contribute to ranking.
- No number, percent or confidence is shown to the user.
- Search still answers offline, by whole words on the about-text.
- Music saves: lyrics are never sent or summarized; the about-text gives the genre and never names a song, artist or album.
- Stop-words and plurals are English-only (the analysis writes English).
- Tests: Python `cd services/webhook && uv run --with-requirements requirements.txt --with pytest --with cryptography python -m pytest -q`; Kit `cd TikTokBrainKit && swift test` — read BOTH summary lines ("Executed N tests" and "Test run with N tests"); App `cd App && xcodegen generate && xcodebuild -project Stash.xcodeproj -scheme Stash -destination 'generic/platform=iOS Simulator' build`.
- Commit messages carry no co-author or "Generated with" footer. Never commit `pipeline-lab/full/*` data (it is the owner's library).
- Server deploy is manual (`services/webhook/deploy.sh`, recipe in `services/webhook/README.md`). TestFlight upload needs the owner's confirmation and is not part of this plan.

## Decisions this plan adds to the spec

- **No photo-post flag exists on the client**, so photo posts are not special-cased: every save with no speech sends its cover *and* its existing `summary` (for a photo post that summary was written from all slides). The spec's photo-post line is updated to match.
- **Shazam genres are never stored**, so the music genre always comes from the model reading the identified tracks (`musicJSON`) and the caption.
- **Saves without an about-text are not embedded and not scored by meaning**: `embeddingText` becomes the about-text or `""`, and the ranker word-matches them on `summary + transcript` and lists them after every about-text save. Their old mixed vectors (title + hashtags) are ignored.
- **Offline order** is by number of query words hit, then newest — the spec's "newest first" with matched-word count ahead of it.

## Review Focus

1. **A query made only of stop-words** ("how to"): offline it finds nothing rather than the whole library; with an embedding it is meaning-only. → Task 3 test `testOnlyStopWordsOfflineFindsNothing`.
2. **Case, punctuation and accents in the query** ("Café!" vs "best cafe in riga") must still match. → Task 3 test `testPunctuationAndAccentsFold`.
3. **A save whose transcript can never be fetched** (Instagram reel: the transcript route 400s, the stage ends `.failed`, never "no speech") still gets a text-only about-text once and is searchable. → Task 2 test `testFailedTranscriptStillGetsATextOnlyItem`.
4. **A silent save whose cover is missing on disk** is written text-only and marked done, not retried forever. → Task 2 test `testSilentSaveWithoutCoverSendsNoImage` + Task 5 step.
5. **A five-minute transcript** is cut to its first 4000 characters before the model sees it. → Task 1 test `test_long_transcript_is_truncated`.

---

### Task 1: Server route `POST /v1/about`

**Files:**
- Create: `services/webhook/about_api.py`
- Modify: `services/webhook/app.py:56-58` (mount beside `embeddings_router`)
- Test: `services/webhook/test_about_api.py`

**Interfaces:**
- Consumes: `api_v1.charge_deep_pass(store)`, `api_v1._bedrock_token()`, `api_v1.BEDROCK_URL`, `api_v1.BEDROCK_MODEL`, `api_v1.OPENROUTER_URL`, `api_v1.OPENROUTER_VISION_MODEL`, `clef.openrouter_key()`, `stash_auth.entitled_store`.
- Produces:
  - `class AboutItem(BaseModel)`: `videoID: str`, `category: str = ""`, `transcript: str = ""`, `ocrText: str = ""`, `caption: str = ""`, `summary: str = ""`, `music: list[str] = []` (each `"Title by Artist"`), `image: str | None = None` (base64 JPEG).
  - `strip_hashtags(caption: str) -> str`
  - `build_about_prompt(item: AboutItem) -> str`
  - `_chat(url: str, model: str, token: str, system: str, content: str | list, max_tokens: int) -> str` (the one network call; tests patch it)
  - `write_about(item: AboutItem) -> str`
  - Route: `POST /v1/about` `{"items": [AboutItem]}` → `{"abouts": [str]}`, same order.
  - Constants: `MAX_ITEMS = 8`, `MAX_TEXT_BYTES = 16 * 1024` (all text fields of one item together), `MAX_IMAGE_BYTES = 400_000` (decoded), `TRANSCRIPT_CHARS = 4000`, `OCR_CHARS = 1000`, `ABOUT_MAX_TOKENS = 220`, `ABOUT_VISION_MODEL = OPENROUTER_VISION_MODEL` (Task 4 may switch it to `BEDROCK_MODEL`).

- [ ] **Step 1: Write the failing tests** in `test_about_api.py`, fixtures shaped like `test_embeddings_api.py` (`store` override of `entitled_store`, `_chat` monkeypatched to record calls and return `"About text."`):

```python
def test_one_about_per_item_in_order(store, chat):
    r = client.post("/v1/about", json={"items": [{"videoID": "a", "transcript": "we make carbonara"},
                                                   {"videoID": "b", "caption": "sunset #fyp"}]})
    assert r.status_code == 200 and r.json() == {"abouts": ["About text.", "About text."]}

def test_speech_prompt_uses_transcript_not_caption():
    p = build_about_prompt(AboutItem(videoID="a", transcript="we make carbonara", caption="#fyp so good"))
    assert "carbonara" in p and "#fyp" not in p and "so good" not in p

def test_long_transcript_is_truncated():
    p = build_about_prompt(AboutItem(videoID="a", transcript="x" * 4000 + "TAIL"))
    assert "TAIL" not in p

def test_music_never_sends_lyrics():
    p = build_about_prompt(AboutItem(videoID="a", category="music", transcript="la la love you",
                                     music=["Lovesong by The Cure"]))
    assert "la la love" not in p and "genre" in p.lower() and "Lovesong by The Cure" in p

def test_silent_prompt_strips_hashtags_and_keeps_summary():
    p = build_about_prompt(AboutItem(videoID="a", caption="Dinner tonight #pasta #fyp", summary="A plate of pasta."))
    assert "Dinner tonight" in p and "#pasta" not in p and "A plate of pasta." in p

def test_image_item_goes_to_vision_model_text_item_to_bedrock(store, chat): ...
    # chat records (url, model): the image item → (OPENROUTER_URL, ABOUT_VISION_MODEL) when that
    # constant is the OpenRouter model; the text item → (BEDROCK_URL, BEDROCK_MODEL); the image
    # item's content is a list containing an image_url part.

def test_refuses_zero_and_too_many_items(store, refuse_chat):        # 422 for [] and 9 items
def test_refuses_oversized_text_and_image(store, refuse_chat):        # 422; image of 400_001 decoded bytes
def test_each_item_charges_the_daily_cap(store, chat, monkeypatch):   # DEEP_PASS_DAILY_CAP=1, 2 items → 429, chat never called
def test_model_failure_is_a_502(store, monkeypatch):                  # _chat raises → 502
def test_charges_no_quota(store, chat):                               # store.get_quota() unchanged after a 200
```

- [ ] **Step 2: Run them, expect failures** — `cd services/webhook && uv run --with-requirements requirements.txt --with pytest --with cryptography python -m pytest -q test_about_api.py` → ImportError on `about_api`.

- [ ] **Step 3: Implement `about_api.py`.** Module docstring in the voice of `embeddings_api.py`. `ABOUT_SYSTEM_PROMPT` is exact copy:

```
You write the text a search engine matches a saved short video against. Answer with 2-4 plain
English sentences and nothing else: no lists, no Markdown, no preamble. Use concrete nouns a
person would search for: dishes, ingredients, places, products, brands, people, techniques,
activities. Never mention hashtags, the creator's handle, or the words "this video".
```

`build_about_prompt` branches, first match wins:
  1. `category == "music"` → `"This is a music post. Do not use any lyrics. In one sentence say the genre of the music; then describe what is shown if the material below says. Never write a song, artist or album name."` + `Identified tracks (for the genre only): …` + `Caption:` (stripped) + `On-screen text:` + the image if attached. Transcript never included.
  2. non-empty `transcript` → `"Summarize what is said."` + `Transcript:` first `TRANSCRIPT_CHARS` + `On-screen text:` first `OCR_CHARS` when present. Caption and summary never included.
  3. otherwise → `"Describe what the post shows, from the material below. The caption and the earlier summary may only name things that are visibly there."` + `On-screen text:`, `Caption:` (stripped), `Earlier summary:` — each only when non-empty — and the image if attached.
`strip_hashtags`: remove `#\w+`, collapse whitespace. `write_about`: image present → `ABOUT_VISION_MODEL` (OpenRouter URL + `openrouter_key()`, or Bedrock URL + token if the constant is `BEDROCK_MODEL`), content = `[{"type":"text",...}, {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,…"}}]`; else Bedrock Gemma. `temperature 0.2`, `max_tokens ABOUT_MAX_TOKENS`, answer `.strip()`. Route: validate shape (422), then `charge_deep_pass(store)` once per item, then write all items concurrently (`ThreadPoolExecutor(max_workers=MAX_ITEMS)`), any exception → log + 502 `"about unavailable"`.

- [ ] **Step 4: Mount it** in `app.py` beside the embeddings router, with the same one-line comment style.

- [ ] **Step 5: Run the whole Python suite** (command in Global Constraints) → all pass, count = previous + 11.

- [ ] **Step 6: Commit** — `git add services/webhook/about_api.py services/webhook/test_about_api.py services/webhook/app.py && git commit -m "feat(server): /v1/about writes the text search matches against"`

---

### Task 2: Kit — the about-text on `Video`, its client, and when it goes stale

**Files:**
- Modify: `TikTokBrainKit/Sources/TikTokBrainKit/Core/Entities.swift` (fields after `embeddingRevision` ~line 47; `hasNoSpeech` beside `needsTranscript` ~line 88; `embeddingText` ~line 118)
- Create: `TikTokBrainKit/Sources/TikTokBrainKit/BoxAboutClient.swift`
- Modify: `TikTokBrainKit/Sources/TikTokBrainKit/BoxEmbeddingClient.swift:29` (`revision = 2`)
- Modify: `TikTokBrainKit/Sources/TikTokBrainKit/Pipeline.swift:616` (`applyAnalysis`), `:374` (transcript backfill marks the stage done)
- Modify: `TikTokBrainKit/Sources/TikTokBrainKit/CloudImport.swift:577` (cloud result applied)
- Test: `TikTokBrainKit/Tests/TikTokBrainKitTests/AboutTests.swift`, additions to `PipelineTests.swift` and `CloudImportTests.swift`

**Interfaces:**
- Produces:
  - `Video.about: String? = nil`, `Video.aboutRevision: Int = 0` (lightweight migration, defaults like `embedding`).
  - `public extension Video { var hasNoSpeech: Bool }` — `!unavailable && (transcript ?? "").isEmpty && stage(.transcribe) == .done`.
  - `Video.embeddingText` → `about ?? ""` (the existing drain filter `!embeddingText.isEmpty` then skips saves without one).
  - `public struct AboutItem: Encodable, Sendable` with the server's field names (`videoID, category, transcript, ocrText, caption, summary, music: [String], image: String?`) and `public init(video: Video, cover: Data?)`: `image` = base64 of `cover` only when `video.hasNoSpeech`; `music` = `"\(title) by \(artist)"` from `musicJSON`.
  - `public enum AboutBackfill { static func pending(in videos: [Video]) -> [Video] }` — `aboutRevision < BoxAboutClient.revision && !unavailable && !categoryRaw.isEmpty && !isGuessed`, input order kept.
  - `public struct BoxAboutClient: Sendable { static let maxItemsPerRequest = 8; static let revision = 1; init(config: BoxConfig, session: URLSession = .shared); func write(_ items: [AboutItem]) async throws -> [String] }` — shaped exactly like `BoxEmbeddingClient`, POST `{base}/about`, throws `BoxError.malformedPayload` when the count differs.
  - Stale rule: `applyAnalysis`, the transcript backfill's "stage done" write, and the cloud apply each set `aboutRevision = 0`.

- [ ] **Step 1: Write the failing tests** in `AboutTests.swift`:

```swift
func testSpeechSaveSendsNoImage()                 // transcript "hi there friends", cover Data([1]) → item.image == nil
func testSilentSaveSendsItsCover()                 // transcribe stage .done, transcript nil, cover Data([1,2]) → image == "AQI="
func testSilentSaveWithoutCoverSendsNoImage()      // same save, cover nil → image == nil
func testFailedTranscriptStillGetsATextOnlyItem()  // transcribe .failed → hasNoSpeech false, image nil, and pending(in:) contains it
func testMusicPicksBecomeTitleByArtist()           // musicJSON [Lovesong/The Cure] → music == ["Lovesong by The Cure"]
func testPendingSkipsUnanalyzedUnavailableAndGuessed()
func testPendingDropsAWrittenSave()                // aboutRevision == BoxAboutClient.revision → not pending
func testEmbeddingTextIsTheAboutTextAlone()        // title "pasta night", about "a dog skates" → "a dog skates"; about nil → ""
func testClientRejectsAShortAnswer()               // URLProtocol stub returns 1 about for 2 items → BoxError.malformedPayload
```

  and in `PipelineTests.swift`: `testTranscriptBackfillMarksTheAboutStale` (no-speech fake transcriber, save starts at `aboutRevision 1` → ends at 0) and `testAnalysisMarksTheAboutStale`; in `CloudImportTests.swift`: `testAppliedCloudResultMarksTheAboutStale`.

- [ ] **Step 2: Run, expect compile failures** — `cd TikTokBrainKit && swift test 2>&1 | tail -5`.
- [ ] **Step 3: Implement** the fields, `hasNoSpeech`, `embeddingText`, `AboutItem`, `AboutBackfill.pending`, `BoxAboutClient`, the three `aboutRevision = 0` writes, and `BoxEmbeddingClient.revision = 2`. Update the `embeddingText` doc comment: it is the about-text now, nothing else.
- [ ] **Step 4: Run `swift test`** → both summary lines report 0 failures.
- [ ] **Step 5: Commit** — `feat(kit): the about-text a save is searched by, and when it goes stale`

---

### Task 3: Kit — the ranker

**Files:**
- Create: `TikTokBrainKit/Sources/TikTokBrainKit/SearchRanking.swift`
- Modify: `TikTokBrainKit/Sources/TikTokBrainKit/BoxEmbeddingClient.swift:120-136` (delete `SearchBlend`; update the header comment)
- Modify: `TikTokBrainKit/Tests/TikTokBrainKitTests/EmbeddingSearchTests.swift` (delete the `SearchBlend` tests only)
- Test: `TikTokBrainKit/Tests/TikTokBrainKitTests/SearchRankingTests.swift`

**Interfaces:**
- Consumes: `EmbeddingVector.cosine`, `Video.about`, `Video.summary`, `Video.transcript`, `Video.embedding`.
- Produces:
  - `public struct SearchEntry: Sendable { videoID: String; bookmarkedAt: Date; words: Set<String>; hasAbout: Bool; embedding: [Float]? }` with a public memberwise init.
  - `public struct SearchMatch: Sendable, Equatable { public let videoID: String }`
  - `public enum SearchIndex` with `static let meaningFloor = 0.35`, `static let wordBoost = 0.15`, `static let tieBand = 0.02` (Task 4 tunes all three), and:
    - `static func words(_ text: String) -> Set<String>` — lowercase + diacritic-fold (`folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)`), split on non-alphanumerics, drop stop-words, `stem` each.
    - `static func stem(_ word: String) -> String` — words longer than 3 characters lose a trailing `"es"` or `"s"` (applied to both sides, so "pastas"/"pasta" and "dishes"/"dish" meet).
    - `static func build(_ videos: [Video]) -> [SearchEntry]` — `about` when non-empty (`hasAbout = true`, embedding unpacked from `video.embedding` **only when `video.embeddingRevision == BoxEmbeddingClient.revision`**, so a pre-about vector built from title and hashtags is never used); else `summary + " " + transcript` with `hasAbout = false` and `embedding = nil`. Title, topics, caption, hashtags and OCR never enter `words`.
    - `static func rank(_ entries: [SearchEntry], query: String, embedding: [Float]?) -> [SearchMatch]`
- `rank` is pinned, because the tests alone do not fix the tie handling:

```
q = words(query) (deduped)
for each entry:
  hits = |q ∩ entry.words|
  if let embedding, entry.hasAbout, let stored = entry.embedding:
     c = cosine(embedding, stored)
     skip unless hits > 0 || c >= meaningFloor
     group 0, key = Int((c + (hits > 0 ? wordBoost : 0)) / tieBand)   // floor
  else:
     skip unless hits > 0
     group 1, key = hits, then hasAbout before !hasAbout
sort: group asc → key desc → (group 1: hasAbout first) → bookmarkedAt desc
```

- [ ] **Step 1: Write the failing tests** (2-D unit vectors give exact cosines: query `[1,0]`, stored `[c, sqrt(1-c*c)]`):

```swift
func testWholeWordsOnly()                 // about "a party at the start", query "art" → []
func testPluralsMatchBothWays()           // "two pastas tonight" ∋ "pasta"; "pasta bake" ∋ "pastas"
func testStopWordsAreIgnored()            // offline, "how to bake" over ["how to fix a bike", "bake bread"] → only "bake bread"
func testOnlyStopWordsOfflineFindsNothing() // "how to" , embedding nil → []
func testPunctuationAndAccentsFold()      // "Café!" matches "best cafe in riga"
func testMeaningOnlyMatchIsIncluded()     // no common word, c = 0.40 → in; c = 0.30 → out
func testSayingTheWordOutranksTheSameMeaning() // both c = 0.50, one says "pasta" → it is first even though older
func testCloseScoresGoNewestFirst()       // c 0.501 (old) and 0.509 (new), no word hits → new first
func testClearlyCloserWinsOverNewer()     // c 0.60 (old) vs 0.50 (new) → old first
func testSavesWithoutAboutComeLast()      // offline, same hit count: hasAbout entry before fallback entry even if older
func testBuildIgnoresTitleTopicsAndCaption() // Video title "pasta night", topics ["pasta"], caption "#pasta", about "a dog skates" → "pasta" finds nothing
func testBuildFallsBackToSummaryAndTranscript() // about nil, transcript "boil the pasta" → found, hasAbout false, embedding nil
func testBuildIgnoresAVectorFromBeforeTheAbout() // about set, embedding set, embeddingRevision 1 → entry.embedding == nil
```

- [ ] **Step 2: Run, expect failures** — `swift test --filter SearchRankingTests`.
- [ ] **Step 3: Implement `SearchRanking.swift`**; stop-words: an English list covering at least `a an and are as at be by for from how i in is it my of on or so the this to was what when where who why with you your`.
- [ ] **Step 4: Run `swift test`** → both summary lines, 0 failures.
- [ ] **Step 5: Commit** — `feat(kit): rank search by what a save is about`

---

### Task 4: Scorecard, vision model choice, and tuning

**Files:**
- Create: `scripts/search_scorecard/build_cache.py`, `scripts/search_scorecard/queries.json`
- Create: `TikTokBrainKit/Tests/TikTokBrainKitTests/SearchScorecardTests.swift`
- Modify (tuning only): `SearchRanking.swift` constants, `about_api.py` `ABOUT_VISION_MODEL`
- Output (never committed): `pipeline-lab/full/scorecard-cache.json`

**Interfaces:**
- Consumes: `about_api.build_about_prompt`, `about_api.write_about`, `about_api.AboutItem`, `embeddings_api._embed`, `SearchIndex.rank`, `SearchEntry`.
- Produces: cache JSON `{"saves": [{"videoID", "bookmarkedAt" (ISO 8601), "about", "aboutVector": [float], "legacy": {"title","topics","caption","summary","transcript"}, "legacyVector": [float]}], "queries": [{"query", "vector": [float], "mustAppear": [id], "top3": [id]}]}`.

- [ ] **Step 1: Draft `queries.json`** — 20 queries in the owner's casual phrasing over `pipeline-lab/full/seed.full.bak.json`, each with `mustAppear` (every save that is about it) and `top3` (1–2 ids). Mix: ≥5 targeting saves with no transcript, ≥3 sharing no word with the right save, ≥3 whose word appears only in an unrelated save's title or hashtags, 2 in Russian or Latvian, 2 music-genre queries.
- [ ] **Step 2: Owner checkpoint.** Show the owner each query with the titles of its `mustAppear` saves (titles only, in chat) and apply their edits. Do not continue until they reply.
- [ ] **Step 3: Write `build_cache.py`** — run from `services/webhook` so its modules import: `uv run --with-requirements requirements.txt python ../../scripts/search_scorecard/build_cache.py --seed ../../pipeline-lab/full/seed.full.bak.json --thumbs ../../pipeline-lab/full/thumbs --queries ../../scripts/search_scorecard/queries.json --out ../../pipeline-lab/full/scorecard-cache.json [--vision gemma|gemini] [--only-silent] [--limit N]`. A save with an empty transcript sends `thumbs/<videoID>.jpg` as its image. Legacy vector = embedding of `title, topics, summary, caption, transcript[:1000]` joined by newlines (today's `embeddingText` minus OCR, which the seed lacks). 8 saves at a time; resumable (skip ids already in `--out`). Uses the default AWS credentials (Bedrock) and `clef.openrouter_key()`; if that key is not available locally, say so and run `--vision gemma` only.
- [ ] **Step 4: Choose the vision model.** Run `--only-silent --limit 10` once with `--vision gemma` and once with `--vision gemini` into scratch files; read the 10 pairs against their thumbnails. Keep Gemma (`ABOUT_VISION_MODEL = BEDROCK_MODEL`) if its descriptions name what is visibly there as well as Gemini's; otherwise keep Gemini. Record the cost of one Gemini silent save from the OpenRouter response `usage`; apply the $0.20 rule from Global Constraints.
- [ ] **Step 5: Build the full cache** with the chosen model (~855 saves).
- [ ] **Step 6: Write `SearchScorecardTests.swift`** — `XCTSkip` unless env `STASH_SCORECARD` points at the cache. It holds `LegacyRanker`, a verbatim copy of today's `SearchIndex.score` + `SearchBlend` (`App/Sources/SearchView.swift:416-468`, weights 0.65/0.30/0.05, floor 0.35, field weights title 2, topics 1.5, others 1), fed from `legacy` + `legacyVector`. For both rankers it prints, per query, found/mustAppear and whether a `top3` id is in the top 3, then totals. Asserts: new recall ≥ legacy recall; new top-3 rate > legacy top-3 rate; every `mustAppear` id legacy found, new finds.
- [ ] **Step 7: Run and tune** — `cd TikTokBrainKit && STASH_SCORECARD=$PWD/../pipeline-lab/full/scorecard-cache.json swift test --filter SearchScorecardTests`. Adjust `meaningFloor`, `wordBoost`, `tieBand` until it passes; Task 3's tests must still pass. If no setting passes, stop and bring the per-query table to the owner.
- [ ] **Step 8: Commit** the scripts, `queries.json`, the test and the tuned constants (not the cache) — message body states the final constants, the vision model, and both scorecards' totals.

---

### Task 5: App — about phase in the drain

**Files:**
- Modify: `App/Sources/PipelineCenter.swift:1826-1858` (`EmbeddingBackfill.run`), and the doc comment at `:449-457`

**Interfaces:**
- Consumes: `AboutBackfill.pending(in:)`, `AboutItem(video:cover:)`, `BoxAboutClient`, `ThumbnailStore.cached(videoID:)`.
- Produces: nothing new; `backfillEmbeddings()` keeps its name and call sites.

- [ ] **Step 1: Add the about phase** at the top of `EmbeddingBackfill.run()`: `AboutBackfill.pending(in: all)` in batches of `BoxAboutClient.maxItemsPerRequest`; cover = `try? Data(contentsOf: ThumbnailStore.cached(videoID:))` when the file exists, else nil; on success set `about`, `aboutRevision = BoxAboutClient.revision`, `embeddingRevision = 0`, save per batch; the first failed batch ends the about phase (same rule as the embed phase) and the embed phase still runs for what is ready. `EmbeddingBackfill` gains a `BoxAboutClient` built from the same config in `backfillEmbeddings()`.
- [ ] **Step 2: Rewrite the ponytail note** at `:454-457` — a re-analysis now marks the about-text stale and the save re-embeds.
- [ ] **Step 3: Build the app** (command in Global Constraints) → `** BUILD SUCCEEDED **`.
- [ ] **Step 4: Commit** — `feat(app): write about-texts before embedding them`

---

### Task 6: App — results screen

**Files:**
- Modify: `App/Sources/SearchView.swift` (whole search part; `SearchGrip`, `SearchSuggestions`, `FlowChips`, `FlexibleWrap` unchanged)
- Modify: `App/Sources/TikTokBrainApp.swift:45` (drop the `SearchIndex.selfTest()` assert)

**Interfaces:**
- Consumes: `SearchIndex.build`, `SearchIndex.rank`, `SearchMatch`.

- [ ] **Step 1: Swap the scorer.** Delete the app's `SearchEntry`, `SearchMatch`, `SearchIndex` (lines 372-497); `rebuildIndex` calls the Kit's `SearchIndex.build`.
- [ ] **Step 2: Never reorder.** Replace `scored`/`scoredQuery` with `finalMatches: [SearchMatch]` and `finalQuery: String`. Ranking runs only once the query is settled (`embeddedQuery == trimmedQuery` and the index exists) and writes both together. In `embedQuery`, a vector arriving after the 6 s deadline already stamped `embeddedQuery` is dropped, so the word-only answer stays final. Rows render `finalMatches`; while `finalQuery != trimmedQuery` the previous list stays with one "Searching…" row above it (a first query shows only "Searching…"). "Also checking by meaning…" is gone. "No saves matched." only when settled and empty.
- [ ] **Step 3: Simplify the row.** Remove the percent capsule, `Hit.percent`, `Hit.score` and the "matched: …" line. Row = thumbnail + title + `video.about` on one line (`.lineLimit(1)`, same font/opacity as the old matched line); no second line when `about` is nil.
- [ ] **Step 4: Copy.** Header tagline `"Meaning, not just keywords"` → `"By what's said and shown"`; empty-library message → `"Import your favorites and Stash reads what each video says and shows."`; no-topics hint → `"Search what your saves say and show"`.
- [ ] **Step 5: Build** → `** BUILD SUCCEEDED **`; grep shows no `percent` or `matched:` left in `SearchView.swift`.
- [ ] **Step 6: See it.** On a booted simulator with the demo library (headless: `xcrun simctl`, the iOS Simulator tool for touches), open search by holding the tab pill 0.35 s and dragging right ≥ 70 pt, type `pasta`, take a screenshot: rows show title + about line, no percent. Type one more letter: the previous rows stay under "Searching…" and do not jump.
- [ ] **Step 7: Commit** — `feat(search): results by what a save is about, no score`

---

### Task 7: Ship to the box and check end to end

- [ ] **Step 1: Run all three test layers** (Global Constraints) → Python all pass, Kit both lines 0 failures, App builds.
- [ ] **Step 2: Deploy the server** per `services/webhook/README.md` (scp `*.py` incl. `about_api.py`, run `deploy.sh`), then on the box `curl -s http://127.0.0.1:8000/health` → ok, and `curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8000/v1/about -H 'Content-Type: application/json' -d '{"items":[]}'` → `401` (route mounted, auth in front).
- [ ] **Step 3: Push `main`.** Bump the build number the way the last `chore: build N` commit did, commit, push. Stop before any TestFlight upload and ask the owner.
