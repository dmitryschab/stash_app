# Handoff: full-library analysis run + prompt tuning

Paste everything below this line into a fresh Claude Code session in `~/Documents/projects/tiktok-brain`.

---

## Mission

Run the Stash AI pipeline over my **entire TikTok favorites library (~944 videos)**, then iterate: inspect the outputs, find misclassifications and weak summaries, and fine-tune the analysis prompt and approach until the results are good. Load the final dataset into the Stash app on the simulator so I can browse it.

## Context — what already works (proven on a 43-video pilot)

Everything lives in `pipeline-lab/eval-43/` (this repo):

- **`analyze.py`** — the working pipeline script: reads `urls.txt` + `meta.tsv` + `transcripts/*.txt`, calls **Gemma 4 26B-A4B on Bedrock** (serverless, OpenAI-compatible), writes `seed.json`. Run it with the venv from the pilot or `pip install aws-bedrock-token-generator` in a fresh venv.
  - Endpoint: `https://bedrock-mantle.eu-central-1.api.aws/openai/v1/chat/completions`, model `google.gemma-4-26b-a4b`, auth via `aws_bedrock_token_generator.provide_token(region="eu-central-1")` using the default AWS creds (IAM user `terraform`, account 709097782876). Works with no extra setup.
- **`dl.sh` / `redl3.sh`** — yt-dlp download helpers. Gotcha: TikTok's default format is sometimes **video-only**; `redl3.sh` resolves the `-1` CDN variant which carries audio. Don't run yt-dlp metadata probes more than ~5-way parallel (rate limiting → silent failures; verify wav count == video count and retry stragglers serially).
- **Transcription: local `mlx_whisper`**, model `mlx-community/whisper-large-v3-turbo`, `--condition-on-previous-text False`. **Free.** Russian works great. MANDATORY post-filter (already validated): collapse consecutive duplicate lines → drop lines whose internal 3/4-grams repeat ≥2× → drop lines repeated >4× → if <12 words remain, transcript = null (music-only video). Without this, music-heavy TikToks produce hallucination loops ("The The The…", "양파"×40).
- **`seed.json`** — the pilot's 43 processed videos (reference output). **`transcripts/`** — 43 cleaned transcripts (reference quality bar).
- **App loading**: the app supports `-seedFile <path>` (added in `App/Sources/SampleData.swift`) — wipes the store and loads a JSON array. Build: `cd App && xcodegen generate && xcodebuild -project Stash.xcodeproj -scheme Stash -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`, then `xcrun simctl launch booted dev.dmitryschab.Stash -seedFile <abs path>`. Seed JSON schema per item: `{videoID, url, author, caption, transcript|null, category: recipe|music|coding|other, title, summary, topics[], recipe?{name,ingredients,steps}, track?{title,artist}, code?{summary,links,techTags}}`.

## Getting the full library list (step 1)

Two options, prefer (a):
a) **Ask me for my TikTok data export** (Settings → Download your data → JSON). `TikTokBrainKit`'s `ExportParser` format is `Activity → Favorite Videos → FavoriteVideoList[{Date, Link}]` — trivially convertible to `urls.txt`.
b) Scrape via Claude-in-Chrome like the pilot: tiktok.com/@dmitryschab → Favorites tab → **real wheel-scroll events** (programmatic `scrollBy` does NOT trigger TikTok's lazy loader; `computer.scroll` actions do) → collect `a[href*="/video/"]`, dedupe, skip `/photo/` posts. 944 items ≈ a lot of scrolling; chunk output (tool responses truncate ~1.2KB) via `window.__list` slices.

## Budget expectations (tell me before the model run, but this is pre-approved up to ~$1)

Pilot actuals: 43 videos = 22.7K in / 5.9K out tokens ≈ $0.01–0.02 on Gemma. Extrapolated 944 videos ≈ $0.25–0.50 worst case. Transcription is local/free but ~940 videos × avg 2.4 min ≈ 3-6 h of whisper wall-time on the M-series — parallelize 2–3 whisper processes, or checkpoint progress (script must be resumable: skip existing .txt/.mp4/analysis entries — the pilot scripts already do this).

## The iterative tuning loop (the actual goal)

1. Run pipeline on full library (resumable, checkpointed batches of ~100).
2. Audit pass: category distribution, % null transcripts, spot-check 10–15 random summaries against transcripts (subagents work well for parallel review), flag: misclassifications, vague summaries ("This video talks about…"), garbage topics, Russian summaries not in English, JSON parse failures.
3. Tune `analyze.py`'s PROMPT (it's inline, ~15 lines) and re-run **only failed/flagged items** (cheap). Known weak spots from the pilot:
   - "coding" is over-broad — absorbs all AI/tech content (24/43). Consider splitting guidance or richer topic tags; category enum is fixed in the Kit (`recipe|music|coding|other`) so tuning = better topics + summaries within those buckets.
   - Videos with null transcript classify from caption alone — check they aren't dumped into "other".
   - Titles >60 chars truncate in the app's Today cards.
4. Reload app via `-seedFile`, screenshot Library/Today/Search per iteration, show me.
5. Converge: write the final prompt + filter rules into `pipeline-lab/PROMPT.md` as the spec for the production `AnalyzerClient` port.

## Style notes

- I approve costs before model runs (one estimate per run is enough).
- Ponytail mode: shortest working solution, no over-engineering.
- Validate everything with real output before claiming done.
