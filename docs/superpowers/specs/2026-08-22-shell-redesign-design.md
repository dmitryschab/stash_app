# Shell redesign: Code tab, search in the grip

**Date:** 2026-08-22
**Status:** design approved in chat; not started
**Mockups:** https://claude.ai/code/artifact/23e30c40-c79a-4590-8f46-4dd469e71f2f

## The problem

The pill has five slots — Today / Library / Cook / Music / Search — and the one section the
owner uses most, coding saves, has no slot at all: it is a "Tech" shelf inside Library, a list
of rows that hides the one thing a coding save is good for (the links and the tech tags the
pipeline already extracted into `CodeData`). Meanwhile Search takes a whole slot for a screen
that is one text field.

## What ships

- **D1 — Today stays first.** Unchanged: three picks, no feed.
- **D2 — Code becomes a tab.** Today · Code · Cook · Music · Library, in that order. Library
  drops its Tech shelf the way it dropped Recipes and Music.
- **D3 — Search leaves the bar.** Hold the pill ~350 ms, push right, and the pill itself
  becomes the search field. Results sit on an overlay above it, the keyboard below. Release
  early and it snaps back. The pill *is* the field — there is no Search screen any more.

Out of scope: the Library "Today rail" (dropped), a Mind map slot (stays in the Library
header), embedding search (the token scorer stays).

## The tab bar

`StashTab` becomes `today, code, cook, music, library` (`.search` removed). Code's symbol is
`chevron.left.forwardslash.chevron.right`, label "Code" — four letters like Cook, and it is
what the owner calls it; the category's `displayName` stays "Tech" for badges, which is the
only place it still shows. `-initialTab` accepts `code` and no longer accepts `search`;
`TabReselect`'s default tab stays `.today`. `libraryShelves` filters out `.coding`;
`-initialSegment coding` goes with it.

## The Code tab — `CodeView.swift`

Built on `CookView`'s bones, not its wall: coding saves are screencasts and talking heads,
so a thumbnail says nothing and rows with the tag and the link count say everything.

- **Data:** `videos.filter { $0.category == .coding }`, newest first (the `@Query` order).
  `needsLook` saves stay in Library's "Needs a look" pile, same as today.
- **Header:** `StashHeader(title: "Code", trailing:)` — "48 saves", or "12 of 48" with a
  filter on.
- **Chips:** the tech tags across the shelf, counted (`TopicCount`), drawn with `TopicChip`
  and `TopicPicker` exactly as Cook does — the five most-used plus "all" and "more". A chosen
  tag filters, it does not dim.
- **Featured card:** the newest save, on `categoryCoding` green, same shape as Library's
  "Latest save" card but the body line is `codeNote.summary` and the foot carries tag chips,
  so it reads like a changelog entry.
- **Rows:** month-sectioned `LazyVStack` with the `TimeRail`, like Cook. Each row: 36 pt
  thumbnail, title, a meta line of `tag · N links` in green micro type, and on the right the
  up-right arrow in green when the save has links, the plain chevron when it does not. The
  row opens `VideoDetailView`, which already renders the code note's summary, links and tags.
- **Empty state:** `StashEmptyState` with the code symbol — "Nothing in code yet".

## Search in the grip

### The gesture

On `StashTabBar`, alongside the slot buttons (`.simultaneousGesture`):

```
LongPressGesture(minimumDuration: 0.35)
    .sequenced(before: DragGesture(minimumDistance: 0))
```

- **Hold (350 ms):** one `.sensoryFeedback(.impact(weight: .medium))` tick. The pill lifts
  3 pt and scales to 1.03, the slots dim to 30 %, and the magnifier peeks in at the left edge
  (progress 0.1). A tap shorter than the hold is still a tap — the pill is also the
  reselect target, and that must not change.
- **Push right:** `progress = clamp(0.1 + dx / 140, 0, 1)` where `dx` is the drag's
  horizontal translation in points. The slot row slides right (`progress × 64 pt`) and fades
  (`1 − 2·progress`); the field slides in from the left (`(1 − progress) × −30 pt`) and fades
  in (`min(1, 4·progress)`), its placeholder a beat behind the magnifier. Leftward drag does
  nothing.
- **Release:** `dx ≥ 70 pt` commits (progress ≥ 0.6); under that it springs back over
  0.35 s with a slight overshoot. Both numbers are tunable; they are the first thing to feel
  on a device.

`SearchGrip` — a small value type holding `progress(for dx:)` and `commits(dx:)` — keeps the
math out of the view and gets a `selfTest()` asserted at launch in DEBUG, the way
`MindMapEngine` does. No gesture code in the Kit; it is all app shell.

### Open state

`RootView` owns `@State private var searchOpen`. When open:

- The pill stays where it is, full width of its slot, and renders as the field: magnifier,
  a focused `TextField` ("that bread video"), and an × at the right end. Same ink fill, same
  cream text — it never stops being the pill.
- A `SearchOverlay` covers the current tab: `stashBackground` at 96 % over the content,
  holding the results list, the "Try asking" chips, or the empty-library state — the bodies of
  today's `SearchView`, lifted out into `SearchResults` so nothing about matching changes.
  `SearchView` as a screen goes away.
- The keyboard pushes the bottom stack up; the pill rides with it (it already lives in the
  safe area).
- Close: the ×, or a swipe left on the field (`dx ≤ −60 pt`). Closing clears the query and
  returns to the tab you were on, scroll position untouched.

### Discoverability (R1)

Nobody finds hold-and-drag on their own. Three things, together:

1. A one-line `Micro` caption floats above the pill — "Hold the bar, push right to search" —
   until the first time search is opened (`@AppStorage("searchGripHintDone")`).
2. The magnifier peeks on every hold, so anyone who long-presses by accident learns the rest.
3. `.accessibilityAction(named: "Search")` on the bar opens search directly — VoiceOver and
   Switch Control users never need the gesture.

### Collisions (R2)

The long-press must not scroll the content behind the pill, and the drag must not read as a
horizontal swipe. The pill owns its hit area already; the open question is whether SwiftUI's
`Button` inside the bar swallows the long-press. If it does, the slots become plain views with
`onTapGesture` — the `TabReselect` wiring is unchanged either way. **Prototype this first**,
before any Code tab work: a bar that cannot be gripped makes D3 moot.

## Files

| File | Change |
|---|---|
| `App/Sources/TikTokBrainApp.swift` | `StashTab` (+code, −search), `RootView` search state + overlay, `StashTabBar` grip + field mode, `SearchGrip` |
| `App/Sources/CodeView.swift` | new — the Code tab |
| `App/Sources/SearchView.swift` | `SearchView` screen → `SearchResults` content view; scoring untouched |
| `App/Sources/Theme.swift` | `libraryShelves` drops `.coding` |
| `App/Sources/LibraryView.swift` | `-initialSegment coding` removed |
| `App/Sources/SampleData.swift` | coding samples already carry `CodeData`; verify at least one has links for the green arrow |

## Testing

- `SearchGrip.selfTest()` — progress and commit thresholds at 0, 69, 70, 140, −20 pt.
- Build + simulator smoke with `-initialTab code` (headless: simctl + idb, as the other
  sections are checked). Screenshot the Code tab with the demo library.
- Gesture on a device, by hand: tap still switches tabs, tap on the current tab still
  returns to top, hold + push opens, hold + release snaps back, × and swipe-left close.
- Dark mode pass on Code and the open search state — the pill inverts to cream in dark, and
  the field's text must follow `stashOnInk`.
