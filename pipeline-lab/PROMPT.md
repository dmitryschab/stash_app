# Stash analysis pipeline — converged spec

Result of the full-library run (941 favorites → 855 analyzed). This is the spec for
the production `AnalyzerClient` port. Working reference implementation:
[`full/run.py`](full/run.py).

## Pipeline stages (all resumable — skip on existing artifact)

1. **Parse export** — `Likes and Favorites → Favorite Videos → FavoriteVideoList[{Date, Link}]`.
   Extract video id from the link (`/video/(\d+)`), dedupe, skip `/photo/` posts.
2. **meta** — `yt-dlp -j <share-link>` → `uploader`, `description` (caption), `duration`.
   Max 5-way parallel (>5 → silent TikTok rate-limiting). Retry stragglers serially.
   ~9% of an old favorites list is unavailable (deleted/private) — expected, skip them.
3. **download** — `yt-dlp -f bestaudio/best` → mp4, then `ffmpeg -ar 16000 -ac 1` → wav,
   delete the mp4. 3-way parallel is safe. `bestaudio/best` avoids TikTok's video-only
   default format (the pilot's `redl3.sh` -1 CDN fallback is no longer needed).
4. **transcribe** — `mlx_whisper` `mlx-community/whisper-large-v3-turbo`,
   `condition_on_previous_text=False`. Local/free. Shard N-way by `index % N` (no
   coordination, resumable). Apply the repetition filter below. ~28% come out null
   (music/no-speech) — that is correct, not a failure.
5. **analyze** — Gemma 4 26B-A4B on Bedrock (OpenAI-compatible), prompt below.
   Checkpoint seed.json every 25. Resumable via `videoID in seed`.
6. **thumbs** — download cover images. TikTok cover URLs are signed and **expire**
   (~hours–days), so store pixels, not URLs: `yt-dlp -j` → `thumbnail` URL → download
   `thumbs/<id>.jpg` immediately (~25–60 KB each). Production port: the enricher already
   has the cover URL at sync time — download it right then into app storage.
7. **finalize** — deterministic fixups the model won't do reliably (placeholder titles),
   plus real save dates from the export (`"date"`) and `"thumbnail"` relative paths.

## Transcript repetition filter (MANDATORY — kills Whisper hallucination loops)

Operate on whisper segment texts, in order:
1. Collapse consecutive duplicate lines.
2. Drop any line whose own 3- or 4-grams repeat ≥2× (internal loops, e.g. "The The The…").
3. Drop any line that appears >4× overall (choruses / non-consecutive loops).
4. If <12 words remain → transcript = **null** (music-only / no speech).

Without this, music-heavy TikToks produce loops ("After After After…", "still still still…").
Validated on real data: every null is a genuine no-speech video; every speech video survives.

## Analyzer prompt (Gemma, `max_tokens` 700, temperature default)

```
You are the analyzer for a TikTok bookmark organizer. Given a video's caption and
transcript, return ONLY a JSON object (no markdown fences) with:
- "category": one of "recipe", "music", "coding", "other"
- "title": short descriptive title (max 60 chars)
- "summary": 1-2 sentence summary
- "topics": 2-4 lowercase topic tags
- if recipe: "recipe": {"name": str, "ingredients": [str], "steps": [str]}
- if music: "track": {"title": str, "artist": str}
- if coding/tech/AI-tools: "code": {"summary": str, "links": [], "techTags": [str]}
Rules:
- Classify from caption hashtags even when the transcript is empty: #linux #arch
  #archlinux #selfhosted #homelab #docker #python #react #vim → "coding"; cooking/
  baking/food → "recipe"; a song/lyrics/album → "music".
- Music: if the video is an album/artist RECOMMENDATION LIST (not one song), set
  track.title to the list's theme and track.artist to the main artist(s), or "" if
  several. If it is one song, identify title+artist from well-known lyrics — but
  NEVER invent an artist you are not confident about; use "" instead of guessing.
- NEVER output placeholder text like "No Content Provided"/"Untitled Video" as the
  title or summary. If caption and transcript are both empty, title="Saved video"
  and summary="No caption or audio was available for this save."
Transcripts may be in English or Russian; always answer in English.
CAPTION: %s
TRANSCRIPT: %s
```

Prompt input: `caption[:300]`, `transcript[:6000]` (or `"(no speech)"` if null).

## Results (final)

- 855 analyzed. Categories: **other 330 (39%), recipe 233 (27%), coding 168 (20%),
  music 124 (15%)**. Transcripts on 67%, null 33%.
- Payload completeness: recipe 233/233, coding 168/168, music track on all — near-perfect.
- Mechanical audit: 0 over-long titles, 0 empty topics/titles/summaries, 0 non-English,
  0 missing payloads, 3 false-positive "vague" flags. **~0 real defects / 855.**
- Model cost: full pass $0.443 + tuning re-run of 101 items $0.045 = **$0.49 total.**

## Known ceilings (not worth more model spend)

- `# ceiling:` ~71 music videos have `artist=""` — genuinely artist-less (ASMR, lyric
  snippets, multi-artist album lists). Upgrade path: a real music-ID service (ACRCloud/
  Shazam) on the audio, not the LLM.
- `# ceiling:` "other" is 39% and legitimately diverse (travel, products, movies). The
  fixed 4-category enum can't subdivide it; richer `topics` are the lever, not category.
