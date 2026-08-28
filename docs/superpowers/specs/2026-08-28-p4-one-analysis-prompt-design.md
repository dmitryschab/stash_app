# P4 — One analysis prompt, not two drifted ones

## Problem

Two shipping system prompts have drifted apart:

- Server fast pass: `ANALYSIS_SYSTEM_PROMPT`, `services/webhook/api_v1.py:270-303` — has the photo-post / album-sleeve / "Sound is the backing track" rules.
- On-device deep pass: `AnalyzerClient.systemPrompt`, `TikTokBrainKit/Sources/TikTokBrainKit/BoxClients.swift:168-208` — has metric-units-for-recipes, "list EVERY distinct release", "never collapse a list into its theme/genre", "NEVER invent an artist".

A video re-analyzed by the deep pass gets different instructions than the fast pass that produced it.

## Decision

The server is the single source of truth. The `/v1/chat/completions` proxy
(`api_v1.py:392-424`) **replaces** the incoming system message with the canonical
prompt whenever the request's first message has `role == "system"`. The endpoint
has exactly one caller (AnalyzerClient), so this is safe; note it in a comment.

## Changes

1. `api_v1.py`: merge the union of both prompts into `ANALYSIS_SYSTEM_PROMPT`:
   keep all existing server rules AND add the client-only rules (metric units;
   every distinct release is its own entry; descriptions like "jungle selection"
   are never titles; never invent an artist). One prompt, no contradictions —
   read both carefully and resolve overlaps by keeping the stricter wording.
2. `api_v1.py`: the vision path (`api_v1.py:320-330` photo addendum) must build
   from the same base constant + a photo-specific addendum — no second full copy.
3. `api_v1.py` proxy: substitute the system message content with
   `ANALYSIS_SYSTEM_PROMPT` before forwarding (after the existing allowlist rebuild).
4. `BoxClients.swift`: shrink `AnalyzerClient.systemPrompt` to a one-line
   placeholder (e.g. `"analyze"`) with a comment saying the box injects the real
   prompt. Keep the fence-stripper and `response_format` behavior untouched.
5. Update any tests that assert on the old client prompt
   (`TikTokBrainKit/Tests/TikTokBrainKitTests/BoxClientsTests.swift`) and add a
   server test: proxy rewrites the system message (`test_api_v1.py`).

## Non-goals

- No taxonomy changes, no `analysisRevision` bump (P3 does that).
- No change to temperature, token caps, or the pinned model.

## Verification

```
cd /Users/dmitryschab/Documents/projects/stash_app/services/webhook && python3 -m pytest -q
cd /Users/dmitryschab/Documents/projects/stash_app/TikTokBrainKit && swift test
```

Both must pass. No git commits.
