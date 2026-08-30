# Recents — Interest Mining and the Today Redesign

**Date:** 2026-08-30
**Status:** Analysis complete; layout direction pending pick
**Dataset:** the real 855-save library (`pipeline-lab/full/seed.json`), saves 2023-08-15 → 2026-07-10

## Why Today is being replaced

`TodayView` (App/Sources/TodayView.swift:36) is a day-of-year rotation over the whole
library — a placeholder, per its own comment. The 2026-07-11 spec framed Today as
*rediscovery* ("Worth returning to"). This redesign reframes the first surface as
*recent-saves exploration*: what did I just save, and what am I currently into. The
window is deliberately not literal "today" — the data below shows why.

## The mining process (repeatable, per-user)

Run in order; every step is a pure function of the library. This is the pipeline a
future "personalized layout" feature would run on any user's data. Reference
implementation: `mine_interests.py` (session scratchpad; port to Kit when built).

### 1. Cadence profile

Group saves by calendar day. Compute active days, saves per active day, gap
percentiles between active days.

*This library:* 449 active days over 1060; 1.9 saves per active day; median gap
between active days 1 d, p90 5 d, max 32 d. Saving is streaky: quiet weeks, then bursts
(92 days with 3+ saves, 3 days with 10+).

### 2. Window sizing — count beats time

For trailing windows of 1/3/7/14/30 d, count items; probe at many anchor dates, not
just "now", because cadence drifts.

*This library, anchored at the last save:* 1 d → 4 items, 3 d → 5, 7 d → 5, 14 d → 11,
30 d → 24. But probed at 2026-01-01: 7 d → 1, 30 d → 6. **A fixed time window is
either empty or overflowing depending on the month.** Median days to accumulate K
items across probes: 3 items ≈ 4 d, 8 ≈ 14 d, 12 ≈ 16 d.

**Rule adopted: Recents = the last N saves (N≈8–12), clamped to ≥3 days and ≤30 days,
labeled honestly ("since Jun 28"), never labeled "Today".**

### 3. Session and binge detection

Session = saves separated by <4 h. A session of 3+ is *thematic* when its modal topic
covers ≥ half the items.

*This library:* 553 sessions, 70 of size 3+, **44% of those thematic** — e.g.
2025-01-09 "ai agents" ×3, 2024-09-26 "linux" ×4, 2024-01-20 "cooking" ×6. Binges are
real, nameable objects; a layout can present "Tuesday — 5 saves about ai agents" as a
first-class row.

### 4. Interest trend (rising / fading)

For each topic with ≥5 uses: ratio of its share in the trailing 180 d vs all-time.
Rising ≥1.6, fading ≤0.4.

*This library:* rising — claude code (6.5×), anthropic (6.5×), github, frontend,
opensource (5.4×), ui design, web design (5.2×). Fading — amsterdam, comfort food,
easy recipe, streetwear (→0). Category halves confirm the pivot: coding 53 → 115,
recipe 137 → 96. **Interests move; the surface should say so.**

### 5. Interest clusters

Co-occurrence graph over topics (edge when two topics share a video; keep edges ≥4),
greedy union over the top-60 topics.

*This library:* ① productivity/ai/automation/tech/lifestyle (~422 videos, the
mega-cluster — includes travel/interior via lifestyle bridges), ② cooking
(~301: chicken, pasta, meal prep, high protein), ③ music/lyrics (58),
④ cinema/movies (55), ⑤ fashion/streetwear (32). Clusters give stable shelf names
where raw topics (1,317 distinct, mean 3.6/save) are too granular.

### 6. Author affinity — measured, rejected

699 distinct authors, only 95 appear twice, max 6. Too weak to drive layout; dropped.

### Signals inventory (what each field is good for)

| Signal | Fill | Use |
|---|---|---|
| `bookmarkedAt` | 100% | windows, sessions, trends |
| `topics` (2–4/save) | 100% | themes, clusters, trends |
| `category` | 100% | tint, shelf fallback |
| `title`/`summary` | 100% | display |
| `transcript` | 68% | search only, too noisy for grouping |
| `ocrText` | **0%** | on-device Vision stage never ran on this library; design must not depend on it |
| open/view history | none | doesn't exist yet — biggest missing signal; log `lastViewedAt` first (already in the 07-11 spec) |

## Generalization: interest-driven layout selection

The same six steps yield a per-user profile: `{cadence, windowN→days, binge rate,
rising[], fading[], clusters[]}`. Layout rules a future feature can apply:

- **Sparse cadence** (median gap >7 d) → digest layout; a "today" surface would embarrass an empty state.
- **High binge share** (>30% of multi-sessions thematic) → thread/binge rows earn their place.
- **Strong trend skew** (any topic ≥4× rising) → rising-interest hero.
- **Flat profile** (none of the above) → calm N-pick with explanations, the safe default.

This library scores: dense-but-streaky cadence, high binge share, strong trend skew —
which is why the shortlisted layouts lean on threads and rising interests.

## Constraints carried over from the 07-11 spec

Finite (no endless scroll), no autoplay, no streaks or engagement pressure, every item
carries a one-line "why shown". Those survive the reframing from rediscovery to
recents; a small "resurface" slot (1 old unopened save) keeps the rediscovery promise
without owning the screen.

## Deliverable

Ten layout mockups rendered in the Stash design language (cream `#F3ECDB`, ink
`#201A12`, Archivo, jewel category tints, 18 pt cards) — published as the
"Stash Recents Layouts" artifact, 2026-08-30. Pick one (or a hybrid) to spec next.
