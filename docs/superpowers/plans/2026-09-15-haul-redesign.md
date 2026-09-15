# Haul Redesign Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development to implement the independent tasks below. The user approved the visual design and implementation in this conversation.

**Goal:** Implement the approved Haul overview and product detail with functional search, expansion, shopping, and persistent wishlist controls.

**Architecture:** Keep products attached to their source Video and reuse existing offer/frame services. Store optional per-product wishlist state on Video so library deletion and account switching remove it naturally. The app shell supplies a binding to hide its custom tab bar on the product detail.

**Tech Stack:** SwiftUI, SwiftData, existing TikTokBrainKit; iOS 17 minimum; no new dependencies.

**Spec:** [Approved two-screen mock](../../design/haul/approved-mock.png), approved in chat on 2026-09-15.

## Global Constraints

- Preserve cream #F3ECDB, surface #F7F1E1, ink #201A12, brown #7A4A22, and Archivo fonts.
- Use actual extracted frames or source covers; no sample prices or product imagery in production.
- Keep video provenance, country-specific store searches, offline offer cache, and source links.
- Preserve unrelated working-tree changes. No deployment or release is part of this task.

## Task 1: Persistent product state

- [x] Add `Video.haulStatesJSON: Data? = nil` and `HaulPickState` with `.want` and `.bought`; nil means unmarked.
- [x] Expose `video.haulState(for: pick)` and `video.setHaulState(state, for: pick)` keyed by normalized product name, independent of position, price, and links.
- [x] Test state transitions, reordering/price changes, separate videos, persistent reload and deletion using isolated SwiftData stores.
- [x] Verify all account-deletion paths remove the new state.

## Task 2: Haul overview and shared UI

- [x] Replace the featured-card/month-list structure in `App/Sources/HaulView.swift` with search, broad-category chips, sort menu, and source groups.
- [x] Show two product previews per multi-product source and a working expansion control; filtering keeps original product indices.
- [x] Add rich single-product rows, mentioned-price labels, Want/Bought filters, and recoverable no-results states.
- [x] Add `HaulProductArtwork(video:pickIndex:)`, `HaulCategory.category(for:)`, and the shell visibility binding in `HaulComponents.swift`.
- [x] Use actual images with a quiet fallback; preserve tab reselect and reduce-motion preferences.

## Task 3: Product detail

- [x] Rebuild `HaulDetailView.swift` to match the mock: artwork, title, Want/Bought controls, country selector, merchant comparison, real primary link, and compact video source.
- [x] Save wishlist mutations using ModelContext, reverting and showing an error if persistence fails.
- [x] Replace street-address entry with a searchable country selector while preserving existing country preferences.
- [x] Add explicit retry for missing offers; preserve cached offers during refresh and keep source/shop links usable.

## Task 4: Integration and verification

- [x] Generate the Xcode project and build the simulator app with signing disabled.
- [x] Run targeted Kit tests, then the existing Kit suite if the targeted tests pass.
- [x] Exercise search, filtering, group expansion, product navigation, wishlist persistence, country selection, and back navigation in the simulator.
- [x] Inspect normal, dark, and large-text layouts; save representative screenshots with the approved mock.
- [x] Review the final diff for regressions and document verification evidence here.

## Verification evidence (2026-09-15, iPhone 17 Pro, iOS 26.3)

- `xcodebuild … CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED** (`/tmp/stash-haul-build3.log`).
- `swift test --package-path TikTokBrainKit` → **157 tests, 0 failures**, including `HaulPickStateTests` (3).
- Screenshots in `docs/design/haul/verification/`: overview, product detail, search, large text
  (AX5), dark mode, group collapsed/expanded, country sheet.
- Interactions driven headlessly with `idb ui tap` against accessibility ids (`haul.search`,
  `haul.product.<videoID>#<index>`):
  - Search "levi" narrows four products to one and keeps its original index (`#1`).
  - `View all 5 products` expands a five-product save to all five and flips to `Show fewer products`.
  - Want on the detail survives terminate + relaunch (`Want | Selected`) and shows on the list row.
  - Shopping country opens the searchable country sheet; the tab bar hides on the detail.
  - Offers fail offline as designed: "Couldn't check prices right now" plus a `Try again` retry.
- Bug found and fixed during this pass: the detail's back and options buttons drew their circle
  as a `.background`, so only the glyph took touches and Back was effectively dead. Added
  `.contentShape(Circle())` (the pattern `StashBackButton` already uses) and re-verified the pop.
- Known, pre-existing: at AX5 text the shell's "HOLD THE BAR" caption and tab pill overlap the
  scrolling content on every tab, Haul included. Out of scope here.

## Execution notes

- Usage check returned no active block data; no percentage was available. Work is limited to two implementation agents plus the parent.
- Wishlist state is intentionally per video and normalized product name; indistinguishable same-named recommendations within one video share state.
- UI presentation changes are verified with builds and simulator interactions; behavioral persistence receives focused automated tests.
