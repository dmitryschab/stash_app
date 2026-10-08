# Clef onboarding — an instant library map at first import

**Date:** 2026-10-07 · **Status:** approved in chat, sections 1–2 reviewed, 3–5 approved on trust ·
**Brief:** `docs/superpowers/briefs/2026-10-07-clef-onboarding-classification.md` ·
**Branch:** `feat/clef-onboarding` off `feat/tiktok-portability-p2` (which already contains
`feat/ux-laws-rework` and `feat/tiktok-oauth-p1`)

## Why

Today a fresh library is a "Needs a look" pile for as long as the fast pass takes: Gemma reads
each video in turn, about 8 s per video four at a time, so a 1,000-video import shows nothing
sorted for the first minutes and its shape only at the end. The owner wants the library to have
its shape within seconds of the bookmarks being known — a distribution, skeleton tiles in every
category, a "what do you want to find fast?" picker — and the full analysis to fill that shape
in rather than reveal it.

## Evidence

Two spikes on the owner's own library, both in the previous session's scratchpad
(`clef-spike/eval_report.txt`) and this session's (`clef-cat/cat_eval.py`), 99–100 videos each,
Cloudflare's `clef-flash` on OpenRouter's `POST /api/v1/systemone`:

| Question | Input | Result |
|---|---|---|
| Category (13-way `choice`), scored against Gemma's label | caption + hashtags + sound + cover | top-1 86 %, top-2 95 %, 590 ms median, $0.00009 per call |
| Same | text only, no cover | top-1 84 %, top-2 93 %, 350 ms median, $0.00005 per call |
| Same, confidence ≥ 0.6 | text only | 95 % on 83 % of videos |
| Speech yes/no (deep-pass gate) | cover + text / text only | AUC 0.80 / 0.72 |
| On-screen text yes/no | any | AUC 0.53 — a cover cannot tell |

Coding 24/26, recipe 25/25, music 15/15, film 8/8 agreed; the misses were home, style and
`other`. "Truth" is Gemma's own label from transcript + OCR, so these are agreement rates, not
ground truth. The reading: Clef can label a tile the moment metadata exists, and the four
categories with their own screens are near-certain. The cover buys two points for double the
latency and a CDN fetch per video, so v1 sends text only.

## Decisions

1. **Clef is the first guess; Gemma's analysis overrides it.** Gemma also writes title, summary,
   recipe, music, films and buys, so it still runs for every video. On the ~1-in-7 disagreement
   the row moves when the full result lands. Nothing on screen says "guessed" in words; a guessed
   row is drawn as a skeleton in its category's tint, not as a finished save.
2. **Sample first.** Every input needs one TikTok fetch per video, so a whole-library map is
   minutes however it is done. The server classifies `MAP_SAMPLE = 60` videos evenly spaced
   through the import right after it is accepted (~10 s at 8-wide) and reports counts; the phone
   scales the sample's shares to the import's total for skeleton counts. Real rows replace
   estimates as the fast pass lands.
3. **Server-side, inside the import.** The OpenRouter key and yt-dlp already live on the box.
   No new endpoint: the map rides on the status poll the app already makes.
4. **Not charged.** No quota units, no daily cap: the map makes at most 60 Clef calls per
   import, about $0.003, and the import itself is already quota-metered.
5. **Any category can be a tab.** `StashTab` grows one case per category without a rich screen,
   shown by one generic `CategoryView`. The picker offers whatever the map found, ranked.
6. **The picker keeps every slot labelled.** At most 3 picks, so Lately + picks + Library never
   exceeds five labelled slots. Settings still allows up to seven.
7. **One skeleton for all categories.** A tinted shimmer row with the category's SF symbol; no
   bespoke animations.

## Components

### C1 — server (`services/webhook/`)

**`clef.py` (new).** One function:

```python
def classify(state: dict) -> tuple[str, float] | None:
    """Clef-flash's category for one video, with its probability, or None on any failure."""
```

- `POST https://openrouter.ai/api/v1/systemone`, `Authorization: Bearer` from the existing
  `_openrouter_key()` (move that helper here; `api_v1.py` imports it back). `requests`, 10 s timeout.
- Body: `{"model": "cloudflare/clef-flash", "state": {...}, "questions": {"category": {"type":
  "choice", "instructions": "Which single category best describes what this short video is
  about?", "criteria": CATEGORIES}}}`. `CATEGORIES` is a dict of the 13 category ids to one-line
  descriptions, the same wording the spike used, lifted from the canonical prompt's definitions.
- State: `caption`, `hashtags`, `author`, `sound_title`, `sound_artist`, `is_original_sound`,
  `duration_s` — the fields `FastPassPipeline.process` already derives from yt-dlp metadata.
  No images in v1.
- Reads `answers.category.choice` and `answers.category.probabilities[choice]`. A choice not in
  `Category` (the Kit's enum) is treated as a failure. Any exception, non-200, or malformed
  body → `None`, logged at warning with the status and the first 200 bytes.

**Map pass (`cloud_import_api.py`).** After `create_import` has staged the rows and enqueued the
fast pass, and only for a newly created import (`CreateImportResult.created`):

```python
_MAP_POOL = ThreadPoolExecutor(max_workers=8)   # module-level, one per process
_MAP_POOL.submit(map_pass, store, result.import_id, request.videos)
```

`map_pass`:
1. `sample = videos[::max(1, len(videos) // MAP_SAMPLE)][:MAP_SAMPLE]`. The phone submits
   newest-first, so the stride walks the whole date range rather than the newest week.
2. `store.start_map(import_id, sampled=len(sample))` → META `mapSampled`, `mapDone = 0`,
   `mapCounts = {}`, `mapGuesses = {}`.
3. Submit one task per sampled video to the same `_MAP_POOL` (no nested pool: eight threads
   per process is the whole budget, however many imports arrive at once). Each task: metadata
   via `FastPassPipeline._metadata(url)` (make it a module function `fetch_metadata`), the same
   state dict `process` builds, `clef.classify(state)`, then
   `store.guess_video(import_id, video_id, category, confidence)`. Metadata missing or Clef
   `None` → `store.skip_map_video(import_id)`.
4. Nothing is written to the VIDEO rows: the guess is small and short-lived, and the status
   poll must not scan 1,200 rows every eight seconds.

**Store (`cloud_import_store.py`).** Three methods, all on META:
- `start_map(import_id, sampled)` — `SET mapSampled = :n, mapDone = :zero, mapCounts = :empty, mapGuesses = :empty`.
- `guess_video(import_id, video_id, category, confidence)` — one `UpdateItem`:
  `SET mapDone = mapDone + :one, mapCounts.#c = if_not_exists(mapCounts.#c, :zero) + :one,
  mapGuesses.#v = :c`. Confidence is logged, not stored: v1 uses no threshold, because 86 % at
  full coverage draws a better map than 95 % with holes.
- `skip_map_video(import_id)` — `SET mapDone = mapDone + :one`.
- `get_status` reads them into `ImportStatus.map`.

**Wire (`cloud_import_models.py`).**

```python
class ImportMap(ContractModel):
    sampled: int
    done: int
    counts: dict[str, int] = Field(default_factory=dict)       # category -> n
    guesses: dict[str, str] = Field(default_factory=dict)      # videoID -> category

class ImportStatus(ContractModel):
    ...
    map: ImportMap | None = None
```

`map` is `None` until `start_map` has run, which the phone reads as "no map, behave as today".
`ANALYSIS_REVISION` is unchanged: no stored result changes meaning.

### C2 — Kit (`TikTokBrainKit/Sources/TikTokBrainKit/CloudImport.swift`)

- `CloudImportMap: Codable, Equatable, Sendable` with `sampled`, `done`, `counts: [Category: Int]`,
  `guesses: [String: Category]`. Decoding drops any key that is not a `Category` instead of
  failing the status decode (same tolerance `Category.init(from:)` applies).
- `CloudImportStatus.map: CloudImportMap?`, decoded with `decodeIfPresent`, so a status from a
  box that predates this field still decodes.
- `CloudImportSyncState.apply(status:)` keeps the incoming map when its `done` is ≥ the current
  one's, otherwise keeps the current.
- `CloudImport.apply(_:to:)`: an `unavailable` result over a row that still holds a guess
  (`isGuessed`) clears `categoryRaw`, so a dead video
  does not keep a category it was only guessed into.
- `public static func applyGuesses(_ guesses: [String: Category], to context: ModelContext) throws -> Int`:
  fetch the named rows; where `cloudAnalysisRevision == 0 && categoryRaw.isEmpty`, set
  `categoryRaw`. Returns how many changed. "Guessed" is derived everywhere as `Video.isGuessed`
  = `!categoryRaw.isEmpty && title.isEmpty && summary.isEmpty` — no new field, no migration.
  Not the revision: rows the old on-device pipeline analysed, and the demo seed, sit at
  revision 0 with titles, and must keep rendering as saves.

### C3 — app (`App/Sources/`)

**`PipelineCenter.swift`**
- In the status poll (`syncCloudImport`), after `cloudState.apply(status:)`: if the map carries
  guesses, `CloudImport.applyGuesses` on the pipeline's context. Idempotent per poll.
- `func expected(_ category: Category) -> Int`: `0` unless an import is active with a map whose
  `done > 0`; else `max(0, Int((Double(counts[c] ?? 0) / Double(done) * Double(total)).rounded()) − landed(c))`,
  where `total = fastPass.total` and `landed(c)` is the count of library rows with
  `categoryRaw == c` (guessed or analysed). Computed from a cached per-category count the
  poll refreshes, not a fetch per view body.
- `func expected(_ intent: SaveIntent, includeBuy: Bool) -> Int`: the sum of `expected(c)` over
  categories where `SaveIntent.classify(category: c, topics: [], hasBuys: false, includeBuy: includeBuy) == intent`.
- `var mapShares: [(Category, Int)]`: the map's counts scaled to `total`, descending — what the
  picker and the hero bar show.

**`TikTokBrainApp.swift` — `StashTab`**
- New cases, in catalogue order after `haul` and before `library`: `fitness, style, travel, home,
  learning, comedy, dining, wellness`. No `other` tab.
- `label`: one word each — "Fitness", "Style", "Travel", "Home", "Learning", "Comedy",
  "Dining", "Wellness". `symbol`: the matching `Category.symbol`. `blurb`: one line each in the
  existing voice ("Workouts and training saves.", "Outfits, beauty and hair.", …).
  `ownedCategory`: the matching category.
- `static func tab(owning category: Category) -> StashTab?`: recipe → cook, music → music,
  coding → code, film → films, other → nil, else the new case. The picker uses it.
- `TabSlots.maximum` stays 7; `decode`/`encode` are unchanged and keep working because they
  filter through `allCases`. `TabSlots.selfTest` gains: every category except `other` has a tab,
  the picker's slot arithmetic below, and a stored string naming only new tabs still pins Library.
- `RootView.tabShell`: the new cases render `CategoryView(category: tab.ownedCategory!)`.
  `libraryShelves(visible:)` needs no change — it already removes every owned category.

**`CategoryView.swift` (new).** The generic section:
- Header like `CookView`'s: the category's `displayName` in its tint, "N saves" trailing where
  N counts analysed rows only.
- Body: month runs of analysed rows (`category == c && !isGuessed && !needsLook`),
  the same row cell `IntentListView` draws — lift that cell out of `LibraryView.swift` as an
  internal `SaveRow` both use. Rows open `VideoDetailView`.
- Under the real rows: `sorting = guessed(c) + center.expected(c)` skeleton rows, where
  `guessed(c)` counts rows with `categoryRaw == c && isGuessed`. Since
  `expected` already subtracts guessed rows as landed, this equals the scaled estimate minus
  the analysed rows. Capped at 5 on screen with a `Micro` line "+N more sorting" beyond that.
  Zero skeletons once the import completes.
- Honours `tabReselect` by scrolling to the top, like the other sections.

**`LibraryView.swift`.** Guessed rows already land on the right desk, because `desked`
classifies on category alone when `topics` is empty. Each desk shelf splits its videos into
analysed (drawn as today) and guessed (`isGuessed`, drawn as `SkeletonRow`),
then appends `center.expected(intent, includeBuy:)` more skeletons — same cap of 5 and the same
"+N more sorting" line. A guessed row is never drawn as a real row with an empty title.

**`Theme.swift` — `SkeletonRow(tint:symbol:)`.** One view: a 44 pt rounded square and two text
bars in `tint.opacity(0.12)`, a lighter gradient sweeping across every 1.4 s, the SF symbol in
the square pulsing between 0.35 and 0.7 opacity. Under Reduce Motion both animations stop and
the row is a static tinted placeholder. Also `MapBar(shares:)`: one horizontal bar split into
tinted segments proportional to the shares, 6 pt tall, with a legend line of the top four
("Tech ~230 · Recipes ~180 · …").

**`FocusPickerView.swift` (new).** A sheet from `RootView`:
- Shown when all hold: the account's `focusPicked-<userID>` default is unset, the user is not
  the demo account, an import is active, and its map has `done >= min(20, sampled)` with at
  least one count. Skipping, or swiping the sheet away, sets the key too: it is seen once.
- Content: `MapBar`, the title "What do you want to find fast?", one chip per category in
  `mapShares` order (top 6, `other` excluded) reading "Tech · ~230" in the category's tint,
  multi-select up to 3 — the fourth tap is refused with the chip row's caption changing to
  "Three keeps every tab labelled; add more in Settings". Buttons: "Set up my bar" (disabled
  with no picks) and "Skip".
- On confirm: `tabSlots = TabSlots.encode([.today] + picks.compactMap(StashTab.tab(owning:)) + [.library])`.
  Replaces the defaults — the user chose. `static func slots(for picks: [Category]) -> [StashTab]`
  is the testable core.
- The sheet never covers Import or Settings: if `importRouteRequested` is up or a sheet is
  already presented, it waits for the next poll.

**`ImportView.swift`.**
- Hero card, `syncing` state: `MapBar` under the progress bar once `map.done > 0`, subtitle
  "Sorting 60 of 941 to shape your library…" until the map is done, then the existing
  "N of M processed".
- Providers card and the Settings legal line gain Cloudflare via OpenRouter: "captions and
  hashtags go to Cloudflare's Clef model through OpenRouter for a first sort".

### C4 — site (`services/webhook/site/privacy.html`)

One `<dt>/<dd>` pair in the providers list, in the page's voice: OpenRouter, Inc. (United
States) routes the caption and hashtags of each imported video to Cloudflare's Clef model for a
first category guess; no cover images, transcripts or account data; see international transfers.
The "How Stash processes your library" paragraph gets one sentence saying the first sort happens
there before the analysis on Bedrock.

## Error handling

- Clef unreachable, 4xx/5xx, or a malformed answer: the video is skipped, `mapDone` still
  advances, and the map completes with fewer counts. The fast pass never waits on the map.
- yt-dlp fails for a sampled video: same as above. The fast pass fetches again later and
  records its own failure.
- The API process restarts mid-map: the map stays partial (`done < sampled`); the phone scales
  whatever `done` it has. No retry — the fast pass makes the estimate moot within minutes.
- Status from an older box (no `map`): `nil`, no picker, no skeletons, no change from today.
- A guessed row the fast pass later marks unavailable loses its guess (C2).
- A map with every guess in `other`: the picker has nothing to offer and is not shown; the key
  is not set, so a later import can still show it.

## Testing

Server, `services/webhook/test_clef.py` and additions to `test_cloud_import_api.py` /
`test_cloud_import_store.py` (pytest, `requests` monkeypatched):
1. `classify` returns `("coding", 0.91)` from a well-formed answer; `None` on timeout, 429, 500,
   a choice outside the enum, and a body without `answers`.
2. `map_pass` on 300 videos samples 60 evenly (first, every fifth, never two adjacent at the
   start), calls Clef once per sampled video, and leaves META with `mapSampled 60`, `mapDone 60`,
   counts summing to the successes, and one guess per success.
3. A Clef failure on one video: `mapDone` reaches 60, counts sum to 59, the fast pass queue is
   untouched.
4. `create_import` for an existing `clientImportID` does not start a second map.
5. `get_status` carries `map`; an import created before the field reports `map: null`.
6. Quota is unchanged by the map pass.

Kit, `CloudImportTests.swift`:
7. Status with and without `map` decodes; an unknown category key in `counts` is dropped.
8. `apply(status:)` keeps the map with the higher `done`.
9. `applyGuesses` sets the category only on empty, revision-0 rows and reports the count; a
   later revision-8 result with a different category overwrites it; an unavailable result
   clears a guess.

App (DEBUG self-tests, asserted at launch like the others):
10. `TabSlots.selfTest`: every category but `other` has a tab; `FocusPickerView.slots(for:)`
    maps `[.coding, .home, .recipe]` to `[.today, .code, .cook, .home, .library]` and refuses a
    fourth pick; a stored `"home,style"` decodes with Library pinned.
11. `PipelineCenter.expectedSelfTest`: counts `{coding: 30, recipe: 20}`, done 50, total 1,000,
    landed coding 100 → expected coding 500; expected recipe with landed 450 → 0 (clamped);
    completed import → 0 for everything.
12. `xcodegen` + simulator build; `-seedFile` run with a fixture status to screenshot the
    picker, a category tab with skeletons, and the hero bar.

## Not in scope

Cover images to Clef (measured +2 points, documented as the upgrade), inline guesses from the
worker for the unsampled rest of the library, bespoke per-category animations, Haul in the picker,
an `other` tab, Clef as a deep-pass gate (the speech question measured AUC 0.80 and is a separate
decision), and any change to the analysis revision.
