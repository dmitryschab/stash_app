# P3 — Split "other": taxonomy v6

Depends on: P4 (single canonical prompt in `services/webhook/api_v1.py`).

## Problem

The 941-favorite validated run left 39% (330/855) in `other`
(`pipeline-lab/PROMPT.md:71-87`). The enum has since gone 4→10
(`TikTokBrainKit/Sources/TikTokBrainKit/Core/Types.swift:31-40`) but no measured
redistribution exists; the residual is likely still the largest bucket.

## Steps

1. **Measure before choosing.** Mine the stored pipeline-lab artifacts
   (`pipeline-lab/full/` output JSON from the 941 run) — frequency-count the
   `topics` of videos with `category == "other"`. Plain counting, no ML, no paid
   API calls. If the artifacts are missing, say so in the report and derive
   candidates from whatever per-video analyses exist on disk; do not invent data.
2. **Choose 3–5 new categories** covering topic clusters with ≥3% share of the
   `other` pool. Total taxonomy stays ≤14. New categories carry NO structured
   payload (like fitness/style/travel today).
3. **Server**: add the new categories to the canonical prompt's category list
   with one-line definitions in the same voice as the existing ones.
4. **Kit**: extend `CategoryKind` in `Types.swift` (unknown-decodes-to-other
   behavior at `Types.swift:36-39` must keep passing).
5. **App**: new categories must show up wherever categories surface — check
   `App/Sources/LibraryView.swift` segments and any category → icon/label maps
   (search for exhaustive switches over `CategoryKind`).
6. **Revision bump**: `ANALYSIS_REVISION` → 6 in
   `services/webhook/cloud_import_models.py` with a changelog line in the
   documented style (`cloud_import_models.py:176-188`), and the matching client
   constant if one exists. The rev gate (`CloudImport.swift:413`) then lets a
   future re-import re-apply.

## Non-goals

- No re-run of the library through Bedrock (the rev gate makes that a later,
  cheap, user-triggered step).
- No new structured payloads.

## Verification

```
cd /Users/dmitryschab/Documents/projects/stash_app/services/webhook && python3 -m pytest -q
cd /Users/dmitryschab/Documents/projects/stash_app/TikTokBrainKit && swift test
```

Report must include the topic-frequency table and the chosen categories with
counts. No git commits.
