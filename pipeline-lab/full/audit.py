#!/usr/bin/env python3
"""Mechanical audit of seed.json — flags the failure modes from the handoff.
Prints category distribution + a list of flagged videoIDs by issue (for cheap re-runs)."""
import json, os, re, sys
from collections import Counter

SEED = os.path.dirname(os.path.abspath(__file__)) + "/seed.json"
d = json.load(open(sys.argv[1] if len(sys.argv) > 1 else SEED))

VAGUE = re.compile(r"\b(this (video|clip|tiktok)|the video|talks about|is about a video)\b", re.I)
def cyrillic(s): return bool(re.search(r"[а-яА-ЯёЁ]", s or ""))
def mostly_non_ascii(s):
    s = s or ""
    letters = [c for c in s if c.isalpha()]
    return letters and sum(c.isascii() for c in letters) / len(letters) < 0.7

cats = Counter(v.get("category") for v in d)
nn = sum(1 for v in d if v.get("transcript"))
print(f"total: {len(d)}  |  with transcript: {nn} ({100*nn//len(d)}%)  null: {len(d)-nn}")
print("categories:", dict(cats))
print()

flags = {"title>60": [], "no_topics": [], "vague_summary": [], "non_english": [],
         "missing_payload": [], "empty_summary": [], "empty_title": []}
for v in d:
    vid, cat = v["videoID"], v.get("category")
    t, s, tops = v.get("title", ""), v.get("summary", ""), v.get("topics") or []
    if len(t) > 60: flags["title>60"].append(vid)
    if not t.strip(): flags["empty_title"].append(vid)
    if not s.strip(): flags["empty_summary"].append(vid)
    if not tops: flags["no_topics"].append(vid)
    if VAGUE.search(s): flags["vague_summary"].append(vid)
    if cyrillic(s) or cyrillic(t) or mostly_non_ascii(s): flags["non_english"].append(vid)
    if cat == "recipe" and not v.get("recipe"): flags["missing_payload"].append(vid)
    if cat == "music" and not v.get("track"): flags["missing_payload"].append(vid)
    if cat == "coding" and not v.get("code"): flags["missing_payload"].append(vid)

for k, ids in flags.items():
    print(f"{k:16} {len(ids):4}  {ids[:6]}{' ...' if len(ids) > 6 else ''}")

# dump all flagged ids (union) for a targeted re-run
allflagged = sorted(set(i for ids in flags.values() for i in ids))
open(os.path.dirname(SEED) + "/flagged.txt", "w").write("\n".join(allflagged) + "\n")
print(f"\n{len(allflagged)} unique flagged ids -> flagged.txt")
