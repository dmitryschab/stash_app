import json, os, re, sys, urllib.request, time
from aws_bedrock_token_generator import provide_token
SP = os.path.dirname(os.path.abspath(__file__)) + "/batch"
token = provide_token(region="eu-central-1")
meta = {}
for line in open(f"{SP}/meta.tsv"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) >= 3: meta[parts[0]] = (parts[1], parts[2])
urls = {}
for line in open(f"{SP}/urls.txt"):
    line = line.strip()
    vid = line.split("/")[-1]
    urls[vid] = "https://www.tiktok.com/" + line

PROMPT = """You are the analyzer for a TikTok bookmark organizer. Given a video's caption and transcript, return ONLY a JSON object (no markdown fences) with:
- "category": one of "recipe", "music", "coding", "other"
- "title": short descriptive title (max 60 chars)
- "summary": 1-2 sentence summary
- "topics": 2-4 lowercase topic tags
- if recipe: "recipe": {"name": str, "ingredients": [str], "steps": [str]}
- if music: "track": {"title": str, "artist": str}
- if coding/tech/AI-tools: "code": {"summary": str, "links": [], "techTags": [str]}
Transcripts may be in English or Russian; always answer in English.
CAPTION: %s
TRANSCRIPT: %s"""

out, usage_in, usage_out = [], 0, 0
ids = [l.strip().split("/")[-1] for l in open(f"{SP}/urls.txt")]
for i, vid in enumerate(ids):
    author, caption = meta.get(vid, ("", ""))
    tpath = f"{SP}/{vid}.txt"
    transcript = open(tpath).read().strip()[:6000] if os.path.exists(tpath) else ""
    body = {"model": "google.gemma-4-26b-a4b", "max_tokens": 700,
            "messages": [{"role": "user", "content": PROMPT % (caption[:300], transcript or "(no speech)")}]}
    req = urllib.request.Request("https://bedrock-mantle.eu-central-1.api.aws/openai/v1/chat/completions",
        data=json.dumps(body).encode(), headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    for attempt in range(3):
        try:
            r = json.load(urllib.request.urlopen(req, timeout=120))
            break
        except Exception as e:
            if attempt == 2: print(vid, "FAILED", e); r = None
            time.sleep(3)
    if not r: continue
    u = r.get("usage", {}); usage_in += u.get("prompt_tokens", 0); usage_out += u.get("completion_tokens", 0)
    text = r["choices"][0]["message"]["content"]
    m = re.search(r"\{.*\}", text, re.S)
    try: parsed = json.loads(m.group(0))
    except Exception: print(vid, "BAD JSON"); continue
    parsed.update({"videoID": vid, "url": urls[vid], "author": author, "caption": caption, "transcript": transcript or None})
    out.append(parsed)
    print(f"{i+1}/{len(ids)} {vid} -> {parsed.get('category')}", flush=True)

json.dump(out, open(f"{SP}/seed.json", "w"), ensure_ascii=False, indent=1)
print(f"WROTE {len(out)} videos. tokens in={usage_in} out={usage_out}")
cost = usage_in*0.33/1e6 + usage_out*2.75/1e6
print(f"worst-case cost: ${cost:.4f}")
