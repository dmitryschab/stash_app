# Brief: instant library map at first import, using Clef

Handed off on 2026-10-07 from the session "TikTok API response review". Start with the brainstorming
skill: this is architectural, so the owner approves a written spec before any code.

## The idea (owner's words, tidied)

1. As soon as someone signs in and their bookmarks are known, classify every saved TikTok by type
   (coding, cooking, music, …) straight away with the Clef decision model.
2. Show the distribution immediately, and place empty placeholder ("skeleton") tiles in each
   category, so the library has its shape before the full analysis finishes.
3. After the first import, show the biggest categories and pop up a picker: which types does the
   person want to focus on? The chosen ones appear in the menu.
4. Category-specific loading animations (a coding one, a cooking one, …) while items fill in.

## Facts already established (verify anything that matters before relying on it)

- **Clef** is Cloudflare's open-weight decision model family, released 2026-10-01: `cloudflare/clef`
  (27B) and `cloudflare/clef-flash` (9B). It answers bounded questions (yes/no, multiple choice,
  rankings) with a probability per option in one forward pass, so multiple-choice classification fits.
  It does not generate text.
  - OpenRouter **Decisions API**, not chat completions; an OpenAI SDK won't work. Price: clef-flash
    $0.09 / M input tokens, clef $0.24 / M, output free, 65,536-token context. OpenRouter lists
    text and image input; video input is claimed by the model card but not confirmed on OpenRouter.
    Workers AI truncates text state to about 2K tokens.
  - Docs: https://openrouter.ai/cloudflare/clef-flash · https://huggingface.co/Cloudflare/clef ·
    https://developers.cloudflare.com/workers-ai/models/clef/ · https://github.com/haginot/clef-quickstart
  - Rough cost: 1,000 bookmarks × ~1.5K tokens (cover + caption) ≈ $0.14 with clef-flash. Verify.
- `OPENROUTER_API_KEY` is already in the box's `/etc/stash-webhook/env` and in `~/.zshrc`. Never
  print it or write it anywhere.
- **Categories today:** `Category` enum in `TikTokBrainKit/Sources/TikTokBrainKit/Core/Types.swift`
  (recipe, fitness, style, travel, home, learning, comedy, music, coding, film, dining, …). Today they
  come from the analyzer after import: `POST /v1/chat/completions` proxies Bedrock
  `google.gemma-4-26b-a4b` (`services/webhook/api_v1.py`) and spends 1 import unit per video.
- **Cloud import:** `services/webhook/cloud_import_*.py`. The worker reads yt-dlp metadata (caption,
  hashtags) per video. `yt-dlp --skip-download --dump-json` returns caption, sound, cover URL and
  subtitle availability in about 1.3 s with no video download, which is a cheap Clef input.
- **Menu:** tab slots are `@AppStorage("tabSlots")` (`App/Sources/TikTokBrainApp.swift:149`).
  Project memory: TabView breaks past 5 sections, and retaining tabs measured 3× slower on device.
- **Clef spike results (2026-10-07):** 100 of the owner's saves, inputs = cover + caption + hashtags
  + sound. "Is there speech?" scored AUC 0.80 (flash) / 0.84 (27B). "Is there on-screen text?" scored
  AUC 0.53, a coin flip, with either model. Classification by type was not tested, so measure it
  before designing around it; the existing Gemma categories on the phone are free ground truth.
  ~$0.00007 per flash call, median 548 ms. API gotcha: on OpenRouter the image goes inside `state`
  as `{"type":"image_url",…}`; the top-level `images` field from Cloudflare's schema returns 400.
  Scripts and data: `/private/tmp/claude-501/-Users-dmitryschab-Documents-projects-stash-app/92620a73-81de-4adf-b6ee-783133b9a13b/scratchpad/clef-spike/`
- **Branches:** local, unpushed `feat/tiktok-portability-p2` → `feat/tiktok-oauth-p1` →
  `feat/ux-laws-rework` (unmerged; it reworked `ImportView` and `TikTokBrainApp`). Ask the owner
  which base to use. Not plain `main`, or the UX rework will conflict.

## Questions the design must settle

1. Does Clef replace the Gemma categorization, or give a fast first guess that Gemma corrects later?
   If it's only a guess, what happens when the two disagree on screen?
2. Where does it run: the server at import (where the key and the yt-dlp metadata already are) or
   the phone? Is it charged against the import budget?
3. Privacy: covers and captions go to OpenRouter and Cloudflare, so `privacy.html` needs a line.
4. Does the focus picker write the existing `tabSlots`, and what happens past 5 choices?
5. Animation scope: which categories get one, and what's the fallback?
