# Search by what the video is about

Date: 2026-10-19 · Status: draft for owner approval
Replaces the ranking in `App/Sources/SearchView.swift` (`SearchIndex.score`, the result row) and
`SearchBlend` in `TikTokBrainKit/Sources/TikTokBrainKit/BoxEmbeddingClient.swift`.

## Why

The owner's words: search "is very lucky" — whether the right save comes up feels like chance.
The percentage badge on each result was fine for a technical preview but means nothing to an
end user. Search should be **based on the summary of what the video says, not on its tags or
its name**.

What the code does today, and why it reads as luck:

- A save is scored by substring hits across six fields: title ×2, topics ×1.5, caption,
  summary, transcript and on-screen text ×1 (`SearchView.swift:391-434`). The title and the
  hashtags — the two things the owner wants out — carry the most weight.
- `contains` is a substring test, so "art" hits "party" and "start"; "how" and "to" count as
  hits on almost every save.
- The lexical score saturates at 1.0 (`min(1, raw / (tokens × 2))`), so many saves tie.
- The list is drawn from word hits first, then re-scored ~0.4 s + one round trip later when the
  query's embedding lands (`SearchView.swift:116-120`), so rows jump.
- Saves without an embedding keep a lexical-only score and are sorted against blended scores
  on a different scale.
- Today's `summary` is written from caption + transcript + on-screen text mixed
  (`services/webhook/api_v1.py` `ANALYSIS_SYSTEM_PROMPT`), so even it is partly the caption.

The owner's own library (`pipeline-lab/full/seed.full.bak.json`, 855 saves): 590 have a
transcript, 265 have none.

## What search does (agreed with the owner in chat)

1. **One "about" text per save, and search matches only against it.** Built in this order
   (Claude's proposal; the owner asked for one and accepted it):
   - someone talks → a summary of **what is said**;
   - nobody talks → a description of **what is shown**: on-screen text plus the frames the
     analysis already sees;
   - neither → the caption with hashtags stripped, as a last resort.
   - **music saves are the exception (owner's call): lyrics are never read.** Their
     about-text gives the genre — "maybe only genre" — plus what is shown when nobody sings
     or talks over it. No song or artist names, so a band's name finds nothing unless it is
     said in a non-music save.
2. **Title, topics and hashtags no longer affect ranking.** They still show on the result row
   and everywhere else in the app.
3. **Every matching save is listed**, not just the best few ("every pasta save, yes"). A save
   is in if its about-text contains a query word or is close to the query in meaning.
4. **Most clearly about the query comes first; equally close saves go newest first** (Claude's
   call, approved).
5. **A word matches only as a whole word or its plural; words like "how", "to", "the" are
   ignored** (Claude's call, approved).
6. **The list does not reorder after it first appears** (Claude's call, approved).
7. **No percentage anywhere.**

## Goals

- The right save is reliably near the top for a query that describes what the video says or
  shows, in the owner's own words.
- A save that is about the query is never missing from the list.
- The results screen is simpler: no score, no "matched: field" line.

## Non-goals

- Filters, facets, sort controls, search history changes, suggestion chips changes.
- Search across other users' saves; a server-side search index.
- Changing what `summary`, `title` or `topics` contain or where they are shown elsewhere.

## Anti-goals (would make this a failure even if it technically works)

- A save that shows up only because its title, caption or a hashtag contains the word.
- Rows visibly jumping or re-sorting after the list appears.
- Any number, percent or "confidence" visible to the user.
- Search that stops answering offline or when the box is down. Today it falls back to word
  matching; it must still answer by words against the about-text.

## How it is built

### The about-text

Facts this rests on: the analyzer the app calls is text-only (caption, hashtags, transcript,
on-screen text — `BoxClients.swift:178-191`); the deep pass's 12 keyframes are used only for
on-device OCR and Shazam and are deleted afterwards (`PipelineCenter.swift:1117-1141`); the
one image every save keeps is its 640 px cover (`ThumbnailStore.swift`). The transcript route
already returns null for speech under 5 words (`api_v1.py:183,256`).

- **Storage:** new optional `Video.about: String?` and `aboutRevision: Int` (default 0),
  lightweight migration like `embedding`. `summary` keeps its meaning for every other screen.
- **Writer:** a new server route `POST /v1/about`, mounted like `embeddings_api.py`, same JWT
  + entitlement check, **no monthly quota charge**, counted against the existing daily
  deep-pass cap. Batched (size is the builder's).
- **Inputs per save:** transcript, on-screen text, caption with hashtags stripped, and — only
  when there is no transcript — the cover thumbnail from `ThumbnailStore`.
- **The rule the prompt enforces** (2–4 sentences, English, concrete nouns — dishes, places,
  products, people, techniques):
  - transcript present → summarize what is said;
  - else → describe what is shown, from the cover image and on-screen text; the caption may
    only name things that are visibly there;
  - else → the caption with hashtags stripped, lightly cleaned.
  Never mention hashtags, the creator's handle, or "this video".
- **Music saves** (analysis `category == "music"`): the transcript is not sent. The genre comes
  from Shazam's genres when the deep pass stored them, else the model infers it from the
  identified track/artist or the caption; the names themselves are not written into the
  about-text. A music save with no transcript gets the cover call like any silent save.
- **When it is written (Claude's call):** a first about-text is written as soon as a save is
  analyzed, **text-only** (Gemma) from whatever exists then. The cover-image call happens only
  after the library pass has tried for a transcript and got none; a speech save is rewritten
  text-only when its transcript lands. So the vision model is paid at most once per save, and a
  just-imported save is searchable by meaning straight away. The builder finds or adds the
  "transcript was attempted" signal.
- **Photo posts (Claude's call):** no cover call. Their existing `summary` was written by the
  vision model from every slide (`api_v1.py:506-514`), so it is the "what is shown" input,
  text-only, together with the hashtag-stripped caption.
- **Model:** Gemma on Bedrock for text-only saves. For the cover image, Gemma if it describes a
  scene acceptably on ~10 silent saves from the test library (it is documented as unable to
  name album art, `api_v1.py:115`), else `google/gemini-3.7-flash` via OpenRouter, the
  photo-post model.
- **Cost:** about $0.0001 per speech save (Gemma, ~300 tokens in / ~100 out). About
  $0.0005–0.001 per silent save with Gemini Flash and one image — the builder measures it. A
  500-save account with a third silent lands near $0.05 on Gemma, near $0.20 on Gemini Flash.
  If Gemini is needed and the measurement exceeds the ~$0.20 per-account ceiling, stop and
  bring it to the owner.
- **Drain:** shaped like the embedding drain (`PipelineCenter.swift:449-475`, filter near
  1841): runs on foreground and whenever an analysis lands, picks saves with
  `aboutRevision < AboutClient.revision`, same gating style. `applyAnalysis`
  (`Pipeline.swift:619`) and the cloud upsert (`CloudImport.swift:556`) reset `aboutRevision`
  to 0, so a save whose transcript or on-screen text arrives later gets rewritten. No change to
  `ANALYSIS_SYSTEM_PROMPT`.
- **Embedding:** `Video.embeddingText` becomes the about-text alone once it exists (the
  current mixed text until then). Writing an about-text resets `embeddingRevision`, so the
  embedding drain re-embeds that save; bump `BoxEmbeddingClient.revision` to 2.
- **Not used:** deep-pass keyframes. If the scorecard's no-speech queries show the cover is
  too thin, the upgrade is sending 3–4 keyframes to the vision model during the deep pass,
  before they are deleted — a later change, not this one.

### Ranking

- **In or out:** a save is in when the about-text contains a non-stop-word query token as a
  whole word or its plural, **or** `cosine(query, about-embedding) ≥ meaningFloor`.
  `meaningFloor` (0.35 today) was measured on the old mixed embedding text and must be
  re-measured on about-text embeddings (see Scorecard).
- **Order:** by closeness in meaning; a whole-word hit adds a fixed boost so a save that says
  the word sits above one that only means it at the same closeness. Ties within a small band
  go newest first. Recency is a tie-breaker only, no longer a weighted term. The exact boost
  and band are the builder's to tune against the scorecard.
- **Offline / no query embedding:** whole-word hits on the about-text only, newest first.
- **A save with no about-text yet** (backfill not reached it): matched by whole words on its
  current summary + transcript, ranked after saves that have an about-text at the same word
  hit count. It never gets title/topic/caption scoring.
- **No reorder:** a list is drawn only once its ranking is final. While the next query is
  being typed and embedded, the previous final list stays on screen (Claude's call) with
  "Searching…" above it; a first query shows just "Searching…". If the embedding does not come
  back by a deadline (6 s today; the builder may shorten it), the word-only answer is shown and
  is final for that query.

### Results screen (`SearchView.swift` `resultRow`)

- Remove the percent capsule and the "matched: …" line.
- Row = thumbnail + title + one line of the about-text (truncated), so the owner can see why
  the save is there. (Claude's call.)
- One waiting label, "Searching…"; "Also checking by meaning…" goes away because the list no
  longer appears before the meaning half lands.
- The "Meaning, not just keywords" tagline and the empty-library copy ("indexes every caption,
  transcript and on-screen word") are rewritten to match: search reads what the video says and
  shows. Exact wording is the builder's.

### Scorecard (how we know it is better, not luckier)

- About 20 queries written in the owner's own phrasing against
  `pipeline-lab/full/seed.full.bak.json`, each with the saves that must appear and the one or
  two that should be in the top 3. Claude drafts the queries and expectations from the
  library; the owner skims the list once before it is used as a gate.
- Mix: speech saves, no-speech saves (music, silent recipes, on-screen-text tips), queries that
  share no word with the right save, and queries whose word appears only in a title or hashtag
  of an unrelated save.
- Measured for old and new ranking: share of must-appear saves found, and how often the
  expected save is in the top 3. New must beat old on both; no must-appear save may be lost.
- Runs headless from a script (Python against the seed file + the box's `/v1/embeddings`), not
  through the app UI.
- Known gap (Claude's call to accept): the seed has no on-screen text and no Shazam results,
  which the phone library has. Silent saves in the seed therefore get only cover + caption — a
  harder case than production, so a model that passes here passes on the phone. If the owner
  exports a fresh library from the app (Settings → export), the scorecard runs on that
  instead.

## Constraints

- Per-account compute stays inside the existing cap (~$0.20 of compute per account); the
  backfill must not spend the user's monthly import quota.
- Server deploys are manual (`services/webhook/deploy.sh`).
- The app keeps working while the backfill is part-way through a library.

## Left to the builder

- Stop-word list and plural rule (English only is fine; the analysis always writes English).
- Boost size, tie band, embedding deadline.
- Truncation of the about-text line in the row.
- How the about-text is stored (new `Video` field vs reusing one) as long as `summary` keeps
  its current meaning for the other screens.
