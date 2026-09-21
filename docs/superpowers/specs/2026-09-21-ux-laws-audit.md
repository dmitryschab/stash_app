# Stash × 10 UX Laws — audit and rework proposals

2026-09-21 · build 51 (main @ 034e197) · method: 4 code auditors over `App/Sources` + headless simulator run
(all 7 tabs, Import, Search, one detail) on iPhone 17 Pro Max with `-seedSample`. Top claims spot-checked in source.
Paths are relative to `App/Sources/`. Codes (F#, R#) stay fixed for this conversation.

## Scorecard

| # | Law | Grade | One-line verdict |
|---|-----|-------|------------------|
| 1 | Jakob's | weak | Search is invisible, 6 of 7 tabs are unlabeled, the five verticals each speak a different dialect |
| 2 | Hick's | good | One product, 5 default tabs, TopicPicker tames ~350 topics. Haul is the exception |
| 3 | Fitts's | weak | Sub-44pt targets sit exactly on critical paths. The in-house fix pattern already exists |
| 4 | Miller's | ok | Shelves chunk well; "Needs a look" and Cook Mode break it |
| 5 | Proximity | ok− | Group gaps ≈ item gaps in several screens (10 vs 12pt) |
| 6 | Von Restorff | mixed | Video detail is clean; Import, Haul detail and Film page are not |
| 7 | Serial position | good | Lately first, Library pinned last. One serious miss: the JSON step |
| 8 | Tesler's | split | Excellent inside the app, poor at the front door (the TikTok export path) |
| 9 | Doherty | weak | Core flow: import progress and errors are invisible outside the Import screen |
| 10 | Peak-End | weak ends | Waiting states are great; completion moments are flat or lead with failures |

## Do first (highest user impact)

- **F1** search has no tap entry · **F29–F31** import progress/errors invisible · **F11** tap targets · **F24** JSON step · **F37** completion line

## Findings by law

### 1 · Jakob's — familiar patterns
- **F1 high** — Search opens only by hold 0.35s + push right 70pt on the pill (`TikTokBrainApp.swift:564`). The sole hint is 9pt text at 50% ink, and it is removed forever after the first open (`:364`) — confirmed on the simulator. Cook (`CookView.swift:275`) and Haul (`HaulView.swift:140`) show visible search fields, so the app teaches a pattern and then hides the stronger search behind another one. **Fix:** permanent magnifier at the pill's right end calling the existing `open()`; keep the gesture as the shortcut.
- **F2 med** — Only the open tab has a label (`:497`). Lately's glyph `point.3.connected.trianglepath.dotted` and Library's grid are not self-evident. **Fix:** labels always on when ≤5 slots (the default).
- **F3 med** — A slow tap (>0.35s) on a tab fires the haptic, dims the bar, then does nothing, and swallows taps for 300ms more (`:521-581`). **Fix:** release with <10pt travel = tap.
- **F4 high** — Same-looking chip row means different things: Music chips are 2 sorts + 1 filter that can blank the page while the header still counts records (`MusicView.swift:332`); Cook/Films are filters; Haul has its own chip style, search, More-sheet and sort (`HaulView.swift:140-215`). **Fix:** R3.
- **F5 high** — `arrow.up.right` means "leaves the app" everywhere except Code, where it means "has links" on a row that pushes in-app (`CodeView.swift:148,220`). Music "From your TikToks" rows leave the app; pixel-identical Films "Saved in" rows push a screen (`MusicView.swift:689`, `FilmsView.swift:423`). **Fix:** arrow = outbound only, chevron = push.
- **F6 med** — Pipeline jargon in user copy: "Cloud import" twice in the Import hero (`ImportView.swift:171,175`), "Fast pass", "partial failures" (`:227-229`), "Re-run pipeline" under every detail CTA (`VideoDetailView.swift:463`).
- **F7 med** — Guide sheet: bold toolbar "Done" only dismisses; "I've requested it" is what starts the waiting state (`DataDownloadGuideView.swift:48-62`). **Fix:** toolbar → "Close" as `.cancellationAction`.

### 2 · Hick's — fewer choices
- **F8 med** — Haul list stacks 4 narrowing tools; category is settable in two of them; "More" highlight follows `status`, not `filtering`; sort glyph is always ↓ (`HaulView.swift:140-245`).
- **F9 med** — Haul detail ≈14 targets; "Open the link from the video" exists twice (`HaulDetailView.swift:84,456`).
- **F10 low** — Settings shows 7 tab toggles with no recommended set and no reset (`ImportView.swift:632`). **Fix:** "Reset to recommended" row.

### 3 · Fitts's — size and reach
- **F11 high** — Critical-path targets under 44pt: Library "all ›" ≈35×11pt, the only door past shelf caps (`LibraryView.swift:182`); Library header Import/Map/Settings 38pt in the top-right corner (`:130-152`); "How to get your TikTok data" ≈15pt (`ImportView.swift:279`); paywall Restore / Sign out / Delete ≈12pt (`PaywallView.swift:170-215`); empty-state Import CTA ≈30pt (`Theme.swift:504`); Music sort chips 26pt (`MusicView.swift:337`); PreviewButton 32–36pt and "▶ Clip" 19pt (`:774,940,1010,788`); Film "Open on Wikipedia" ≈16pt (`FilmsView.swift:394`). **Fix:** R5 — the pattern already exists in `StashBackButton` (`Theme.swift:710`) and `TopicChip` (`CookView.swift:164`).
- **F12 med** — At 7 slots on a 375pt phone each slot is 42.5pt with zero spacing (`TikTokBrainApp.swift:490-519`).
- **F13 med** — `Micro` default ink 0.45 = 2.75:1, 0.55 = 3.65:1, used at 8–10pt (`Theme.swift:95-107`). **Fix:** default 0.62 (≈4.5:1).

### 4 · Miller's — chunking
- **F14 med** — "Needs a look" is an uncapped flat list of hundreds under five capped shelves (`LibraryView.swift:275`). **Fix:** `prefix(5)` + "all ›".
- **F15 high** — Cook Mode gets steps but no ingredients; checking a quantity means leaving full-screen and losing your step (`CookView.swift:408,536`). **Fix:** pass ingredients, one chip in the header.
- **F16 med** — Budget card shows two numbers that disagree (badge counts trial videos, sentence doesn't) plus a third paragraph (`ImportView.swift:315,339`).
- **F17 med** — Sign-in: ≈60 words of grey text in 3 blocks above the button; the invite field is a screen away from its only submit (`SignInView.swift:59-149`).

### 5 · Proximity
- **F18 low** — Gaps don't encode grouping: Import 10 vs 12pt (`ImportView.swift:93-111`); Lately card gap 14 < card padding 18 (`LatelyView.swift:135`); detail sections 20 vs rows 18 (`VideoDetailView.swift:117`); Haul detail 13 ad-hoc paddings. **Fix:** two Theme tokens — group 24, item 8–10.
- **F19 med** — Import screen mixes unrelated content: a 5-line privacy block between hero and CTA, and Library category tiles below the importer (seen on simulator).

### 6 · Von Restorff — one thing stands out
- **F20 med** — Import: the green hero card and the black CTA both open the same file picker (`ImportView.swift:164,273`). **Fix:** hero becomes status-only.
- **F21 med** — Haul detail's one filled button duplicates offer row 0 (`HaulDetailView.swift:275-288`).
- **F22 high** — Film page has no primary action at all; every other vertical has one (`FilmsView.swift:394`). **Fix:** "Watch the clip" primary, Wikipedia secondary.
- **F23 med** — Import, the app's core action, is a 38pt outline icon in the top-right of the last tab.

### 7 · Serial position
- **F24 high** — "Select file format: JSON — this one matters" is step 3 of 4 (`DataDownloadGuideView.swift:31`). Miss it → two-day wait wasted, and the error says "The export contains no bookmarked videos" (`PipelineCenter.swift:312`). **Fix:** JSON callout above the list; error names the TXT cause.

### 8 · Tesler's — product absorbs complexity
- **F25 high** — Export path is 8 manual steps and automates none: picker allows `[.json, .folder]` only so the downloaded zip is greyed out (`ImportView.swift:120`); "I've requested it" schedules no reminder though local notifications exist (`PipelineCenter.swift:892`); no deep link into TikTok.
- **F26 med** — No paste-a-link path; "Or share a TikTok to Stash…" is static text (`ImportView.swift:291`). The extension's parser already exists.
- **F27 med** — Search suggestions are 3 hardcoded strings; no history (`SearchView.swift:211`). **Fix:** top `video.topics` from the library.

### 9 · Doherty — feedback
- **F29 high** — The shell pill reads on-device `center.progress` only; cloud import (the only Release path) reports via `cloudStatus`, and `isImporting` drops right after submit (`TikTokBrainApp.swift:335`, `PipelineCenter.swift:353`). A 1000-video import shows progress on the Import screen only.
- **F30 high** — After picking the export nothing changes for seconds: parse + quota call + up to 1200 inserts run before `isImporting = true`; the button stays tappable (`PipelineCenter.swift:288-355`).
- **F31 high** — 14+ sites write `lastError`; one view reads it (`ImportView.swift:102`). No dismiss, no retry.
- **F32 high** — Search shows a false "No saves matched." while the index builds, and no spinner during the 400ms debounce + embedding call (`SearchView.swift:84,119`).
- **F33 plausible** — Signed-in, not entitled, `quota == nil` → bare spinner with no timeout or retry (`TikTokBrainApp.swift:258-262`). Needs a check of whether sign-in always returns quota.
- **F34 med** — Film posters: "still resolving" and "will never resolve" look identical (`FilmsView.swift:348`).
- **F35 med** — Mind map has no re-fit after pan/zoom (`MindMapView.swift:79-141`).
- **F36 low** — The search hint text overlaps cards on Music, Haul and Import (seen on simulator).

### 10 · Peak-End
- **F37 high** — Completion line reads "Complete · N unavailable · N partial failures": failures only, never the win, and it never expires (`ImportView.swift:229`). The push notification already says it right (`PipelineCenter.swift:896`).
- **F38 med** — Cook Mode "DONE" just dismisses; no success frame, no haptic (`CookView.swift:598`).
- **F39 low** — With the sample library, Lately is one card, "You're caught up", and 60% empty screen.

## Rework proposals

- **R1 — Visible search + labelled bar** (F1 F2 F3 F12 F36). Default 5 labelled slots; fixed magnifier at the pill's right end; gesture stays as accelerator; slow tap counts as tap. ~3h.
- **R2 — One status channel in the shell** (F29 F30 F31 F37). One pill above the bar for: reading export → syncing N of M (cloud) → "N videos sorted" → errors, tappable into Import. ~4h.
- **R3 — One list grammar for all verticals** (F4 F5 F8 F9 F21 F22). Shared header: `TopicChip` filters + one sort menu; arrow = outbound, chevron = push; exactly one primary per detail. ~1 day.
- **R4 — Export path absorbs the work** (F24 F25 F26 F7). JSON callout on top, accept .zip, 1h/24h reminders, TikTok deep link, PasteButton. ~1 day; zip needs a dependency or small reader (`ExportParser.swift:10` punts on it today).
- **R5 — Tap-target + contrast pass** (F11 F13). One `minTapTarget()` modifier at the listed sites, `Micro` default 0.62. ~1h. Zero layout risk.

Suggested order: R5 → R2 → R1 → R4 → R3.

## Keep (already follows the laws)

- Five distinct Lately empty states with a next step each (`LatelyView.swift:397-427`).
- "Waiting on TikTok" empty states after "I've requested it" (`Theme.swift:504-533`).
- Music service asked once, stored, changeable in Settings (`MusicView.swift:1207-1229`).
- `OfferStore` shows day-old prices instead of a spinner and prefetches (`HaulDetailView.swift:645-744`).
- One product, one price, one Subscribe button (`PaywallView.swift:137-157`).
