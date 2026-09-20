#!/usr/bin/env python3
"""Offline A/B of TypeSafe Jev against the two incumbents it could replace.

Bench 1 (category): Jev Choice over the 13 analyzer categories vs the label
    google.gemma-4-26b-a4b already produced for the 855-video validation run.
Bench 2 (halluc):   Jev Noul per Whisper segment vs the hand-rolled rule filter
    in services/webhook/api_v1.py (blocklist + no_speech_prob/avg_logprob/
    compression_ratio gates + n-gram loop detection).

Neither incumbent is ground truth. Agreement is not accuracy: the output that
matters is the disagreement list, which a human adjudicates. `report` prints it.

Nothing here touches the box or production. Reads pipeline-lab data only.

Usage:
    export TYPESAFE_API_KEY=...
    python3 jevbench.py category --n 200 --budget 0.50
    python3 jevbench.py segments --n 60          # local whisper, no API, no cost
    python3 jevbench.py halluc   --budget 0.50
    python3 jevbench.py report
"""
import argparse
import json
import os
import re
import statistics
import sys
import time
import urllib.error
import urllib.request
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
FULL = os.path.join(HERE, "full")
SEED = os.path.join(FULL, "seed.full.bak.json")   # 855 records, all categorised
MEDIA = os.path.join(FULL, "media")
RAW = os.path.join(HERE, "jevbench-raw")          # raw whisper segments (bench 2 input)
OUT = os.path.join(HERE, "jevbench-out")

# Official endpoint, confirmed against docs.typesafe.ai. Note: the community site
# jevapi.org advertises https://tokenra.io/v1/decisions — an unaffiliated host. Do
# not send a key there.
BASE = os.environ.get("TYPESAFE_BASE_URL", "https://api.typesafe.ai").rstrip("/")
PATH = "/v1/systemone"
MODEL = os.environ.get("TYPESAFE_DEFAULT_MODEL", "jev-latest")
IN_COST_PER_TOK = 0.042 / 1_000_000   # output is unmetered
CTX_LIMIT = 32_000                    # Jev context window, in tokens

WHISPER = "mlx-community/whisper-large-v3-turbo"

# Verbatim from ANALYSIS_SYSTEM_PROMPT (api_v1.py:329-355). Kept identical so the
# comparison measures the model, not a reworded taxonomy.
CATEGORIES = {
    "recipe": "cooking, a dish, ingredients or steps",
    "fitness": "workouts, gym, running, nutrition",
    "style": "fashion, beauty, makeup",
    "travel": "trips, destinations, hotels, flights",
    "home": "decor, cleaning, DIY, renovation, gardening",
    "learning": "facts, how-to, study, science, history",
    "comedy": "skits, jokes, memes, pranks",
    "music": "albums, tracks, artists, listening recommendations",
    "coding": "software, gadgets, AI, and tags like #linux #arch #selfhosted "
              "#homelab #docker #python #react #vim",
    "film": "movies, TV, anime, what to watch",
    "dining": "restaurants, cafes, coffee, wine",
    "wellness": "health, supplements, sleep, mental health",
    "other": "none of the above fits",
}


# ---------------------------------------------------------------- client

class Budget:
    """Refuse a call that could take the run past the cap. Borrowed from the
    guard in kliros tools/orbench.py, which exists for the same reason."""

    def __init__(self, cap_usd):
        self.cap = cap_usd
        self.spent = 0.0

    def check(self, est_tokens):
        est = est_tokens * IN_COST_PER_TOK
        if self.spent + est > self.cap:
            raise SystemExit(
                f"budget stop: spent ${self.spent:.4f}, next call ~${est:.4f}, "
                f"cap ${self.cap:.2f}. Raise --budget to continue.")

    def add(self, tokens):
        self.spent += tokens * IN_COST_PER_TOK


def est_tokens(state: str) -> int:
    """No tokenizer is shipped for Jev. 4 chars/token is the usual English
    approximation; it is only used for the budget guard and the cost estimate,
    both of which are reported as estimates."""
    return max(1, len(state) // 4)


KEYFILE = os.path.expanduser("~/.config/typesafe/.env")


def api_key() -> str:
    """Env first, then ~/.config/typesafe/.env — same convention as ~/.config/watch/.env.
    Keeping it out of the repo means it never lands in a diff."""
    key = os.environ.get("TYPESAFE_API_KEY")
    if key:
        return key.strip()
    try:
        with open(KEYFILE, encoding="utf-8") as fh:
            for line in fh:
                k, _, v = line.partition("=")
                if k.strip() == "TYPESAFE_API_KEY":
                    return v.strip().strip("'\"")
    except OSError:
        pass
    raise SystemExit(f"no key. export TYPESAFE_API_KEY, or put it in {KEYFILE}")


def ask(state: str, questions: dict, budget: Budget, retries: int = 2) -> tuple[dict, float, int]:
    """POST one state + question map. Returns (answers, latency_s, tokens)."""
    key = api_key()

    tok = est_tokens(state)
    if tok > CTX_LIMIT:
        raise ValueError(f"state is ~{tok} tokens, over the {CTX_LIMIT} context window")
    budget.check(tok)

    body = json.dumps({"model": MODEL, "state": state, "questions": questions}).encode()
    req = urllib.request.Request(
        BASE + PATH, data=body, method="POST",
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})

    for attempt in range(retries + 1):
        t0 = time.monotonic()
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                payload = json.load(resp)
            dt = time.monotonic() - t0
            # Prefer the server's own count when it reports one.
            tok = (payload.get("usage") or {}).get("input_tokens") or tok
            budget.add(tok)
            return payload.get("answers", {}), dt, tok
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503) and attempt < retries:
                time.sleep(2 ** attempt)
                continue
            raise SystemExit(f"HTTP {e.code} from {BASE}{PATH}: {e.read()[:300].decode(errors='replace')}")
        except urllib.error.URLError as e:
            if attempt < retries:
                time.sleep(2 ** attempt)
                continue
            raise SystemExit(f"cannot reach {BASE}: {e.reason}")
    raise SystemExit("unreachable")


def checkpoint(path, rows):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rows, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, path)   # atomic: a killed run never leaves half a file


def load(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


# ---------------------------------------------------------------- bench 1: category

def state_for(rec: dict) -> str:
    """Mirror the user block the analyzer sees (api_v1.py builds caption, author,
    sound and transcript). Same inputs, so the only variable is the model."""
    tr = os.path.join(FULL, "transcripts", f"{rec['videoID']}.txt")
    transcript = ""
    if os.path.exists(tr):
        with open(tr, encoding="utf-8") as fh:
            transcript = fh.read().strip()
    parts = [f"author: @{rec.get('author', '')}",
             f"caption: {(rec.get('caption') or '').strip()}"]
    if transcript:
        parts.append(f"transcript:\n{transcript}")
    state = "\n".join(parts)
    # Long transcripts are the only thing that can approach the window. Trim the
    # tail rather than failing the record; the category signal is front-loaded.
    cap = (CTX_LIMIT - 500) * 4
    return state[:cap]


def cmd_category(args):
    recs = load(SEED, [])
    if not recs:
        raise SystemExit(f"no records in {SEED}")
    recs = recs[:args.n]
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "category.json")
    rows = load(path, [])
    done = {r["videoID"] for r in rows}
    budget = Budget(args.budget)
    budget.spent = sum(r["tokens"] for r in rows) * IN_COST_PER_TOK

    question = {"category": {
        "type": "choice",
        "instructions": "Pick the single category this short video belongs to, "
                        "judging the whole post including hashtags.",
        "criteria": CATEGORIES,
    }}

    todo = [r for r in recs if r["videoID"] not in done]
    print(f"category: {len(todo)} to do ({len(done)} already done)", flush=True)
    for n, rec in enumerate(todo, 1):
        try:
            answers, dt, tok = ask(state_for(rec), question, budget)
        except ValueError as e:
            print("  SKIP", rec["videoID"], e, flush=True)
            continue
        a = answers.get("category", {})
        rows.append({
            "videoID": rec["videoID"],
            "incumbent": rec.get("category"),
            "jev": a.get("choice"),
            "confidence": a.get("confidence"),
            "distribution": a.get("distribution"),
            "latency_s": round(dt, 3),
            "tokens": tok,
            "caption": (rec.get("caption") or "")[:200],
        })
        if n % 10 == 0 or n == len(todo):
            checkpoint(path, rows)
            print(f"  {n}/{len(todo)}  ${budget.spent:.4f}", flush=True)
    checkpoint(path, rows)
    print(f"wrote {path}  est. cost ${budget.spent:.4f}")


# ---------------------------------------------------------------- bench 2: segments

# Ports of the production gates (api_v1.py:160-215) so the incumbent under test
# is the code that actually ships, not a paraphrase of it.
NO_SPEECH_MAX = 0.6
AVG_LOGPROB_MIN = -1.0
COMPRESSION_RATIO_MAX = 2.4
_HALLUCINATIONS = (
    "субтитры сделал", "субтитры создавал", "субтитры делал", "редактор субтитров",
    "dimatorzok", "amara.org", "subtitles by", "subs by", "subtitle by",
    "thanks for watching", "thank you for watching", "please subscribe",
    "like and subscribe", "don't forget to subscribe", "see you next time",
    "시청해주셔서 감사합니다", "mbc 뉴스", "字幕", "字幕志愿者",
)


def _is_hallucination(text: str) -> bool:
    return any(h in text.strip().lower() for h in _HALLUCINATIONS)


def _ngram_loops(line: str) -> bool:
    words = line.split()
    for n in (3, 4):
        if len(words) < n * 2:
            continue
        grams = [tuple(words[i:i + n]) for i in range(len(words) - n + 1)]
        if grams and max(Counter(grams).values()) >= 2:
            return True
    return False


def _low_diversity(line: str) -> bool:
    words = line.split()
    return len(words) >= 4 and len({w.lower() for w in words}) / len(words) < 0.5


def rules_keep(seg: dict) -> bool:
    """The incumbent verdict for one segment: True = real speech, keep it."""
    if seg.get("no_speech_prob", 0.0) >= NO_SPEECH_MAX:
        return False
    if seg.get("avg_logprob", 0.0) < AVG_LOGPROB_MIN:
        return False
    if seg.get("compression_ratio", 0.0) > COMPRESSION_RATIO_MAX:
        return False
    text = re.sub(r"\s+", " ", seg.get("text", "")).strip()
    if not text:
        return False
    return not (_is_hallucination(text) or _ngram_loops(text) or _low_diversity(text))


def cmd_segments(args):
    """Re-transcribe locally, keeping RAW segments. The shipped pipeline saves
    only post-filter text, so the dropped lines — the whole point of bench 2 —
    do not exist on disk anywhere. Free: local MLX, no API."""
    import mlx_whisper

    os.makedirs(RAW, exist_ok=True)
    wavs = sorted(f for f in os.listdir(MEDIA) if f.endswith(".wav"))[:args.n]
    todo = [w for w in wavs if not os.path.exists(os.path.join(RAW, w[:-4] + ".json"))]
    print(f"segments: {len(todo)} to transcribe (raw, unfiltered)", flush=True)
    for n, wav in enumerate(todo, 1):
        vid = wav[:-4]
        try:
            r = mlx_whisper.transcribe(os.path.join(MEDIA, wav), path_or_hf_repo=WHISPER,
                                       condition_on_previous_text=False)
        except Exception as e:
            print("  ERR", vid, e, flush=True)
            continue
        segs = [{k: s.get(k) for k in
                 ("text", "no_speech_prob", "avg_logprob", "compression_ratio", "start", "end")}
                for s in r.get("segments", [])]
        checkpoint(os.path.join(RAW, vid + ".json"), segs)
        if n % 5 == 0 or n == len(todo):
            print(f"  {n}/{len(todo)}", flush=True)
    print(f"wrote raw segments to {RAW}")


def cmd_halluc(args):
    if not os.path.isdir(RAW):
        raise SystemExit(f"no raw segments. Run: python3 {sys.argv[0]} segments --n 60")
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "halluc.json")
    rows = load(path, [])
    done = {(r["videoID"], r["idx"]) for r in rows}
    budget = Budget(args.budget)
    budget.spent = sum(r["tokens"] for r in rows) * IN_COST_PER_TOK

    question = {"is_speech": {
        "type": "noul",
        "instructions": "This is one transcript segment from a short social video. "
                        "Is it real speech spoken in the video, rather than a "
                        "transcription artefact such as a canned subtitle credit, a "
                        "sign-off, or repeated filler produced over music or silence?",
        "criteria": {
            "true": "genuine speech from the video, even if short or fragmentary",
            "false": "a hallucinated or boilerplate line the speaker did not say",
        },
    }}

    todo = []
    for name in sorted(os.listdir(RAW)):
        if not name.endswith(".json"):
            continue
        vid = name[:-5]
        for idx, seg in enumerate(load(os.path.join(RAW, name), [])):
            if (vid, idx) not in done and (seg.get("text") or "").strip():
                todo.append((vid, idx, seg))
    if args.n:
        todo = todo[:args.n]

    print(f"halluc: {len(todo)} segments to judge ({len(done)} done)", flush=True)
    for n, (vid, idx, seg) in enumerate(todo, 1):
        text = re.sub(r"\s+", " ", seg.get("text", "")).strip()
        answers, dt, tok = ask(text, question, budget)
        a = answers.get("is_speech", {})
        noul = a.get("noul", a.get("confidence"))
        rows.append({
            "videoID": vid, "idx": idx, "text": text[:300],
            "rules_keep": rules_keep(seg),
            "jev_noul": noul,
            "no_speech_prob": seg.get("no_speech_prob"),
            "avg_logprob": seg.get("avg_logprob"),
            "compression_ratio": seg.get("compression_ratio"),
            "latency_s": round(dt, 3), "tokens": tok,
        })
        if n % 25 == 0 or n == len(todo):
            checkpoint(path, rows)
            print(f"  {n}/{len(todo)}  ${budget.spent:.4f}", flush=True)
    checkpoint(path, rows)
    print(f"wrote {path}  est. cost ${budget.spent:.4f}")


# ---------------------------------------------------------------- report

def _latency(rows):
    lat = sorted(r["latency_s"] for r in rows)
    if not lat:
        return "n/a"
    p95 = lat[min(len(lat) - 1, int(len(lat) * 0.95))]
    return f"p50 {statistics.median(lat):.2f}s  p95 {p95:.2f}s"


def report_category(rows):
    print("\n=== bench 1: category (Jev Choice vs gemma-4-26b) ===")
    print(f"n={len(rows)}   {_latency(rows)}   est. cost ${sum(r['tokens'] for r in rows) * IN_COST_PER_TOK:.4f}")
    agree = [r for r in rows if r["jev"] == r["incumbent"]]
    print(f"agreement with incumbent: {len(agree)}/{len(rows)} = {len(agree) / len(rows):.1%}")
    print("  (agreement is NOT accuracy — gemma is unlabelled too. See disagreements.)")

    conf = [r["confidence"] for r in rows if isinstance(r.get("confidence"), (int, float))]
    if conf:
        print(f"\nconfidence: median {statistics.median(conf):.2f}")
        print("  calibration — does low confidence predict disagreement?")
        for lo, hi in ((0.0, 0.5), (0.5, 0.7), (0.7, 0.9), (0.9, 1.01)):
            b = [r for r in rows if isinstance(r.get("confidence"), (int, float))
                 and lo <= r["confidence"] < hi]
            if b:
                ok = sum(1 for r in b if r["jev"] == r["incumbent"])
                print(f"    conf {lo:.1f}-{hi:.1f}: n={len(b):4d}  agree {ok / len(b):.1%}")

    mism = Counter((r["incumbent"], r["jev"]) for r in rows if r["jev"] != r["incumbent"])
    print("\ntop disagreements (gemma -> jev), adjudicate these by hand:")
    for (inc, jev), c in mism.most_common(10):
        print(f"    {c:4d}  {inc or '?':9s} -> {jev or '?'}")
    print("\n  sample disagreement captions:")
    for r in [x for x in rows if x["jev"] != x["incumbent"]][:5]:
        print(f"    [{r['incumbent']} -> {r['jev']} @{r.get('confidence')}] {r['caption'][:90]}")


def report_halluc(rows):
    print("\n=== bench 2: hallucination filter (Jev Noul vs shipped rules) ===")
    print(f"n={len(rows)} segments   {_latency(rows)}   est. cost ${sum(r['tokens'] for r in rows) * IN_COST_PER_TOK:.4f}")
    thr = 0.5
    both_keep = [r for r in rows if r["rules_keep"] and (r["jev_noul"] or 0) >= thr]
    both_drop = [r for r in rows if not r["rules_keep"] and (r["jev_noul"] or 0) < thr]
    jev_drops = [r for r in rows if r["rules_keep"] and (r["jev_noul"] or 0) < thr]
    jev_saves = [r for r in rows if not r["rules_keep"] and (r["jev_noul"] or 0) >= thr]
    n = len(rows) or 1
    print(f"  agree keep: {len(both_keep)}   agree drop: {len(both_drop)}   "
          f"=> {(len(both_keep) + len(both_drop)) / n:.1%} agreement")
    print(f"\n  jev drops what rules keep ({len(jev_drops)}) — candidate hallucinations the blocklist misses:")
    for r in jev_drops[:8]:
        print(f"    noul={r['jev_noul']}  {r['text'][:80]}")
    print(f"\n  jev keeps what rules drop ({len(jev_saves)}) — candidate real speech being lost today:")
    for r in jev_saves[:8]:
        print(f"    noul={r['jev_noul']}  nsp={r['no_speech_prob']}  {r['text'][:70]}")
    print("\n  Both lists need human adjudication. That count IS the finding:")
    print("  the rules are deterministic, so every disagreement is a case the")
    print("  shipped filter gets wrong or Jev does — nothing else explains it.")


def cmd_report(args):
    cat = load(os.path.join(OUT, "category.json"), [])
    hal = load(os.path.join(OUT, "halluc.json"), [])
    if cat:
        report_category(cat)
    if hal:
        report_halluc(hal)
    if not cat and not hal:
        print("nothing to report — run `category` and/or `halluc` first")
    if cat:
        # The decision this whole exercise exists to inform.
        per_video = sum(r["tokens"] for r in cat) / len(cat) * IN_COST_PER_TOK
        print(f"\nper-video Jev category cost: ${per_video:.6f}  "
              f"(analyzer comment claims ~$0.0005/video for the full gemma call)")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("category", help="bench 1: Jev Choice vs gemma category")
    c.add_argument("--n", type=int, default=200)
    c.add_argument("--budget", type=float, default=0.50, help="hard USD cap")
    c.set_defaults(fn=cmd_category)

    s = sub.add_parser("segments", help="local whisper, raw segments, no API cost")
    s.add_argument("--n", type=int, default=60)
    s.set_defaults(fn=cmd_segments)

    h = sub.add_parser("halluc", help="bench 2: Jev Noul vs shipped rule filter")
    h.add_argument("--n", type=int, default=0, help="0 = all available segments")
    h.add_argument("--budget", type=float, default=0.50, help="hard USD cap")
    h.set_defaults(fn=cmd_halluc)

    r = sub.add_parser("report", help="print both benchmarks")
    r.set_defaults(fn=cmd_report)

    args = p.parse_args()
    args.fn(args)


def selftest():
    """Smallest thing that fails if the incumbent port drifts from api_v1.py."""
    assert rules_keep({"text": "here is the recipe", "no_speech_prob": 0.02, "avg_logprob": -0.3})
    assert not rules_keep({"text": "music", "no_speech_prob": 0.95})
    assert not rules_keep({"text": "hi", "avg_logprob": -2.0})
    assert not rules_keep({"text": "la la la la", "compression_ratio": 3.1})
    assert not rules_keep({"text": "Субтитры создавал кто-то"})
    assert not rules_keep({"text": "The The The The"})
    assert rules_keep({"text": "plain segment with no confidence fields"})
    assert est_tokens("abcd" * 10) == 10
    b = Budget(0.0001)
    b.check(1)
    try:
        b.check(10_000_000)
    except SystemExit:
        pass
    else:
        raise AssertionError("budget guard did not fire")
    print("jevbench selftest OK")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        selftest()
    else:
        main()
