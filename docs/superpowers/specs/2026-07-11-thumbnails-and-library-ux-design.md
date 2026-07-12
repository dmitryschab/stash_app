# Thumbnails + Library list UX — design

Date: 2026-07-11. Status: approved (brainstormed interactively; layout option C chosen
from visual mockups in `.superpowers/brainstorm/`).

## Problem

1. Every Library row shows the category-color fallback because nothing populates
   `Video.thumbnailURL` — the `Thumbnail` view and model field already exist.
2. With the full library loaded (855 videos; e.g. 124 music, 330 other), the Library
   is an endless flat swipe: rows render in an **eager `VStack`** (all rows inflate at
   once) with no sectioning, no jump navigation, and no way to narrow within a segment.
3. The seed loader fabricates `bookmarkedAt` (index × 4 h apart), so any time-based
   grouping would be fiction. The TikTok export carries real save dates (span:
   Aug 2023 → Jul 2026, 36 distinct months).

User intent (asked): browsing is **both** rediscovery and finding-a-specific-save,
about equally — so the design pairs a scan structure (sections + rail) with a cheap
narrowing lever (topic chips).

## Design

### 1. Thumbnails — store pixels, not URLs

TikTok cover URLs are signed CDN URLs that expire (~hours–days). Storing a URL rots;
we download bytes once.

- **Pipeline** (`pipeline-lab/full/run.py`): new resumable `thumbs` stage — for each
  video id with metadata, `yt-dlp -j` → take `thumbnail` (cover) URL → download to
  `pipeline-lab/full/thumbs/<id>.jpg`. Skip-on-exist, ≤5-way parallel (TikTok
  rate-limit), serial retry for stragglers. ~855 × 30–60 KB ≈ 40 MB, free.
- **Seed**: `finalize` stage adds `"thumbnail": "thumbs/<id>.jpg"` (path relative to
  seed.json) to each item whose jpg exists.
- **App** (`App/Sources/SampleData.swift`, `loadSeedFile`): resolve the relative
  `thumbnail` against the seed file's parent directory → `file://` URL →
  `video.thumbnailURL`. The existing `Thumbnail` view (AsyncImage) renders file URLs
  as-is; items without a thumbnail keep the current category-color fallback.
  **No UI changes for this feature.**
- **Production note (spec-only, not built now):** the live sync path already extracts
  the cover URL at enrich time (`Enricher.parse` → `VideoMeta.thumbnailURL`); the
  production pipeline must download it to app storage at that moment — same expiry
  reasoning — e.g. `Documents/thumbs/<videoID>.jpg`, and point `Video.thumbnailURL`
  at the local file.

### 2. Real dates in the seed

- Pipeline: carry `Date` from the export's `FavoriteVideoList` into seed items as
  `"date"` (`yyyy-MM-dd HH:mm:ss`, UTC — same format `ExportParser` already parses).
- `loadSeedFile`: parse `date` → `bookmarkedAt`; keep the current fabricated spacing
  as fallback when the field is absent (sample/pilot seeds).

### 3. Library layout — option C ("compact rows + time rail")

All within `App/Sources/LibraryView.swift`; extract subviews only if a section grows
unwieldy.

- **Lazy rendering**: rows move from `VStack` to `LazyVStack` (fixes eager inflation
  of hundreds of rows; scroll memory/jank).
- **Compact rows**: thumbnail 44 pt → 36 pt, tighter vertical padding, title + one
  meta line — ≈ +40 % rows per screen.
- **Month sections**: group the (filtered) segment by year-month of `bookmarkedAt`,
  newest first, with micro-caps headers ("JULY", "JUNE", …) in the existing `Micro`
  style. Section anchors get stable IDs for the rail.
- **Time rail**: fixed vertical rail on the right edge — month abbreviations for the
  current year plus year markers ('25, '24, '23) for older content (~10 items for
  this dataset). Tapping scrolls to that section via `ScrollViewReader.scrollTo`.
  `ponytail:` no live scroll-position sync/highlight on the rail — static jump
  targets only; add sync if it feels dead in use.
- **Topic chips**: horizontal chip row under the category pills — "all" + top 6
  topics by frequency within the current segment (auto-derived from `Video.topics`,
  no curation). Selecting a chip filters rows *and* the featured card. Chip
  selection resets when the segment pill changes.
- Featured card, pills, needs-a-look section, empty state: unchanged.

## Error handling

- Missing/corrupt thumbnail file → AsyncImage placeholder = current fallback icon.
- Unparseable `date` → fabricated-spacing fallback (never crash on seed data).
- Segment with < 2 distinct months → rail hides (nothing to jump between).
- Segment with no topics → chip row hides.

## Testing / verification

- `run.py selftest` still green; `thumbs` stage idempotent (re-run skips existing).
- Rebuild app; **terminate then relaunch** with updated seed (launch alone
  foregrounds stale data); verify SwiftData row count still 855.
- Screenshot Library (music + other), verify thumbnails render, sections + rail
  present; tap-test rail jump and chip filter in the simulator.
- Existing Kit tests untouched (no Kit code changes).

## Out of scope

- Production thumbnail download in the live sync path (noted above; post-API-approval).
- Search tab, Today, MindMap, analyzer prompt/pipeline.
- Rail scroll-sync highlight; grid layout (option B) — revisit only if C disappoints.
