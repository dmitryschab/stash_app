"""Stash /v1 haul offers — where a pick can actually be bought, priced for the buyer's country.

  POST /v1/haul/offers  {name, kind, country} -> {offers: [...], checkedAt, cached}
  One offer may carry imageURL: the shop page's og:image, the pick's catalog photo.

Its own module and its own router, mounted in app.py, like embeddings_api before it.

The Haul shelf knows what a save is selling but not where to buy it; its answer used to be a
store search URL, which is a question, not an answer. This route asks a web-searching model for
live listings and turns them into at most three offers the buyer can actually order:

  slot 1  the country's own Amazon storefront, whenever it stocks the item — pinned even when
          a rival is cheaper, because one trusted checkout beats ten unknown ones;
  slot 1  (when Amazon doesn't) the maker's own store;
  the rest cheapest first, one offer per shop.

An offer must point at a concrete product page — on Amazon that means /dp/ or /gp/product/ —
because a search-results link is exactly the non-answer this route exists to replace. A foreign
Amazon storefront is not the pin: amazon.com does not ship to a Latvian buyer the way amazon.de
does, so it competes on price like anybody else.

Money: no quota moves — the save was already paid for at import, and asking "how much is this
thing" must not cost like saving it. What bounds the route instead is a per-user per-UTC-day
cap (the deep-pass pattern) and a day-long answer cache shared across users, keyed on the
product + country, so one lookup serves everyone who saved the same viral thing. Roughly $0.01
per uncached lookup (Gemini Flash + the web plugin's per-request fee).

ponytail: prices are whatever the search snippets said, not a live scrape — each offer links to
the shop page as the source of truth. A structured product API (with an Amazon Associates
account behind it) is the upgrade path if snippet prices prove too stale.
"""
import hashlib
import json
import logging
import os
import re
import time
from datetime import datetime, timedelta, timezone
from html import unescape
from urllib.parse import urlparse

import requests
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, field_validator

import stash_secrets
from cloud_import_store import (
    QUOTA_CAS_ATTEMPTS,
    DynamoImportStore,
    _dynamo_value,
    _is_conditional_failure,
)
from stash_auth import entitled_store

log = logging.getLogger("stash-webhook")

router = APIRouter(prefix="/v1")

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
# The vision model already trusted with photo posts; here it reads search results instead.
OFFERS_MODEL = "google/gemini-3.7-flash"
# Six offers of one JSON line each; generous, because a truncated body loses the whole answer.
OFFERS_MAX_OUTPUT_TOKENS = 1200
SEARCH_MAX_RESULTS = 8
SEARCH_TIMEOUT = 90

# Measured against the live box: a 504 here is almost always an upstream provider 429 that
# clears immediately, and it comes back fast (~11s) while a real answer takes 33-69s. So one
# retry is worth taking, but only when the first failure was quick enough to leave room for it
# — a slow failure means the app is already near its own 100s timeout, and a second attempt
# would only make it wait longer for the same 502. When the app does give up, this request
# still finishes and caches, so the user's next open is an instant hit.
SEARCH_ATTEMPTS = 2
RETRY_WHILE_FASTER_THAN = 25.0
_TRANSIENT_STATUS = {408, 429, 500, 502, 503, 504}

MAX_OFFERS = 3
CACHE_HOURS = 24
# A shopping session opens a couple dozen picks; a hundred uncached lookups is ~a dollar.
OFFER_DAILY_CAP = 100

# Mirror of Shop.amazonHost in TikTokBrainKit/Core/Types.swift, fallback included: there is no
# worldwide Amazon, and a European buyer's nearest storefront that ships across the EU is .de.
_AMAZON_TLDS = {
    "US": "com", "CA": "ca", "MX": "com.mx", "BR": "com.br",
    "GB": "co.uk", "IE": "co.uk", "FR": "fr", "ES": "es", "IT": "it",
    "NL": "nl", "BE": "com.be", "SE": "se", "PL": "pl", "TR": "com.tr",
    "JP": "co.jp", "AU": "com.au", "IN": "in", "SG": "sg", "AE": "ae",
}


def amazon_host(country: str) -> str:
    return "www.amazon." + _AMAZON_TLDS.get(country, "de")


def _daily_cap() -> int:
    """Read per call, not at import — same reason as api_v1._daily_cap."""
    return int(os.environ.get("OFFER_DAILY_CAP") or OFFER_DAILY_CAP)


OFFERS_SYSTEM_PROMPT = """
You check where one product can be bought online right now. Use web search. Respond with ONLY
a JSON object, no prose and no Markdown code fences:
{"offers": [{"merchant": string, "url": string, "price": string, "amount": number,
             "currency": string, "isBrandSite": boolean}]}

Rules:
- Only shops that sell the product NEW and deliver to the buyer's country.
- ALWAYS include the preferred Amazon storefront's listing when it sells the product. Its url
  MUST be the direct product page (…/dp/ASIN), never a search results URL.
- Include the manufacturer's own online store when it sells directly and ships to the buyer's
  country, with "isBrandSite": true. Every other shop is "isBrandSite": false.
- Then other well-known retailers that ship there. Up to 6 offers total, one per shop.
- "url" is always the concrete product page for exactly this product — never a search page, a
  category page, or a similar-but-different model.
- "price" is the price exactly as the shop lists it ("€94.99"); "amount" is its number
  (94.99); "currency" is the ISO code ("EUR"). NEVER estimate: skip any shop whose current
  price you did not see, and skip used or refurbished listings.
- Finding nothing is a valid answer: {"offers": []}.
""".strip()


def _search(name: str, kind: str, country: str, storefront: str) -> str:
    """One web-searching completion; the raw content string comes back for parsing."""
    key = stash_secrets.secret("OPENROUTER_API_KEY")
    if not key:
        raise RuntimeError("offers not configured: no OPENROUTER_API_KEY")
    lines = [f"Product: {name}"]
    if kind:
        lines.append(f"Kind: {kind}")
    lines += [f"Buyer country: {country}", f"Preferred Amazon storefront: {storefront}"]
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    body = {
        "model": OFFERS_MODEL,
        "temperature": 0.1,
        "max_tokens": OFFERS_MAX_OUTPUT_TOKENS,
        # The web plugin, engine left on auto. OpenRouter is steering new work toward its
        # server tool, but the plugin is the shape its docs still fully specify — swap when
        # the tool's contract is documented.
        "plugins": [{"id": "web", "max_results": SEARCH_MAX_RESULTS}],
        "messages": [
            {"role": "system", "content": OFFERS_SYSTEM_PROMPT},
            {"role": "user", "content": "\n".join(lines)},
        ],
    }
    started = time.monotonic()
    status = 0
    for attempt in range(1, SEARCH_ATTEMPTS + 1):
        response = requests.post(OPENROUTER_URL, headers=headers, json=body,
                                 timeout=SEARCH_TIMEOUT)
        if response.status_code == 200:
            return response.json()["choices"][0]["message"]["content"]
        status = response.status_code
        if attempt == SEARCH_ATTEMPTS or status not in _TRANSIENT_STATUS:
            break
        if time.monotonic() - started >= RETRY_WHILE_FASTER_THAN:
            break
        log.info("openrouter %s on attempt %s, retrying", status, attempt)
    raise RuntimeError(f"openrouter {status}")


def _parse(content: str) -> list[dict]:
    """The model's offers list, fences tolerated — same indulgence the analyzer extends."""
    content = content.strip()
    if content.startswith("```"):
        content = content.split("\n", 1)[1].rsplit("```", 1)[0].strip()
    offers = json.loads(content).get("offers")
    if not isinstance(offers, list):
        raise ValueError("no offers list")
    return offers


def _clean(raw: dict) -> dict | None:
    """One validated offer, or None. A missing price is a dropped offer, not a guessed one —
    the same rule BuyPick.price lives by, one step downstream."""
    if not isinstance(raw, dict):
        return None
    merchant = str(raw.get("merchant") or "").strip()
    url = str(raw.get("url") or "").strip()
    price = str(raw.get("price") or "").strip()
    try:
        amount = float(raw.get("amount") or 0)
    except (TypeError, ValueError):
        return None
    parsed = urlparse(url)
    if not merchant or not price or amount <= 0:
        return None
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return None
    return {
        "merchant": merchant,
        "url": url,
        "price": price,
        "amount": amount,
        "currency": str(raw.get("currency") or "").strip().upper(),
        "isBrandSite": bool(raw.get("isBrandSite")),
    }


def _bare_host(url: str) -> str:
    host = (urlparse(url).hostname or "").lower()
    return host[4:] if host.startswith("www.") else host


def rank_offers(raw_offers: list[dict], storefront: str) -> list[dict]:
    """Up to MAX_OFFERS, in the order the buyer asked for: the country's Amazon pinned first
    whenever it has the item, the brand's own store when it doesn't, the rest cheapest-first,
    one offer per shop."""
    storefront_host = storefront[4:] if storefront.startswith("www.") else storefront
    kept: dict[str, dict] = {}
    for raw in raw_offers:
        offer = _clean(raw)
        if offer is None:
            continue
        host = _bare_host(offer["url"])
        path = urlparse(offer["url"]).path or ""
        if host.startswith("amazon.") or ".amazon." in f".{host}":
            # A search URL is the non-answer this route replaces; on Amazon it is detectable.
            if "/dp/" not in path and "/gp/product/" not in path:
                continue
            kind = "amazon" if host == storefront_host else "other"
        else:
            kind = "brand" if offer["isBrandSite"] else "other"
        entry = {"merchant": offer["merchant"], "url": offer["url"], "price": offer["price"],
                 "amount": offer["amount"], "currency": offer["currency"], "kind": kind}
        if host not in kept or entry["amount"] < kept[host]["amount"]:
            kept[host] = entry

    offers = sorted(kept.values(), key=lambda entry: entry["amount"])
    pinned = next((entry for entry in offers if entry["kind"] == "amazon"), None) \
        or next((entry for entry in offers if entry["kind"] == "brand"), None)
    if pinned:
        offers = [pinned] + [entry for entry in offers if entry is not pinned]
    return offers[:MAX_OFFERS]


# ---------------------------------------------------------------- picture

# The shop page's own product photo, read from its og:image tag. Fetched for at most this many
# offers per uncached lookup, brand site first; Amazon is skipped because it answers a bot with
# a captcha page and no og:image.
PAGE_TRIES = 2
PAGE_TIMEOUT = 10
_PAGE_HEADERS = {"User-Agent": (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.4 Safari/605.1.15")}
_META_TAG = re.compile(r"<meta\b[^>]*>", re.I)
_OG_IMAGE = re.compile(r"""\b(?:property|name)\s*=\s*["']og:image["']""", re.I)
_CONTENT = re.compile(r"""\bcontent\s*=\s*(?:"([^"]*)"|'([^']*)')""", re.I)


def _fetch_page(url: str) -> str:
    """The first 200 KB of the page — og:image lives in <head>, and a shop page runs megabytes."""
    response = requests.get(url, headers=_PAGE_HEADERS, timeout=PAGE_TIMEOUT, stream=True)
    response.raise_for_status()
    return response.raw.read(200_000, decode_content=True).decode("utf-8", "replace")


def og_image(html: str) -> str | None:
    """The page's og:image when it is an absolute http(s) URL, else None."""
    for tag in _META_TAG.findall(html):
        if not _OG_IMAGE.search(tag):
            continue
        match = _CONTENT.search(tag)
        if not match:
            continue
        url = unescape(match.group(1) or match.group(2) or "").strip()
        if urlparse(url).scheme in ("http", "https"):
            return url
    return None


def attach_picture(offers: list[dict]) -> None:
    """Put "imageURL" on the first offer whose page shows a product photo. Failures cost only
    the picture: an unreachable shop still keeps its price."""
    candidates = [entry for entry in offers if entry["kind"] != "amazon"]
    candidates.sort(key=lambda entry: entry["kind"] != "brand")
    for entry in candidates[:PAGE_TRIES]:
        try:
            image = og_image(_fetch_page(entry["url"]))
        except Exception as error:
            log.info("product page unread (%s): %s", entry["url"], error)
            continue
        if image:
            entry["imageURL"] = image
            return


# ---------------------------------------------------------------- cache + cap

def _cache_key(country: str, name: str) -> dict[str, str]:
    """Global, not per-user: a price is a fact about a shop, and one lookup should serve every
    account that saved the same viral thing. Hashed so a product name never becomes a key."""
    slug = " ".join(name.lower().split())
    digest = hashlib.sha256(f"{country}|{slug}".encode()).hexdigest()[:24]
    return {"PK": f"OFFERS#{digest}", "SK": "OFFERS"}


def _fresh(item: dict) -> bool:
    try:
        checked = datetime.fromisoformat(item["checkedAt"])
    except (KeyError, TypeError, ValueError):
        return False
    return datetime.now(timezone.utc) - checked < timedelta(hours=CACHE_HOURS)


def _offers_out(stored: list) -> list[dict]:
    """Dynamo hands numbers back as Decimal; the wire promises plain numbers."""
    return [{**offer, "amount": float(offer.get("amount", 0))} for offer in stored]


def _charge(store: DynamoImportStore) -> None:
    """Count one lookup against the caller's daily allowance, or 429.

    charge_deep_pass, re-played on its own counter: sharing DEEPPASS would let an evening of
    shopping starve the library backfill (and the reverse). Charged up front — the OpenRouter
    fee is spent whether or not the search finds anything.
    """
    cap = _daily_cap()
    key = {"PK": store.partition, "SK": "OFFERCAP"}
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    for _ in range(QUOTA_CAS_ATTEMPTS):
        item = store.table.get_item(Key=key).get("Item")
        used = int(item.get("usedToday", 0)) if item and item.get("utcDay") == today else 0
        if used >= cap:
            now = datetime.now(timezone.utc)
            midnight = (now + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
            raise HTTPException(
                status_code=429, detail="offer lookup daily cap reached",
                headers={"Retry-After": str(max(1, int((midnight - now).total_seconds())))})
        try:
            if item is None:
                store.table.put_item(
                    Item={**key, "utcDay": today, "usedToday": 1,
                          "updatedAt": datetime.now(timezone.utc).isoformat()},
                    ConditionExpression="attribute_not_exists(PK)",
                )
            else:
                store.table.update_item(
                    Key=key,
                    UpdateExpression="SET utcDay = :today, usedToday = :used, updatedAt = :now",
                    ConditionExpression="utcDay = :prevDay AND usedToday = :prevUsed",
                    ExpressionAttributeValues={
                        ":today": today, ":used": used + 1,
                        ":now": datetime.now(timezone.utc).isoformat(),
                        ":prevDay": item.get("utcDay"),
                        ":prevUsed": int(item.get("usedToday", 0)),
                    },
                )
        except Exception as error:
            if _is_conditional_failure(error):
                continue
            raise
        return
    raise RuntimeError("offer cap contention: compare-and-set did not settle")


# ---------------------------------------------------------------- the route

class OfferRequest(BaseModel):
    name: str
    kind: str = ""
    country: str = "LV"

    @field_validator("name")
    @classmethod
    def name_must_say_something(cls, value: str) -> str:
        value = value.strip()
        if not value or len(value) > 200:
            raise ValueError("name must be 1..200 characters")
        return value

    @field_validator("country")
    @classmethod
    def country_is_a_code(cls, value: str) -> str:
        value = value.strip().upper()
        if not re.fullmatch(r"[A-Z]{2}", value):
            raise ValueError("country must be a two-letter ISO code")
        return value


@router.post("/haul/offers")
def haul_offers(body: OfferRequest, store: DynamoImportStore = Depends(entitled_store)):
    """Up to three ranked offers for one pick, or an honest empty list.

    `entitled_store` rather than `user_store`: this reaches OpenRouter, so it is spending,
    and the subscription check is what stops a stranger signing in and spending it.
    """
    storefront = amazon_host(body.country)
    key = _cache_key(body.country, body.name)
    cached = store.table.get_item(Key=key).get("Item")
    if cached and _fresh(cached):
        return {"offers": _offers_out(cached.get("offers") or []),
                "checkedAt": cached["checkedAt"], "cached": True}

    _charge(store)  # 429 before spending OpenRouter money
    try:
        offers = rank_offers(_parse(_search(body.name, body.kind, body.country, storefront)),
                             storefront)
    except Exception as error:
        # The app shows its store-search fallback and tries again next open; a bad day at
        # OpenRouter costs this screen its prices and nothing else. Nothing is cached — a
        # failure must not become the day's answer.
        log.warning("offer lookup failed: %s", error)
        raise HTTPException(status_code=502, detail="offers unavailable")
    attach_picture(offers)

    checked_at = datetime.now(timezone.utc).isoformat()
    # An empty answer is cached too: "nobody ships this here" is a day's worth of true, and
    # re-asking on every open would spend the cap proving it.
    store.table.put_item(Item={**key, "offers": _dynamo_value(offers), "checkedAt": checked_at})
    return {"offers": offers, "checkedAt": checked_at, "cached": False}
