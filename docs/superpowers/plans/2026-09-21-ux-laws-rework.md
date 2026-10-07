# UX Laws Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Stash follow the ten UX laws from the audit: visible search and a labelled bar, one status channel for imports, an export path that absorbs the work, one list grammar across shelves, and 44 pt targets everywhere.

**Architecture:** No new screens and no new dependencies. Three foundation changes land first (Theme helpers, a pure `ShellStatus` on `PipelineCenter`, a zip reader in the Kit); every later task owns a disjoint set of view files and consumes only those three. Tasks run as waves of three Opus subagents, each in its own git worktree, merged into `feat/ux-laws-rework` between waves.

**Tech Stack:** SwiftUI (iOS 17), Swift 5, XcodeGen, SwiftData, TikTokBrainKit (SwiftPM, `swift test`), Compression framework.

**Spec:** `docs/superpowers/specs/2026-09-21-ux-laws-audit.md` (findings F1–F39, reworks R1–R5). Visual reference: https://claude.ai/code/artifact/f0bd001f-c073-46a3-8980-5a0c9eba39ce

## Global Constraints

- Deployment target iOS 17.0; **no new packages or dependencies**.
- The shell stays a custom pill. **No native `TabView`, no keep-alive tabs** (measured 3× worse, see memory `stash-tab-switch-perf-findings`).
- Haul keeps its approved visual design (`docs/design/haul/approved-mock.png`) and its search field. Haul tasks change logic only.
- The third-party processing disclosure on Import (Groq, AWS Bedrock) stays **verbatim**; it may move, not shrink.
- Every interactive element has a hit area of at least 44×44 pt. No text under 9.5 pt except tab-bar labels (8.5 pt).
- `Micro`'s default ink opacity is 0.62. Do not pass an opacity under 0.62 for text of 11 pt or smaller on `stashBackground`.
- Copy: no pipeline jargon in user-visible strings ("cloud import", "fast pass", "partial failures", "pipeline").
- `arrow.up.right` means "leaves Stash". `chevron.right` means "pushes a screen". Nothing else.
- Match the surrounding code: comment density, naming, idiom. Mark deliberate shortcuts with a `ponytail:` comment naming the ceiling.
- Non-trivial logic leaves one runnable check: Kit code gets a `swift test` case; app code gets a `#if DEBUG static func selfTest() -> Bool` in the file's existing style. **Do not register self-tests in `TikTokBrainApp.swift`** — the orchestrator does that at merge (lines 42–46).
- Subagents never boot or launch a simulator, never use desktop control, never push, never edit a file outside their task's **Files** list. If a needed change falls outside the list, stop and report it.
- Commits: conventional messages, **no co-author or "Generated with" footer**.
- Build check (run from the worktree root):

```bash
cd App && xcodegen generate && xcodebuild -project Stash.xcodeproj -scheme Stash -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd build 2>&1 | tail -15
```

Expected last lines contain `** BUILD SUCCEEDED **`. Kit check: `cd TikTokBrainKit && swift test 2>&1 | tail -5` — both summary lines ("Executed N tests" and "Test run with N tests") must show 0 failures.

## File ownership and waves

| Wave | Task | Files (exclusive) |
|------|------|-------------------|
| 0 | T1 Theme foundation | `App/Sources/Theme.swift` |
| 0 | T2 Shell status + reminders | `App/Sources/PipelineCenter.swift` |
| 0 | T3 Zip exports | `TikTokBrainKit/Sources/TikTokBrainKit/ExportParser.swift`, new `ZipReader.swift`, `Tests/.../ExportParserTests.swift`, `Tests/.../Fixtures/` |
| 1 | T4 Shell: search, labels, pill | `App/Sources/TikTokBrainApp.swift` |
| 1 | T5 Import + export guide | `App/Sources/ImportView.swift`, `App/Sources/DataDownloadGuideView.swift` |
| 1 | T6 Library + Search | `App/Sources/LibraryView.swift`, `App/Sources/SearchView.swift` |
| 2 | T7 Music + Code | `App/Sources/MusicView.swift`, `App/Sources/CodeView.swift` |
| 2 | T8 Films + Cook | `App/Sources/FilmsView.swift`, `App/Sources/FilmSection.swift`, `App/Sources/CookView.swift` |
| 2 | T9 Haul logic | `App/Sources/HaulView.swift`, `App/Sources/HaulDetailView.swift` |
| 3 | T10 Small fixes | `App/Sources/PaywallView.swift`, `SignInView.swift`, `MindMapView.swift`, `LatelyView.swift`, `VideoDetailView.swift` |
| 3 | T11 Integration check | orchestrator only |

Between waves the orchestrator merges the task branches, registers new self-tests, runs both checks, and checks usage (`npx -y ccusage@latest blocks --active --json`; pause at 95%).

---

### Task 1: Theme foundation (F11 F13 F18)

**Files:** Modify `App/Sources/Theme.swift`

**Interfaces — Produces:**

```swift
extension View {
    /// Grows the hit area to Apple's 44 pt minimum. The visual stays whatever the caller drew.
    func minTapTarget(_ side: CGFloat = 44) -> some View {
        frame(minWidth: side, minHeight: side).contentShape(Rectangle())
    }
}

/// Two gaps, so spacing can say "same group" or "next group" and nothing in between.
enum StashSpacing {
    static let group: CGFloat = 24
    static let item: CGFloat = 10
}
```

- [ ] **Step 1:** Add `minTapTarget` next to `stashCard`/`stashOutlineCard` (Theme.swift ~156–169) and `StashSpacing` under the colour extension.
- [ ] **Step 2:** `Micro` (Theme.swift:95–107): change the default `color` from `.stashInk.opacity(0.45)` to `.stashInk.opacity(0.62)`. In `StashHeader` change the trailing `Micro` from `opacity(0.5)` to `opacity(0.62)`.
- [ ] **Step 3:** `StashEmptyState` (Theme.swift ~504–533): give the Import `NavigationLink` label `.minTapTarget()`; keep the chip's look.
- [ ] **Step 4:** Inside Theme.swift only, raise any remaining explicit `Micro` opacity under 0.62 to 0.62 and any `Micro` size under 9.5 to 9.5 (TimeRail labels at ~622 are 8.5).
- [ ] **Step 5:** Run the build check. Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 6:** Commit: `feat(theme): 44pt tap-target helper, spacing tokens, readable micro ink`

---

### Task 2: Shell status, import routing, export reminders (F29 F30 F31 F24 F25)

**Files:** Modify `App/Sources/PipelineCenter.swift`

**Interfaces — Produces** (members of `PipelineCenter` unless noted):

```swift
/// What the shell's one status pill says. Pure, so it can be checked without a pipeline.
enum ShellStatus: Equatable {
    case reading                          // an export was picked; nothing submitted yet
    case syncing(done: Int, total: Int)   // on-device drain or the cloud's sorting pass
    case shares(Int)                      // shared TikToks in flight
    case finished(sorted: Int)            // a cloud import completed under 24 h ago, not dismissed
    case failed(String)                   // a failed share, or lastError
}

var shellStatus: ShellStatus? { get }
var importRouteRequested = false          // the shell sets it; Library pushes ImportView on it
func dismissShellStatus()                 // clears .failed / .finished
func scheduleExportReminders()            // local notifications at +1 h and +24 h; idempotent
func cancelExportReminders()

static func shellStatus(isImporting: Bool, progress: (done: Int, total: Int)?,
                        cloud: CloudImportStatus?, pendingShares: [PendingShare],
                        lastError: String?, dismissedImportID: String?, now: Date) -> ShellStatus?
#if DEBUG
static func shellStatusSelfTest() -> Bool
#endif
```

Priority inside the pure function, first match wins: failed share → `.syncing` from `progress` (total > 0) while importing → `.reading` while importing with no progress → `.syncing` from `cloud` when `cloud.state == .accepted || .fastPass` → `.shares(n)` → `.failed(lastError)` → `.finished(sorted: cloud.fastPass.done - cloud.unavailable)` when `cloud.state == .completed`, `now - cloud.updatedAt < 86_400` and `cloud.importID != dismissedImportID` → `nil`.

- [ ] **Step 1: Write the check first.** Add `shellStatusSelfTest()` asserting, with hand-built inputs: no work → `nil`; importing + no progress → `.reading`; importing + `(3, 40)` → `.syncing(done: 3, total: 40)`; cloud `.fastPass` 412/941 → `.syncing(done: 412, total: 941)`; cloud `.completed` 941 done, 12 unavailable, updated 1 h ago → `.finished(sorted: 929)`; same, 25 h ago → `nil`; same, dismissed id → `nil`; a `.failed("Out of imports")` share beats a running sync; `lastError` alone → `.failed`.
- [ ] **Step 2:** Implement the enum, the pure function and the `shellStatus` computed property (it passes the instance state and `Date()`). Persist `dismissedImportID` in `UserDefaults` under `"shellStatusDismissedImport"`. `dismissShellStatus()` sets `lastError = nil` and stores `cloudStatus?.importID`.
- [ ] **Step 3:** `runCloudImport` (~288–355): set `isImporting = true` and `lastSummary = "Reading your export…"` directly after the entry `guard`, keeping the existing `defer { isImporting = false }` semantics (move the `defer` up with it). The button must no longer be tappable while the file is parsed.
- [ ] **Step 4:** Replace the empty-export message at ~312 with: `"No favourites found. If you chose TXT when you asked TikTok for the export, ask again with the format set to JSON."`
- [ ] **Step 5:** Reminders. Reuse the notification authorisation path `notifyLibraryReady` (~892) already uses. Identifiers `"export-reminder-1h"` and `"export-reminder-24h"`, `UNTimeIntervalNotificationTrigger` 3 600 s and 86 400 s, title `"Your TikTok export may be ready"`, body `"Download it from TikTok and bring it into Stash."`. `scheduleExportReminders()` removes pending requests with those identifiers before adding. Call `cancelExportReminders()` wherever `exportRequestedKey` is cleared on a submitted import.
- [ ] **Step 6:** Run the build check. Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 7:** Commit: `feat(pipeline): one shell status, import routing flag, export reminders`

---

### Task 3: Read a real zip export (F25)

**Files:** Create `TikTokBrainKit/Sources/TikTokBrainKit/ZipReader.swift`; modify `ExportParser.swift`; modify `Tests/TikTokBrainKitTests/ExportParserTests.swift`; add fixtures under `Tests/TikTokBrainKitTests/Fixtures/`

**Interfaces — Produces:**

```swift
/// Reads the JSON members of a zip without unpacking it to disk.
/// ponytail: no zip64, no encryption, whole member in memory — fine for TikTok exports
/// (tens of MB); swap for a streaming reader if one ever exceeds a few hundred MB.
enum ZipReader {
    static func jsonMembers(of url: URL) throws -> [Data]
}
```

`ExportParser.parse(zipAt:)` keeps its signature; a file whose extension is `zip` or whose first four bytes are `50 4B 03 04` now goes through `ZipReader` and merges every member, exactly as the directory branch merges files. Anything unreadable throws `CocoaError(.fileReadCorruptFile)`.

- [ ] **Step 1: Fixtures.** From a small export JSON (reuse an existing fixture's content) build two archives with `/usr/bin/zip`: `export-deflated.zip` (default) and `export-stored.zip` (`zip -0`), each holding `user_data_tiktok.json`; plus `export-txt.zip` holding only `Favorite Videos.txt`.
- [ ] **Step 2: Failing tests.** Add `testParsesDeflatedZip`, `testParsesStoredZip` (both expect the same bookmarks as the raw JSON fixture), `testTxtOnlyZipYieldsNoBookmarks` (expects `[]`), `testGarbageZipThrows` (4 random bytes renamed `.zip` → throws). Run `swift test --filter ExportParserTests`; expected: the three zip tests FAIL (today a zip throws `fileReadUnknown`).
- [ ] **Step 3: Implement `ZipReader`.** Find the End of Central Directory record (signature `0x06054b50`, scan back up to 65 557 bytes), walk the central directory (`0x02014b50`), keep entries whose name ends in `.json` (case-insensitive) and that are not directories, read each local header (`0x04034b50`) to find the data offset, then: method 0 → the bytes as they are; method 8 → inflate with `compression_decode_buffer(..., COMPRESSION_ZLIB)` into a buffer of the entry's uncompressed size (zip deflate is raw deflate, which is what `COMPRESSION_ZLIB` decodes). Any other method, a set encryption bit, or a `0xFFFFFFFF` size (zip64) throws `CocoaError(.fileReadCorruptFile)`.
- [ ] **Step 4:** Wire it into `parse(zipAt:)`; update the type's doc comment (it still says zips are out of scope).
- [ ] **Step 5:** `cd TikTokBrainKit && swift test 2>&1 | tail -5`. Expected: both summary lines, 0 failures.
- [ ] **Step 6:** Commit: `feat(kit): parse TikTok exports straight from the zip`

---

### Task 4: Shell — visible search, labelled bar, one status pill (F1 F2 F3 F12 F29 F31 F33 F36)

**Files:** Modify `App/Sources/TikTokBrainApp.swift`

**Interfaces — Consumes:** `PipelineCenter.ShellStatus`, `center.shellStatus`, `center.importRouteRequested`, `center.dismissShellStatus()`, `View.minTapTarget()`.

- [ ] **Step 1: Labels.** In `StashTabBar.tabs` (~490–519): when `slots.count <= 5` every slot shows its `Micro` label (8.5 pt, tracking 0.7; unselected colour `stashOnInk.opacity(0.62)`), all slots share the width equally and the open slot no longer takes a fixed 80 pt. When `slots.count > 5` keep today's behaviour, but the open slot is 64 pt wide when `slots.count == 7`. Update the doc comment above `tabs`.
- [ ] **Step 2: Search button.** At the trailing end of the `tabs` HStack add a 1×28 pt divider (`stashOnInk.opacity(0.18)`) and a 44×44 pt circle (stroke `stashOnInk.opacity(0.4)`, 1.5 pt) holding `magnifyingglass` at 17 pt semibold; tap calls the existing `open()`; `.accessibilityLabel("Search")`. The hold-and-push gesture stays as the accelerator.
- [ ] **Step 3: A slow tap is a tap.** In `gripGesture`'s `.onEnded`, when the grip did not commit and the drag travelled under 10 pt, select the slot under the touch's start x (slot index = x ÷ slot width, clamped) instead of only springing back, and do not start the 0.3 s `gripEndedAt` swallow for that case. Extend `SearchGrip.selfTest()` with the index arithmetic if you factor it into a pure function.
- [ ] **Step 4: Remove the hint.** Delete the `"Hold the bar · push right to search"` `Micro`, the `searchGripHintDone` `@AppStorage`, and the `.onChange(of: searchOpen)` that set it (~348–366).
- [ ] **Step 5: One pill.** Replace the `if center.isImporting … else if !center.pendingShares.isEmpty …` block (~335–346) with a `switch center.shellStatus`: `.reading` → "Reading your export…"; `.syncing(d, t)` → "Syncing d of t" plus a 48×3 pt progress track; `.shares(n)` → today's "Syncing 1 share" / "Syncing n shares"; `.finished(sorted)` → checkmark + "sorted videos sorted"; `.failed(message)` → `exclamationmark.triangle` + message (one line, truncated). Extend `ImportSyncPill` rather than adding a second pill type. The whole pill is a `Button` that sets `tab = .library` then `center.importRouteRequested = true`. `.finished` and `.failed` carry a trailing `xmark` with `.minTapTarget()` calling `center.dismissShellStatus()`. The pill's hit area is at least 44 pt tall (pad the target, keep the 32–36 pt look). Keep the existing transitions.
- [ ] **Step 6: No dead spinner.** In `paidShell` (~245–262) add `.task { if session.quota == nil { await session.refreshQuota() } }`. In `splash`, after 8 s still on screen, show `"Still checking your account…"` and a `StashPrimaryButton(title: "Try again")` that calls `refreshQuota()` again.
- [ ] **Step 7:** Run the build check. Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 8:** Commit: `feat(shell): visible search, labelled tabs, one status pill`

---

### Task 5: Import screen and export guide (F6 F7 F10 F11 F16 F19 F20 F24 F25 F26 F37)

**Files:** Modify `App/Sources/ImportView.swift`, `App/Sources/DataDownloadGuideView.swift`

**Interfaces — Consumes:** `StashSpacing`, `minTapTarget()`, `PipelineCenter.shared.scheduleExportReminders()`, `controller.dismissShellStatus()`, `ExportParser` zip support (no call-site change), `TikTokLink.firstLink(in:)`, `SharedInbox`.

- [ ] **Step 1: The hero is status, not a button.** `syncCard` (~160–193): remove its tap action and `.disabled`. Eyebrow `"TikTok"` only (delete the duplicate "Cloud import" eyebrow). Title by state: none → `"Import your saves"`; `.accepted`/`.fastPass` → `"Syncing your saves"`; `.completed` under 24 h old → `"Library ready"`. Keep the progress bar.
- [ ] **Step 2: Human status copy** (`subtitleLine`, ~222–235): `.fastPass` → `"Sorted N of M · you can close the app, Stash pings you when it is done"`; `.completed` → `"\(done - unavailable) videos sorted onto your shelves"`, followed by `" · K could not be read — private or deleted on TikTok"` only when `unavailable + partialFailures > 0`. Once `status.updatedAt` is over 24 h old, fall through to the fresh-account line.
- [ ] **Step 3: One primary.** `StashPrimaryButton(title: "Choose TikTok export", systemImage: …)`; under it a centred 11.5 pt caption `"Zip, folder or JSON — Stash unpacks it."`; `.fileImporter(allowedContentTypes: [.json, .folder, .zip])` (~120).
- [ ] **Step 4: Two option rows in one outline card**, each at least 56 pt tall with a trailing `chevron.right`: "Paste a TikTok link" and "How to get your TikTok data" / "TikTok takes up to 2 days". Paste reads `UIPasteboard.general.string`, runs `TikTokLink.firstLink(in:)`, writes the link through the same `SharedInbox` call the share extension uses (`App/ShareExtension/ShareViewController.swift:53` shows it), then triggers the inbox drain the app already runs on foreground. With no link on the clipboard show `"No TikTok link on the clipboard."` under the row. The paste row's subtitle states the real cost of a shared video, read from the constant the quota copy at ~339–342 uses. This replaces the static "Or share a TikTok…" line (~291–297) and the 15 pt guide link (~279–287).
- [ ] **Step 5: One budget number.** Show `"\(quota.remaining) videos left"` as the hero's badge; delete the sentence that counts a different bucket (~339–342) and the separate budget card if nothing else remains in it.
- [ ] **Step 6: Order and gaps.** hero → `StashSpacing.group` → primary + caption → 16 → option card → `StashSpacing.group` → the processing disclosure card (text **unchanged**) → `StashSpacing.group` → error. Show the "Library" category tiles (~379) only while the hero reads "Library ready".
- [ ] **Step 7: Errors can be dismissed.** The `lastError` line (~102) gets a trailing `xmark` with `.minTapTarget()` calling `controller.dismissShellStatus()`.
- [ ] **Step 8: Settings.** Under the Tab bar section (~632–661) add a row `"Reset to recommended"` that writes `TabSlots.encode(TabSlots.fallback)` to the `tabSlots` `@AppStorage`.
- [ ] **Step 9: Guide.** Toolbar item becomes `ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }`. Above the numbered list add a callout card filled `Color.categoryOther` with ink text: eyebrow `"The one setting that matters"`, title `"Choose JSON, not TXT"` (22 pt heavy), body `"Stash cannot read a TXT export, and you would wait two days to find out."`. "Request it" shrinks from 4 steps to 3 (the JSON step is now the callout). In the retrieval list delete the "Uncompress" step. Add an outlined 48 pt capsule `Link("Open TikTok settings", destination: URL(string: "https://www.tiktok.com/setting/download-your-data")!)` with a trailing `arrow.up.right`. "I've requested it" also calls `PipelineCenter.shared.scheduleExportReminders()`; under it the line `"Stash reminds you in 1 hour and again tomorrow."`.
- [ ] **Step 10:** Run the build check. Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 11:** Commit: `feat(import): one primary action, paste a link, zip exports, JSON-first guide`

---

### Task 6: Library and Search (F11 F14 F23 F27 F32)

**Files:** Modify `App/Sources/LibraryView.swift`, `App/Sources/SearchView.swift`

**Interfaces — Consumes:** `minTapTarget()`, `PipelineCenter.shared.importRouteRequested`. **Produces:** `SearchSuggestions.topTopics(in:limit:) -> [(topic: String, count: Int)]` and `SearchSuggestions.selfTest()` (DEBUG).

- [ ] **Step 1: Labelled header actions.** Replace the three 38 pt icon circles (~126–152) with one row under the title: three outlined capsules, 44 pt tall, icon + `Micro` label — "Import", "Map", "Settings" — same destinations as today.
- [ ] **Step 2: Route from the pill.** On the Library `NavigationStack` content add `.navigationDestination(isPresented: $center.importRouteRequested) { ImportView() }` (use `@Bindable` on the shared center as the file already does for observation).
- [ ] **Step 3: "All" is a target.** `shelfHeader` (~177–189): the link reads `"All \(count)"` + chevron inside a 28 pt outlined capsule (`stashInk.opacity(0.28)`, 1.2 pt) with `.minTapTarget()`; `Micro` size 9.5. The row is 44 pt tall; drop the header's `.padding(.top, 24)` to 16 so rhythm holds.
- [ ] **Step 4: Cap "Needs a look".** `ForEach(needsLook.prefix(5))` (~275) and give the section the same `shelfHeader` with an "All N" link into `IntentListView`.
- [ ] **Step 5: Badges.** `LibraryRow` badge (~476–480): `Micro` size 9.5, capsule 28 pt tall, `.minTapTarget()` when it is tappable.
- [ ] **Step 6: No false "No saves matched."** SearchView ~84: condition becomes `results.isEmpty, scoredQuery == trimmedQuery, !index.isEmpty`. While `scoredQuery != trimmedQuery`, the index is empty, or the embedding call is in flight, show a row: mini `ProgressView` + `Micro("Also checking by meaning…")` above whatever results exist.
- [ ] **Step 7: Suggestions from the library.** Write `SearchSuggestions.topTopics` (count `video.topics` case-insensitively, keep first-seen spelling, sort by count then name, take `limit`) with a `selfTest()` covering ties, case-folding and an empty library. Replace the hardcoded chips (~211) with the top 5 under `"From your saves"`; tapping one sets the query.
- [ ] **Step 8: Recents.** `@AppStorage("recentSearches")` holding up to 5 queries joined by `\n`; record a query when a result is opened; show them above the topics under `"Recent"` as 44 pt rows with a clock glyph.
- [ ] **Step 9:** Run the build check. Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 10:** Commit: `feat(library,search): real targets, capped pile, honest search states, own-topic suggestions`

---

### Task 7: Music and Code speak the shared grammar (F4 F5 F11)

**Files:** Modify `App/Sources/MusicView.swift`, `App/Sources/CodeView.swift`

**Interfaces — Consumes:** `TopicChip` (CookView.swift:164), `minTapTarget()`.

- [ ] **Step 1: Chips filter, the menu sorts.** `Sorting` (~332–354) keeps `.recent` and `.mostSaved` only and moves into a `Menu` at the trailing end of the first section header, labelled with the current sort plus `arrow.up.arrow.down`, `.minTapTarget()`. "Whole albums" becomes a filter chip drawn with `TopicChip` beside "All", with its count; add further chips only for distinctions the model already has (a list of releases, if `items` exposes one). Do not invent categories.
- [ ] **Step 2: Honest header.** When a filter is on, `trailing` reads `"\(shown.count) of \(items.count)"`, as Cook does (CookView.swift:63–66). A filter with zero items is not offered.
- [ ] **Step 3: Targets.** `PreviewButton` (~1160): `.padding(max(5, (44 - size) / 2))`. "▶ Clip" (~788–793, ~1010): `.minTapTarget()`. Every `Micro` under 9.5 pt in this file (8, 8.5, 9 at ~530, 568, 957) becomes 9.5.
- [ ] **Step 4: Arrows.** "From your TikToks" rows (~689–716) leave the app: give them a trailing `arrow.up.right`.
- [ ] **Step 5: Code.** In `CodeView.swift` (~148–152, ~220) rows and the featured card push `VideoDetailView`, so their trailing glyph is `chevron.right`; mark "has links" with a `link` glyph plus the count in the meta line instead of `arrow.up.right`. Featured-card tag `Micro`s at 9.5 pt minimum.
- [ ] **Step 6:** Run the build check. Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 7:** Commit: `feat(music,code): chips filter, menus sort, arrows only leave the app`

---

### Task 8: Films gets a primary action, Cook Mode gets ingredients and an ending (F15 F22 F34 F38 F5)

**Files:** Modify `App/Sources/FilmsView.swift`, `App/Sources/FilmSection.swift`, `App/Sources/CookView.swift`

**Interfaces — Consumes:** `StashPrimaryButton`, `ShimmerBlock` (Theme.swift:200), `minTapTarget()`. **Produces:** `CookModeView(title: String, steps: [String], ingredients: [String], videoID: String)`; `CookedLog` (UserDefaults-backed `[videoID: Date]`, key `"cookedRecipes"`).

- [ ] **Step 1: Film page.** After the year (`FilmsView.swift` ~388–397) add `StashPrimaryButton(title: "Watch the clip", systemImage: "play.fill")` opening the TikTok URL of the first save that named the film (the saves the page already lists). Wikipedia becomes a secondary outlined 48 pt capsule `"Wikipedia"` + `arrow.up.right`, still only `if let ref`. "Saved in" rows (~423–454) get a trailing `chevron.right`.
- [ ] **Step 2: Posters tell you they are loading.** Store resolution results as `[String: FilmRef?]` in both `FilmsView` and `FilmSection` so a recorded miss differs from "not resolved yet"; show `ShimmerBlock` while the key is absent, the typographic sleeve only for a recorded miss.
- [ ] **Step 3: Ingredients in Cook Mode.** `CookModeView` takes `ingredients` and `videoID`; `RecipeDetailView` passes `video.recipe?.ingredients ?? []`. Under the progress capsules add an outlined cream capsule `"Ingredients · N"` (44 pt) that presents the list in a `.sheet` with `.presentationDetents([.medium])`; the step index survives. Under the step text show a `"For this step"` strip listing the ingredients whose name appears in the step text (case-insensitive containment on the ingredient string stripped of leading quantities); hide the strip when nothing matches. `// ponytail: substring match, swap for the recipe model's own step↔ingredient links if it grows them.` Give the matcher a `selfTest()`.
- [ ] **Step 4: An ending.** On the last step the button sets `finished = true` instead of dismissing: show a full-cover frame on `categoryRecipe` — check disc, `"Cooked."` (52 pt black), `"\(title) · \(steps.count) steps"`, `Micro("Marked as cooked · today")`, and a cream `"Back to the recipe"` button that dismisses; `.sensoryFeedback(.success, trigger: finished)`; write `CookedLog` for `videoID`. `RecipeDetailView` shows `Micro("Cooked \(date)")` under the title when logged.
- [ ] **Step 5:** Run the build check. Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 6:** Commit: `feat(films,cook): a primary action for films, ingredients and an ending for cook mode`

---

### Task 9: Haul — fewer, truer controls (F8 F9 F21 F18)

**Files:** Modify `App/Sources/HaulView.swift`, `App/Sources/HaulDetailView.swift`. Visual design unchanged.

- [ ] **Step 1:** Filter sheet (~217–245): delete the Category section — the chip row already sets `category`.
- [ ] **Step 2:** `chip("More", selected: …)` (~172) reads `filtering` (~97–99), not `status != .all`.
- [ ] **Step 3:** Sort glyph (~209): `arrow.up.arrow.down` instead of the fixed `arrow.down`.
- [ ] **Step 4:** Detail: delete the second "Open the link from the video" (~456); it stays in the ellipsis menu (~84).
- [ ] **Step 5:** Detail primary (~275–288): with more than one offer the button reads `"Buy the cheapest — \(price)"` and points at the cheapest offer; with one offer it keeps `"View at \(merchant)"`.
- [ ] **Step 6:** Detail spacing: three groups (product / shopping state / where to buy) separated by `StashSpacing.group`; gaps inside a group 4–6 pt. Touch only the `.padding(.top, …)` values listed in the spec under F7/F18.
- [ ] **Step 7:** Run the build check. Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 8:** Commit: `fix(haul): one place per filter, a primary that is not a duplicate, grouped spacing`

---

### Task 10: Small fixes (F6 F11 F17 F18 F35)

**Files:** Modify `App/Sources/PaywallView.swift`, `SignInView.swift`, `MindMapView.swift`, `LatelyView.swift`, `VideoDetailView.swift`

- [ ] **Step 1: Paywall** (~170–215): "Restore purchases", "Sign out", "Delete account" get `.minTapTarget()` and ink opacity 0.62.
- [ ] **Step 2: Sign-in** (~59–149): move `inviteField` to sit directly above the Apple button; fold the `InfoChip` sentence into `cloudNote` so two text blocks remain, not three; `.accessibilityHidden(true)` on the category dots.
- [ ] **Step 3: Mind map:** add a `"Fit"` capsule beside `StashHeader` (~32) calling `rebuild()`, `.minTapTarget()`.
- [ ] **Step 4: Lately** (~135): card stack `spacing: StashSpacing.group`.
- [ ] **Step 5: Video detail:** "Re-run pipeline" (~458–466) moves into an ellipsis `Menu` in the top bar as `"Analyse again"`; `sectionHeader` top padding 20 → 34 (~117).
- [ ] **Step 6:** Run the build check. Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 7:** Commit: `fix(ui): reachable paywall links, tidier sign-in, map re-fit, clearer detail`

---

### Task 11: Integration check (orchestrator)

- [ ] Merge every task branch into `feat/ux-laws-rework`; register `PipelineCenter.shellStatusSelfTest()`, `SearchSuggestions.selfTest()` and the Cook matcher's self-test beside the asserts at `TikTokBrainApp.swift:42–46`.
- [ ] Build check and Kit check, both green.
- [ ] Headless simulator pass (memory `simulator-headless-launch-recipe`): `-seedSample` on the spare iPhone 17 Pro Max; screenshot Lately, Library, Import, the guide, Search (empty and with a query), Music, Haul, a film page, Cook Mode and its ending; compare each with its mockup; shut the simulator down.
- [ ] Report: what matches, what differs, what could not be checked without a device (TikTok deep link, real notifications, a real zip from TikTok).

## Known trade-offs

- At 7 slots the bar's search button leaves each slot about 43 pt on a 393 pt phone (40 pt on 375 pt). The default is 5; "Reset to recommended" is one tap.
- The TikTok settings link is a best-effort universal link; it must be tried on a device.
- Zip support has no zip64. TikTok exports are far below that ceiling.

---

## Execution record (2026-09-21)

All ten tasks were implemented by Opus subagents in separate worktrees, each task-reviewed, then one whole-branch review and one fix wave. Branch `feat/ux-laws-rework`, 24 commits ahead of `main`, nothing pushed.

### Verification

- `cd TikTokBrainKit && swift test`: 200 XCTest + 99 Swift Testing, 0 failures (on 3e2f28a).
- `xcodebuild … build`: BUILD SUCCEEDED (on 3e2f28a).
- Headless simulator (iPhone 17 Pro Max, `-seedSample`): the app launches, so all twelve registered debug self-tests pass. Seen on screen: five labelled tabs and the search button; the status pill, its route into Import and its dismissal; the new Import screen; Library’s labelled actions and "All N" links; Search opened by tap with own-topic chips; Music’s filter chips and sort menu; Cook Mode’s ingredients capsule, per-step quantities and the "Cooked." ending.
- After the fix wave: the pill reads "Could not check on your import…"; dismissed at 10:53, it was still gone at 13:32 with the same error recurring (the inline line on Import still shows it); the header Import button and the pill share one route.
- Not opened on the simulator: the export guide sheet, Haul, the Film page, Search with a query typed, Code, Sign-in, Paywall, Mind map.
- Needs a device: the TikTok settings link, real reminder notifications, a real TikTok zip (including a multi-GB "All data" export).

### Rulings made during execution

- run implementers in parallel waves of 3, each in its own git worktree with exclusive file ownership — the user asked for Opus subagents and the plan's file table makes conflicts impossible — if wrong, a merge conflict costs one manual merge.
- one task review per task (spec + quality) stays; final whole-branch review at the end — unchanged from the skill.
- F39 (Lately emptiness on the sample library) has no task — it is sample-data specific — if wrong, one follow-up card design.
- T3 must skip AppleDouble members (`__MACOSX/`, basename starting `._`) — a Mac re-zipped export would otherwise fail the whole parse — costs one fix round; if wrong, one line to delete.
- keep requestAuthorization inside scheduleExportReminders — a reminder scheduled without permission is silently dropped, and asking at "I've requested it" is in context — costs an earlier permission prompt; if wrong, delete one call.
- T6 Step 6 — the spec's F32 ("no false 'No saves matched'") beats the brief's literal 3-clause condition: show the negative only when `!isSettling`, with a bounded wait so a hung embed cannot hide the verdict forever — costs one fix round; if wrong, revert one condition.
- promote T4 minor "pill tap while search is open routes behind the overlay" to the fix round — it is a broken interaction, one line (`searchOpen = false`) — if wrong, nothing lost.
- cross-task gaps found by reviewers go to the PipelineCenter owner (T2 implementer) as T2 fix round 2: (a) `dismissShellStatus()` must also drop `.failed` pending shares or the pill's ✕ is inert; (b) `runCloudImport`/`runLocalImport` must route every picked URL through `parser.parse(zipAt:)` or a picked .zip still fails — both are load-bearing for T4/T5.
- glyph rule on Import option rows — the paste row acts in place and gets NO trailing glyph; the guide row presents a screen and keeps `chevron.right` — if wrong, two glyphs to change.
- guide callout text on amber uses a fixed dark ink `Color(light: 0x201A12, dark: 0x1D0E06)` — `stashInk` flips to cream in dark mode (~2.5:1) — deviates from the brief's "ink text" to keep contrast.
- T5 fix round 1 carries four controller rulings — callout fixed dark ink; paste row no trailing glyph; zero-budget badge regains its warning treatment (promoted minor 7); paste success notice (promoted minor 5) — each is a one-to-three line change.
- zero-budget badge inverts (cream fill, fixed dark ink, hourglass) instead of amber-on-green (~1.8:1) — a design call made for contrast; if wrong, one style to change. Plural "1 video left".
- the Global Constraint "Haul keeps its approved visual design" beats plan Step 6 — REVERT the whole Haul-detail spacing pass to BASE values (F18 is dropped for Haul) — costs the proximity fix on that one screen; if wrong, re-run Step 6 with StashSpacing.item.
- T9 Step 2 reverts to `status != .all` — with the Category section gone the sheet only holds the shortlist, so the original condition is now the truthful one (the audit's F8 sub-point is satisfied by Step 1).
- T9 Step 5 — the button says "Buy the cheapest — price" only when the cheapest offer is NOT offers.first; otherwise it stays "View at merchant" exactly as approved. F21's duplicate remains in that case, because removing it would redraw the approved screen.
- T9 Step 3 stays (`arrow.up.arrow.down`) — a glyph that lies about sort direction is a logic bug; one-glyph departure from the mock ("Recent ↓") — flagged to the user.
- T9 cheapest requires a non-empty shared currency (promoted minor F5).
- ratify T7's placement of the sort menu at the trailing end of the chip row — Music's wall has no section header to hang it on — if wrong, move one view.
- promote the matcher's inside-word hits to the fix round — showing "oil" under "bring to the boil" is wrong output, not polish.
- ONE fix dispatch takes C1 I1 I2 I3 I4 I5 I6 M1 M3 plus simulator finding S1 (dismissed error re-fires every poll). M2 deferred — a stray unparseable JSON inside TikTok's own export is unlikely; if wrong, skip-bad-members is a 5-line follow-up.
- I4(b) observed on the simulator — pill tap from Lately switched to Library and pushed Import once, back returned to Library, second tap worked — so the flag is written back on pop; (a) still fixed structurally via the single route.

### Deferred minors (not fixed)

- Task 1: — Theme.swift:100 duplicate doc comment above minTapTarget
- Task 3: — M1 merge-loop duplication in ExportParser; M2 no test for magic-bytes path; M3 no tests for truncated/unsupported-method/encrypted/zip64; M4 Int-relative Data subscripting in ZipReader; M5 no CRC-32 check
- Task 2: — max(0,…) clamp on finished count (kept, mirrors notifyLibraryReady); zip() over parallel literals for reminder IDs; schedule/cancel race during auth round-trip; dismissShellStatus writes nil when cloudStatus is nil
- Task 3: — 256 MB cap reports as corrupt, not "too large"
- Task 5: — category tiles vanish 24 h after an import (brief-mandated; design confirmation owed to the user); force-local DEBUG build never shows the tiles; dismissing an unrelated error also silences the "N videos sorted" pill (dismissShellStatus semantics, PipelineCenter); sharedVideoCost = 3 is a client-only constant; guide link label uppercased
- Task 4: — 0.2 s choose() debounce also drops fast double taps; "Try again" on splash is wrong for a stalled Keychain restore; redundant accessibilityAction("Search"); missing ponytail notes on the debounce
- Task 6: — 6 s embed deadline is an unstructured Task (harmless); recordSearch drops multi-line queries; VoiceOver phrasing on the Needs-a-look header; elective opacity bumps
- Task 5: — paste success notice renders in the amber warning tone
- Task 10: — PaywallView renewalTerms 11 pt at ink 0.5 (under the 0.62 floor); SignInView "Have a code?" is a ~13 pt target; Menu budget-note row styling unverified; hand-rolled Fit capsule
- Task 9: — a11y idiom on the primary button; pre-existing Swift 6 'explicit self' warnings at HaulDetailView.swift:778
- Task 7: — F4 invariant written twice (chips + offered); trailing(...) not self-tested; `meta` shadowing in CodeView; tracklist number 11 pt at 0.45 ink; 9 pt link glyph; music pick arrow shows before the service chooser; focus not written back
- Final: — lastSummary "Synced N cloud results" (PipelineCenter ~:1361) same register as the banned jargon; ZipReader ceiling comment understates the mapped archive; runLocalImport never shows .reading (debug-only path)
