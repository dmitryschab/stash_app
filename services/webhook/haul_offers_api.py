"""Stash /v1 haul offers — where a pick can actually be bought, priced for the buyer's country.

  POST /v1/haul/offers  {name, kind, country} -> {offers: [...], checkedAt, cached}
  Dead shop links are dropped before caching; one survivor may carry imageURL,
  the shop page's og:image, which becomes the pick's catalog photo.
  POST /v1/haul/photo   {name, kind, link} -> {imageURL, cached}
  The same catalog photo without the prices: a keyless web search, then og:image.

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
per uncached lookup, nearly all of it the web plugin's per-request fee.

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
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from html import unescape
from urllib.parse import parse_qs, unquote, urlparse

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
# Measured 2026-09-16 on ten real picks, same prompt and search: gemini-3.7-flash took 53s
# (31s median in production, over half its calls upstream-throttled) with 26% of its links
# dead; mercury-2.5 took 4.6s with 7% dead and a right link for every pick, at the same
# ~$0.007 a lookup. Low reasoning: default reasoning was slower and found fewer Amazon listings.
OFFERS_MODEL = "inception/mercury-2.5"
OFFERS_REASONING = {"effort": "low"}
# Reasoning tokens count against this cap. At 1200 a thinking model spent all of it thinking
# and returned an empty answer; six offers of one JSON line each need ~300 more.
OFFERS_MAX_OUTPUT_TOKENS = 4000
SEARCH_MAX_RESULTS = 8
SEARCH_TIMEOUT = 90

# Measured against the live box: a 504 here is almost always an upstream provider 429 that
# clears immediately, and it comes back fast (~11s) while a real answer took 33-69s on Gemini. So one
# retry is worth taking, but only when the first failure was quick enough to leave room for it
# — a slow failure means the app is already near its own 100s timeout, and a second attempt
# would only make it wait longer for the same 502. When the app does give up, this request
# still finishes and caches, so the user's next open is an instant hit.
SEARCH_ATTEMPTS = 2
RETRY_WHILE_FASTER_THAN = 25.0
_TRANSIENT_STATUS = {408, 429, 500, 502, 503, 504}

MAX_OFFERS = 3
CACHE_HOURS = 24
# A catalog photo outlives a price: shops reshoot a product about never. A month also keeps the
# photo route free even while an answer sits behind a shop that has started refusing bots.
PHOTO_CACHE_HOURS = 24 * 30
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
        "reasoning": OFFERS_REASONING,
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

# Every non-Amazon offer's page is fetched once: it proves the link is real and it carries the
# product photo in its og:image tag. Amazon is skipped because it answers a bot with a captcha
# page, so a fetch would prove nothing about the listing.
PAGE_TIMEOUT = 10
# Only these prove the page is not there. A 403 is a bot check, which Aesop answers with; a 5xx
# is the shop having a bad minute; a transport error proves nothing at all. None of those are
# grounds to throw away what may be a real shop.
_PAGE_GONE = {404, 410}
_PAGE_HEADERS = {"User-Agent": (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.4 Safari/605.1.15")}
_META_TAG = re.compile(r"<meta\b[^>]*>", re.I)
_OG_IMAGE = re.compile(r"""\b(?:property|name)\s*=\s*["']og:image["']""", re.I)
_CONTENT = re.compile(r"""\bcontent\s*=\s*(?:"([^"]*)"|'([^']*)')""", re.I)


def _fetch_page(url: str) -> tuple[int, str]:
    """(status, first 200 KB of the body) — og:image lives in <head> and a shop page runs
    megabytes. Raises only when the shop could not be reached at all."""
    response = requests.get(url, headers=_PAGE_HEADERS, timeout=PAGE_TIMEOUT, stream=True)
    if response.status_code != 200:
        response.close()
        return response.status_code, ""
    return 200, response.raw.read(200_000, decode_content=True).decode("utf-8", "replace")


def _page(url: str) -> tuple[int | None, str]:
    """_fetch_page with an unreachable shop reported as (None, "") instead of raised."""
    try:
        return _fetch_page(url)
    except Exception as error:
        log.info("product page unread (%s): %s", url, error)
        return None, ""


# Measured on live shops: logitech.com serves "logitech-global-og-image.png" — the company
# logo on a green card — as the og:image of every page it has. A brand card under a product
# name is a wrong picture, which is worse than the video's own frame, so these never pass.
_GENERIC_IMAGE = ("og-image", "og_image", "ogimage", "logo", "social", "share",
                  "default", "placeholder", "banner")
_JSON_LD_IMAGE = re.compile(r'"image"\s*:\s*(?:\[\s*)?"(https?://[^"]+)"', re.I)


def og_image(html: str) -> str | None:
    """The page's og:image when it is an absolute http(s) URL and shows a product, else None."""
    for tag in _META_TAG.findall(html):
        if not _OG_IMAGE.search(tag):
            continue
        match = _CONTENT.search(tag)
        if not match:
            continue
        url = unescape(match.group(1) or match.group(2) or "").strip()
        if _shows_a_product(url):
            return url
        log.info("skipping generic og:image %s", url)
    # Shops that hand every page the same brand card still describe the product properly in
    # their schema.org block, and its "image" is the catalog shot.
    for url in _JSON_LD_IMAGE.findall(html):
        if _shows_a_product(url):
            return url
    return None


def _shows_a_product(url: str) -> bool:
    if urlparse(url).scheme not in ("http", "https"):
        return False
    file = urlparse(url).path.rsplit("/", 1)[-1].lower()
    return not any(word in file for word in _GENERIC_IMAGE)


DDG_URL = "https://html.duckduckgo.com/html/"
# The shops whose page is a bot check, a feed or a marketplace listing of somebody's used one:
# none of them hands back the catalog photo the product's own seller publishes.
_NOT_A_CATALOG = ("amazon.", "tiktok.com", "instagram.", "facebook.", "youtube.", "pinterest.",
                  "ebay.", "aliexpress.", "reddit.com", "wikipedia.org")
_DDG_LINK = re.compile(r'<a[^>]+class="result__a"[^>]+href="([^"]+)"', re.I)
# The page has to be the thing's own listing. Measured live: without this, "Logitech MX Master
# 3S" settled on hub.sync.logitech.com and its "Welcome to Logitech Hub" banner — a wrong
# picture, which the frame from the video beats.
_PRODUCT_PATH = ("/product/", "/products/", "/p/", "/dp/", "/shop/", "/item/")


def shop_pages(name: str, kind: str, limit: int = 3) -> list[str]:
    """The first few product pages a plain web search finds for the pick, best first.

    DuckDuckGo's HTML endpoint, because it needs no key and no account: this lookup must keep
    working on the day OpenRouter does not. A blocked or changed page yields no links, which
    costs the pick its photo and nothing else.
    """
    query = " ".join(part for part in (name, kind) if part)
    try:
        response = requests.get(DDG_URL, params={"q": query}, headers=_PAGE_HEADERS,
                                timeout=PAGE_TIMEOUT)
        html = response.text if response.status_code == 200 else ""
    except Exception as error:
        log.info("photo search unread (%s): %s", query, error)
        return []

    pages: list[str] = []
    for href in _DDG_LINK.findall(html):
        url = unescape(href)
        # DDG wraps results as /l/?uddg=<encoded>; older layouts link straight out.
        if "uddg=" in url:
            url = unquote(parse_qs(urlparse(url).query).get("uddg", [""])[0])
        if url.startswith("//"):
            url = "https:" + url
        host = (urlparse(url).hostname or "").lower()
        if urlparse(url).scheme not in ("http", "https") or not host:
            continue
        if any(skip in host for skip in _NOT_A_CATALOG) or url in pages:
            continue
        if not any(part in urlparse(url).path.lower() for part in _PRODUCT_PATH):
            continue  # a review, a hub, a category: pages that picture something else
        pages.append(url)
        if len(pages) == limit:
            break
    return pages


def product_photo(name: str, kind: str = "", link: str | None = None) -> str | None:
    """The product's own catalog photo, from the first page that publishes one.

    The video's own link leads when it has one — a creator linking the product links the seller
    — and a web search supplies the rest. Same og:image reader the offers path uses, so a pick
    gets the same picture whether its prices answered or not.
    """
    if link:
        status, html = _page(link)
        if status == 200 and (image := og_image(html)):
            return image  # a linked seller answers before any search is run
    for url in shop_pages(name, kind):
        if url == link:
            continue
        status, html = _page(url)
        if status != 200 or not page_is_about(name, html):
            continue
        if image := og_image(html):
            return image
    return None


_TITLE = re.compile(r"<title[^>]*>(.*?)</title>", re.I | re.S)
_OG_TITLE = re.compile(r"""\b(?:property|name)\s*=\s*["']og:title["']""", re.I)
# PickFrames.matchFloor, replayed: a page has to carry three quarters of the pick's words
# before its picture may claim to be the pick. Measured live, this is what separates
# keychron.com's K3 listing from a lamp shop that merely sells something called Umbra.
NAME_MATCH_FLOOR = 0.75


def page_is_about(name: str, html: str) -> bool:
    """Does this page's own title name the product the pick names?

    The search will answer something for any words at all: "Umbra desk lamp" found a Czech shop
    selling a different brand's Umbra table lamp, and its photo would have sat on the pick page
    as if it were the thing. A wrong picture is worse than the video's own frame.
    """
    wanted = _words(name)
    if not wanted:
        return False
    titles = [unescape(match) for match in _TITLE.findall(html)]
    for tag in _META_TAG.findall(html):
        if _OG_TITLE.search(tag) and (match := _CONTENT.search(tag)):
            titles.append(unescape(match.group(1) or match.group(2) or ""))
    for title in titles:
        present = set(_words(title))
        if sum(word in present for word in wanted) / len(wanted) >= NAME_MATCH_FLOOR:
            return True
    return False


def _words(text: str) -> list[str]:
    """Lowercased alphanumeric runs, accents folded — "SKÅDIS" and "skadis" are one word."""
    folded = unicodedata.normalize("NFKD", text.lower())
    stripped = "".join(char for char in folded if not unicodedata.combining(char))
    return [word for word in re.split(r"[^a-z0-9]+", stripped) if word]


def verify_offers(offers: list[dict]) -> list[dict]:
    """Drop offers whose product page is definitively gone, and put "imageURL" on the first
    survivor whose page shows a product photo.

    The model invents plausible product URLs: measured against the live box, most non-Amazon
    links answered 404, and small models make up Amazon ASINs, which amazon.de answers with a
    404 too (a bot check is a 503, so a real listing still survives). A dead link is worse than no link on a card whose whole job is telling
    someone where to buy. Every shop is checked at once rather than in turn, because the search
    ahead of this already spends most of the app's timeout budget.
    """
    if not offers:
        return offers
    urls = [entry["url"] for entry in offers]
    with ThreadPoolExecutor(max_workers=len(urls)) as pool:
        pages = dict(zip(urls, pool.map(_page, urls)))

    kept = []
    for entry in offers:
        status = pages.get(entry["url"], (None, ""))[0]
        if status in _PAGE_GONE:
            log.info("dropping dead offer %s (%s)", entry["url"], status)
            continue
        kept.append(entry)

    # Brand site first for the photo, but a dead or pictureless one must not stop a live shop
    # further down the list from supplying it.
    # Amazon's page is checked for existence only; its photo was never the one this card used.
    for entry in sorted((e for e in kept if e["kind"] != "amazon"), key=lambda e: e["kind"] != "brand"):
        status, html = pages.get(entry["url"], (None, ""))
        if status == 200 and (image := og_image(html)):
            entry["imageURL"] = image
            break
    return kept


# ---------------------------------------------------------------- cache + cap

def _cache_key(country: str, name: str) -> dict[str, str]:
    """Global, not per-user: a price is a fact about a shop, and one lookup should serve every
    account that saved the same viral thing. Hashed so a product name never becomes a key."""
    slug = " ".join(name.lower().split())
    digest = hashlib.sha256(f"{country}|{slug}".encode()).hexdigest()[:24]
    return {"PK": f"OFFERS#{digest}", "SK": "OFFERS"}


def _photo_key(name: str) -> dict[str, str]:
    """No country in the key: a shop's catalog photo of a product is the same picture in every
    country, so one lookup serves every buyer who saved it."""
    slug = " ".join(name.lower().split())
    digest = hashlib.sha256(f"photo|{slug}".encode()).hexdigest()[:24]
    return {"PK": f"PHOTO#{digest}", "SK": "PHOTO"}


def _fresh(item: dict, hours: int = CACHE_HOURS) -> bool:
    try:
        checked = datetime.fromisoformat(item["checkedAt"])
    except (KeyError, TypeError, ValueError):
        return False
    return datetime.now(timezone.utc) - checked < timedelta(hours=hours)


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
    offers = verify_offers(offers)

    checked_at = datetime.now(timezone.utc).isoformat()
    # An empty answer is cached too: "nobody ships this here" is a day's worth of true, and
    # re-asking on every open would spend the cap proving it.
    store.table.put_item(Item={**key, "offers": _dynamo_value(offers), "checkedAt": checked_at})
    return {"offers": offers, "checkedAt": checked_at, "cached": False}


class PhotoRequest(BaseModel):
    name: str
    kind: str = ""
    # The link the video itself gave, when it gave one. Checked before any search.
    link: str | None = None

    @field_validator("name")
    @classmethod
    def name_must_say_something(cls, value: str) -> str:
        value = value.strip()
        if not value or len(value) > 200:
            raise ValueError("name must be 1..200 characters")
        return value

    @field_validator("link")
    @classmethod
    def link_is_a_web_address(cls, value: str | None) -> str | None:
        if not value:
            return None
        return value if urlparse(value).scheme in ("http", "https") else None


@router.post("/haul/photo")
def haul_photo(body: PhotoRequest, store: DynamoImportStore = Depends(entitled_store)):
    """The pick's catalog photo — the seller's own product shot — or null.

    Deliberately not part of /haul/offers: a picture must not depend on a price search that has
    a bad day, which is the whole reason a pick was still wearing a frame of the video. No
    quota moves, because no model runs here: this is a search page and at most three HEAD-sized
    reads. A miss is cached too, so a product nobody photographs is asked about once a month.
    """
    key = _photo_key(body.name)
    cached = store.table.get_item(Key=key).get("Item")
    if cached and _fresh(cached, hours=PHOTO_CACHE_HOURS):
        return {"imageURL": cached.get("imageURL") or None, "cached": True}

    image = product_photo(body.name, body.kind, body.link)
    checked_at = datetime.now(timezone.utc).isoformat()
    store.table.put_item(Item={**key, "imageURL": image or "", "checkedAt": checked_at})
    return {"imageURL": image, "cached": False}
