#!/usr/bin/env python3
"""Resumable Stash pipeline over the full favorites library.

Stages (each skips already-produced artifacts, so re-running resumes):
  meta       yt-dlp -j per id  -> meta.tsv  (id\tuploader\tcaption\tduration)
  dl         download mp4 -> wav            -> media/<id>.wav
  transcribe wav -> cleaned transcript      -> transcripts/<id>.txt  (or .null marker)
  analyze    Gemma on Bedrock               -> seed.json  (append, checkpointed)

Run:  ./run.py meta | dl [--shard i/n] | transcribe [--shard i/n] | analyze
"""
import json, os, re, sys, subprocess, time, urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

HERE = os.path.dirname(os.path.abspath(__file__))
MEDIA = f"{HERE}/media"
TR = f"{HERE}/transcripts"
META = f"{HERE}/meta.tsv"
SEED = f"{HERE}/seed.json"
IDS = f"{HERE}/ids.txt"
LINKS = f"{HERE}/share_links.txt"
WHISPER = "mlx-community/whisper-large-v3-turbo"


def ids():
    return [l.strip() for l in open(IDS) if l.strip()]


def links():
    return {i: l.strip() for i, l in zip(ids(), open(LINKS))}


def load_meta():
    m = {}
    if os.path.exists(META):
        for line in open(META):
            p = line.rstrip("\n").split("\t")
            if len(p) >= 3:
                m[p[0]] = p[1:]  # uploader, caption, duration?
    return m


def clean(s):
    return re.sub(r"\s+", " ", (s or "").replace("\t", " ").replace("\n", " ")).strip()


# ---------------------------------------------------------------- meta
def stage_meta():
    link = links()
    have = load_meta()
    todo = [i for i in ids() if i not in have]
    print(f"meta: {len(have)} cached, {len(todo)} to fetch", flush=True)

    def fetch(vid):
        try:
            out = subprocess.run(["yt-dlp", "-j", "--no-warnings", link[vid]],
                                 capture_output=True, text=True, timeout=60)
            if out.returncode != 0:
                return vid, None
            d = json.loads(out.stdout)
            return vid, (clean(d.get("uploader") or d.get("uploader_id") or ""),
                         clean(d.get("description") or ""), str(d.get("duration") or ""))
        except Exception:
            return vid, None

    fails = []
    with open(META, "a") as f:
        with ThreadPoolExecutor(max_workers=5) as ex:  # >5 -> silent TikTok rate limits
            for n, (vid, res) in enumerate(as_completed_map(ex, fetch, todo), 1):
                if res is None:
                    fails.append(vid)
                else:
                    f.write(f"{vid}\t{res[0]}\t{res[1]}\t{res[2]}\n"); f.flush()
                if n % 50 == 0:
                    print(f"  {n}/{len(todo)} (fails so far {len(fails)})", flush=True)
    # retry stragglers serially (rate-limit victims)
    if fails:
        print(f"retrying {len(fails)} stragglers serially...", flush=True)
        with open(META, "a") as f:
            for vid in fails:
                time.sleep(1)
                _, res = fetch(vid)
                if res:
                    f.write(f"{vid}\t{res[0]}\t{res[1]}\t{res[2]}\n"); f.flush()
                else:
                    print("  STILL-FAILED", vid, flush=True)
    print(f"meta done: {len(load_meta())}/{len(ids())} have metadata", flush=True)


def as_completed_map(ex, fn, items):
    futs = {ex.submit(fn, it): it for it in items}
    for fut in as_completed(futs):
        yield fut.result()


# ---------------------------------------------------------------- download
def stage_dl(shard):
    link = links()
    meta = load_meta()
    def need(i):
        return (i in meta                              # unavailable videos have no meta
                and not os.path.exists(f"{MEDIA}/{i}.wav")
                and not os.path.exists(f"{TR}/{i}.txt")   # already transcribed (pilot reuse)
                and not os.path.exists(f"{TR}/{i}.null"))
    todo = shard_filter([i for i in ids() if need(i)], shard)
    print(f"dl: {len(todo)} to download (shard {shard})", flush=True)
    for n, vid in enumerate(todo, 1):
        ok = download_one(vid, link[vid])
        if n % 25 == 0 or not ok:
            print(f"  {n}/{len(todo)} {vid} {'ok' if ok else 'FAIL'}", flush=True)


def download_one(vid, url):
    mp4 = f"{MEDIA}/{vid}.mp4"; wav = f"{MEDIA}/{vid}.wav"
    # default format is sometimes video-only; prefer a format with audio, else -1 CDN variant
    subprocess.run(["yt-dlp", "-q", "-f", "bestaudio/best", "-o", mp4, "--no-warnings", url],
                   capture_output=True, timeout=180)
    if not os.path.exists(mp4):
        subprocess.run(["yt-dlp", "-q", "-f", "mp4", "-o", mp4, "--no-warnings", url],
                       capture_output=True, timeout=180)
    if not os.path.exists(mp4):
        return False
    r = subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", mp4, "-ar", "16000", "-ac", "1", wav],
                       capture_output=True, timeout=120)
    ok = os.path.exists(wav) and os.path.getsize(wav) > 2000
    if ok:
        os.remove(mp4)  # keep only the 16k wav; mp4s would be ~GBs at scale
    return ok


# ---------------------------------------------------------------- transcribe
def stage_transcribe(shard):
    import mlx_whisper
    todo = shard_filter([i for i in ids()
                         if os.path.exists(f"{MEDIA}/{i}.wav")
                         and not os.path.exists(f"{TR}/{i}.txt")
                         and not os.path.exists(f"{TR}/{i}.null")], shard)
    print(f"transcribe: {len(todo)} to do (shard {shard})", flush=True)
    for n, vid in enumerate(todo, 1):
        try:
            r = mlx_whisper.transcribe(f"{MEDIA}/{vid}.wav", path_or_hf_repo=WHISPER,
                                       condition_on_previous_text=False)
            lines = [clean(s.get("text", "")) for s in r.get("segments", [])]
            text = filter_transcript(lines)
            if text:
                open(f"{TR}/{vid}.txt", "w").write(text)
            else:
                open(f"{TR}/{vid}.null", "w").write("")  # music-only marker (resumable skip)
        except Exception as e:
            print("  ERR", vid, e, flush=True)
        if n % 20 == 0:
            print(f"  {n}/{len(todo)}", flush=True)


def filter_transcript(lines):
    """Kill Whisper repetition hallucinations. Returns cleaned text or '' (music-only).
    1) collapse consecutive duplicate lines
    2) drop lines whose own 3/4-grams repeat >=2x (internal loops)
    3) drop lines that appear >4x overall
    4) if <12 words remain -> '' (treat as music-only)."""
    out = []
    for ln in lines:
        ln = ln.strip()
        if not ln:
            continue
        if out and ln == out[-1]:
            continue  # (1)
        if ngram_loops(ln):
            continue  # (2)
        out.append(ln)
    from collections import Counter
    c = Counter(out)
    out = [ln for ln in out if c[ln] <= 4]  # (3)
    text = "\n".join(out).strip()
    if len(text.split()) < 12:  # (4)
        return ""
    return text


def ngram_loops(line):
    w = line.split()
    for n in (3, 4):
        if len(w) < n * 2:
            continue
        grams = [tuple(w[i:i + n]) for i in range(len(w) - n + 1)]
        from collections import Counter
        if grams and max(Counter(grams).values()) >= 2:
            return True
    return False


def shard_filter(items, shard):
    if not shard:
        return items
    i, n = shard
    return [x for k, x in enumerate(items) if k % n == i]


# ---------------------------------------------------------------- analyze
PROMPT = """You are the analyzer for a TikTok bookmark organizer. Given a video's caption and transcript, return ONLY a JSON object (no markdown fences) with:
- "category": one of "recipe", "music", "coding", "other"
- "title": short descriptive title (max 60 chars)
- "summary": 1-2 sentence summary
- "topics": 2-4 lowercase topic tags
- if recipe: "recipe": {"name": str, "ingredients": [str], "steps": [str]}
- if music: "track": {"title": str, "artist": str}
- if coding/tech/AI-tools: "code": {"summary": str, "links": [], "techTags": [str]}
Rules:
- Classify from caption hashtags even when the transcript is empty: #linux #arch #archlinux #selfhosted #homelab #docker #python #react #vim → "coding"; cooking/baking/food → "recipe"; a song/lyrics/album → "music".
- Music: if the video is an album/artist RECOMMENDATION LIST (not one song), set track.title to the list's theme and track.artist to the main artist(s), or "" if several. If it is one song, identify title+artist from well-known lyrics — but NEVER invent an artist you are not confident about; use "" instead of guessing.
- NEVER output placeholder text like "No Content Provided"/"Untitled Video" as the title or summary. If caption and transcript are both empty, title="Saved video" and summary="No caption or audio was available for this save."
Transcripts may be in English or Russian; always answer in English.
CAPTION: %s
TRANSCRIPT: %s"""


def stage_analyze(only=None):
    from aws_bedrock_token_generator import provide_token
    token = provide_token(region="eu-central-1")
    meta = load_meta()
    done = {}
    if os.path.exists(SEED):
        done = {v["videoID"]: v for v in json.load(open(SEED))}
    if only:  # re-process a specific subset (tuning); replace their entries in-place
        force = set(l.strip() for l in open(only) if l.strip())
        todo = [i for i in ids() if i in meta and i in force]
        for i in todo:
            done.pop(i, None)
        print(f"analyze --only: re-processing {len(todo)} flagged videos", flush=True)
    else:
        todo = [i for i in ids() if i in meta and i not in done]
        print(f"analyze: {len(done)} cached, {len(todo)} to do", flush=True)
    ui = uo = 0
    out = list(done.values())
    for n, vid in enumerate(todo, 1):
        uploader, caption = meta[vid][0], meta[vid][1]
        tp = f"{TR}/{vid}.txt"
        transcript = open(tp).read().strip()[:6000] if os.path.exists(tp) else ""
        body = {"model": "google.gemma-4-26b-a4b", "max_tokens": 700,
                "messages": [{"role": "user",
                              "content": PROMPT % (caption[:300], transcript or "(no speech)")}]}
        req = urllib.request.Request(
            "https://bedrock-mantle.eu-central-1.api.aws/openai/v1/chat/completions",
            data=json.dumps(body).encode(),
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
        r = None
        for attempt in range(3):
            try:
                r = json.load(urllib.request.urlopen(req, timeout=120)); break
            except Exception as e:
                if attempt == 2:
                    print("  FAILED", vid, e, flush=True)
                time.sleep(3)
        if not r:
            continue
        u = r.get("usage", {}); ui += u.get("prompt_tokens", 0); uo += u.get("completion_tokens", 0)
        text = r["choices"][0]["message"]["content"]
        m = re.search(r"\{.*\}", text, re.S)
        try:
            parsed = json.loads(m.group(0))
        except Exception:
            print("  BAD JSON", vid, flush=True); continue
        parsed.update({"videoID": vid,
                       "url": f"https://www.tiktok.com/@{uploader}/video/{vid}",
                       "author": uploader, "caption": caption,
                       "transcript": transcript or None})
        out.append(parsed)
        if n % 25 == 0:
            json.dump(out, open(SEED, "w"), ensure_ascii=False, indent=1)  # checkpoint
            print(f"  {n}/{len(todo)} (in={ui} out={uo})", flush=True)
    json.dump(out, open(SEED, "w"), ensure_ascii=False, indent=1)
    cost = ui * 0.33 / 1e6 + uo * 2.75 / 1e6
    print(f"analyze done: {len(out)} videos. tokens in={ui} out={uo} cost=${cost:.4f}", flush=True)


# ---------------------------------------------------------------- thumbs
THUMBS = f"{HERE}/thumbs"
EXPORT = os.path.expanduser("~/Downloads/user_data_tiktok.json")


def stage_thumbs():
    """Download cover images (TikTok cover URLs are signed and expire — store pixels)."""
    os.makedirs(THUMBS, exist_ok=True)
    link = links()
    meta = load_meta()
    todo = [i for i in ids() if i in meta and not os.path.exists(f"{THUMBS}/{i}.jpg")]
    print(f"thumbs: {len(todo)} to fetch", flush=True)

    def fetch(vid):
        try:
            out = subprocess.run(["yt-dlp", "-j", "--no-warnings", link[vid]],
                                 capture_output=True, text=True, timeout=60)
            if out.returncode != 0:
                return vid, False
            url = json.loads(out.stdout).get("thumbnail")
            if not url:
                return vid, False
            img = urllib.request.urlopen(url, timeout=30).read()
            if len(img) < 1000:
                return vid, False
            open(f"{THUMBS}/{vid}.jpg", "wb").write(img)
            return vid, True
        except Exception:
            return vid, False

    fails = []
    with ThreadPoolExecutor(max_workers=5) as ex:  # >5 -> silent TikTok rate limits
        for n, (vid, ok) in enumerate(as_completed_map(ex, fetch, todo), 1):
            if not ok:
                fails.append(vid)
            if n % 50 == 0:
                print(f"  {n}/{len(todo)} (fails so far {len(fails)})", flush=True)
    if fails:
        print(f"retrying {len(fails)} stragglers serially...", flush=True)
        for vid in fails:
            time.sleep(1)
            _, ok = fetch(vid)
            if not ok:
                print("  STILL-FAILED", vid, flush=True)
    have = len([f for f in os.listdir(THUMBS) if f.endswith(".jpg")])
    print(f"thumbs done: {have} jpgs", flush=True)


# ---------------------------------------------------------------- finalize
def stage_finalize():
    """Deterministic fixups the model can't be trusted to do: placeholders,
    real bookmark dates (from the export), and thumbnail paths."""
    import re
    ph = re.compile(r"no (content|transcript|caption|data)|not provided|no speech|untitled", re.I)
    d = json.load(open(SEED))
    n = 0
    for v in d:
        if ph.search(v.get("title", "")) or ph.search(v.get("summary", "")):
            v["title"] = "Saved video"
            v["summary"] = "No caption or audio was available — open in TikTok to view."
            n += 1
    # real save dates from the export (id -> "yyyy-MM-dd HH:mm:ss", newest per id)
    dates = {}
    if os.path.exists(EXPORT):
        exp = json.load(open(EXPORT))
        for it in exp["Likes and Favorites"]["Favorite Videos"]["FavoriteVideoList"]:
            m = re.search(r"/(\d{15,})", it.get("Link", ""))
            if m:
                vid = m.group(1)
                dates[vid] = max(dates.get(vid, ""), it.get("Date", ""))
    nd = nt = 0
    for v in d:
        if v["videoID"] in dates:
            v["date"] = dates[v["videoID"]]; nd += 1
        if os.path.exists(f"{THUMBS}/{v['videoID']}.jpg"):
            v["thumbnail"] = f"thumbs/{v['videoID']}.jpg"; nt += 1
    json.dump(d, open(SEED, "w"), ensure_ascii=False, indent=1)
    print(f"finalize: {n} placeholders cleaned, {nd} dates set, {nt} thumbnails linked", flush=True)


# ---------------------------------------------------------------- self-test / cli
def selftest():
    # repetition loop -> dropped; genuine content -> kept
    assert filter_transcript(["The The The The", "The The The The"]) == ""
    assert filter_transcript(["one two three four five six seven eight nine ten eleven twelve"]) != ""
    assert ngram_loops("go go go go go go go go") is True
    assert ngram_loops("today I will show you a real cooking recipe step") is False
    # non-consecutive line repeated >4x (chorus) dropped; unique verses kept
    lines = []
    for i in range(5):
        lines += ["chorus line here", f"unique verse number {i} distinct words follow"]
    res = filter_transcript(lines)
    assert "chorus line here" not in res.split("\n")
    assert "unique verse number 0 distinct words follow" in res.split("\n")
    print("selftest OK")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "selftest"
    shard = None
    if "--shard" in sys.argv:
        i, n = sys.argv[sys.argv.index("--shard") + 1].split("/")
        shard = (int(i), int(n))
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
    {"meta": stage_meta,
     "dl": lambda: stage_dl(shard),
     "transcribe": lambda: stage_transcribe(shard),
     "analyze": lambda: stage_analyze(only),
     "thumbs": stage_thumbs,
     "finalize": stage_finalize,
     "selftest": selftest}[cmd]()
