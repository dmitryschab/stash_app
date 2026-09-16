"""The offers route: where a pick can actually be bought, ranked for the buyer's country.

The ranking is the contract. The buyer told us their priorities outright: the country's own
Amazon storefront is always slot one when it stocks the item, the maker's own store leads when
Amazon doesn't, and everything else competes on price. A search URL is never an offer — the
whole feature exists because "Search Amazon" was the disaster it replaced — so an offer must
point at a concrete product page or it is dropped.

Money-wise this is a deep-pass sibling: no quota moves, a per-user per-UTC-day cap bounds the
spend, and a day-long cache means one lookup serves every user who saved the same product.
"""

import json

import pytest
from fastapi.testclient import TestClient

import haul_offers_api
import stash_auth
from app import app
from cloud_import_models import INITIAL_LIMIT
from cloud_import_store import DynamoImportStore
from conftest import ConditionalTable


@pytest.fixture
def table():
    return ConditionalTable()


@pytest.fixture
def store(table):
    subject = DynamoImportStore(table=table, user_id="user-a")
    app.dependency_overrides[stash_auth.current_user] = lambda: "user-a"
    app.dependency_overrides[stash_auth.entitled_store] = lambda: subject
    yield subject
    app.dependency_overrides.clear()


@pytest.fixture
def provider(monkeypatch):
    """Stand in for the OpenRouter search call, recording what it was asked."""
    state = {"content": json.dumps({"offers": []}), "calls": []}

    def search(name, kind, country, amazon_host):
        state["calls"].append({"name": name, "kind": kind, "country": country,
                               "amazonHost": amazon_host})
        result = state["content"]
        if isinstance(result, Exception):
            raise result
        return result

    monkeypatch.setattr(haul_offers_api, "_search", search)
    return state



@pytest.fixture(autouse=True)
def pages(monkeypatch):
    """Stand in for the product-page fetch behind the picture: url -> html, or an exception.
    Autouse, so no test ever reaches a real shop; an unknown page fails like an unreachable one."""
    state = {"pages": {}, "fetched": []}

    def fetch(url):
        state["fetched"].append(url)
        page = state["pages"].get(url)
        if page is None:
            raise RuntimeError("unreachable page")
        if isinstance(page, Exception):
            raise page
        return page if isinstance(page, tuple) else (200, page)

    monkeypatch.setattr(haul_offers_api, "_fetch_page", fetch)
    return state


def og_page(image):
    return f'<html><head><meta property="og:image" content="{image}"></head><body></body></html>'


def refuse(monkeypatch):
    monkeypatch.setattr(haul_offers_api, "_search",
                        lambda *args: pytest.fail("the provider was called for a refused request"))


def offer(merchant, url, amount, *, currency="EUR", brand=False, price=None):
    return {"merchant": merchant, "url": url, "amount": amount,
            "price": price or f"€{amount}", "currency": currency, "isBrandSite": brand}


def lookup(client, name="Logitech MX Master 4", country="LV", kind="mouse"):
    return client.post("/v1/haul/offers", json={"name": name, "kind": kind, "country": country})


# ------------------------------------------------------------------ ranking


def test_amazon_is_pinned_first_even_when_pricier(store, provider):
    provider["content"] = json.dumps({"offers": [
        offer("1a.lv", "https://www.1a.lv/p/mx-master-4", 79.0),
        offer("Amazon.de", "https://www.amazon.de/dp/B0ABC12345", 94.99),
        offer("Logitech", "https://www.logitech.com/products/mx-master-4", 89.0, brand=True),
    ]})
    with TestClient(app) as client:
        body = lookup(client).json()

    assert [entry["merchant"] for entry in body["offers"]] == ["Amazon.de", "1a.lv", "Logitech"]
    assert [entry["kind"] for entry in body["offers"]] == ["amazon", "other", "brand"]
    assert body["offers"][0]["amount"] == 94.99


def test_without_amazon_the_brand_site_leads(store, provider):
    provider["content"] = json.dumps({"offers": [
        offer("220.lv", "https://220.lv/p/thing", 30.0),
        offer("Satechi", "https://satechi.net/products/thing", 40.0, brand=True),
        offer("1a.lv", "https://www.1a.lv/p/thing", 35.0),
    ]})
    with TestClient(app) as client:
        body = lookup(client).json()

    assert [entry["merchant"] for entry in body["offers"]] == ["Satechi", "220.lv", "1a.lv"]
    assert [entry["kind"] for entry in body["offers"]] == ["brand", "other", "other"]


def test_without_amazon_or_brand_the_cheapest_wins_and_three_is_the_cap(store, provider):
    provider["content"] = json.dumps({"offers": [
        offer("Shop D", "https://shop-d.example/p/1", 44.0),
        offer("Shop A", "https://shop-a.example/p/1", 31.0),
        offer("Shop C", "https://shop-c.example/p/1", 39.0),
        offer("Shop B", "https://shop-b.example/p/1", 35.0),
    ]})
    with TestClient(app) as client:
        body = lookup(client).json()

    assert [entry["amount"] for entry in body["offers"]] == [31.0, 35.0, 39.0]


def test_an_amazon_search_url_is_not_an_offer(store, provider):
    """A search-results link is exactly the non-answer this feature replaces."""
    provider["content"] = json.dumps({"offers": [
        offer("Amazon.de", "https://www.amazon.de/s?k=mx+master+4", 94.99),
        offer("1a.lv", "https://www.1a.lv/p/mx-master-4", 99.0),
    ]})
    with TestClient(app) as client:
        body = lookup(client).json()

    assert [entry["merchant"] for entry in body["offers"]] == ["1a.lv"]


def test_a_foreign_amazon_storefront_is_not_the_pin(store, provider):
    """amazon.com does not ship to a Latvian buyer the way amazon.de does; it competes on
    price like any other shop instead of taking the reserved slot."""
    provider["content"] = json.dumps({"offers": [
        offer("Amazon.com", "https://www.amazon.com/dp/B0ABC12345", 60.0),
        offer("1a.lv", "https://www.1a.lv/p/mx-master-4", 80.0),
    ]})
    with TestClient(app) as client:
        body = lookup(client).json()

    assert [entry["kind"] for entry in body["offers"]] == ["other", "other"]
    assert body["offers"][0]["merchant"] == "Amazon.com"  # cheapest first, no pin


def test_two_offers_from_one_shop_keep_only_the_cheaper(store, provider):
    provider["content"] = json.dumps({"offers": [
        offer("1a.lv", "https://www.1a.lv/p/bundle", 99.0),
        offer("1a.lv", "https://www.1a.lv/p/solo", 79.0),
    ]})
    with TestClient(app) as client:
        body = lookup(client).json()

    assert [entry["amount"] for entry in body["offers"]] == [79.0]


def test_an_offer_without_a_usable_price_or_url_is_dropped(store, provider):
    provider["content"] = json.dumps({"offers": [
        {"merchant": "Priceless", "url": "https://shop.example/p/1", "price": "", "amount": 0,
         "currency": "EUR", "isBrandSite": False},
        {"merchant": "Linkless", "url": "not-a-url", "price": "€10", "amount": 10,
         "currency": "EUR", "isBrandSite": False},
        offer("Kept", "https://kept.example/p/1", 12.0),
    ]})
    with TestClient(app) as client:
        body = lookup(client).json()

    assert [entry["merchant"] for entry in body["offers"]] == ["Kept"]


def test_no_offers_is_an_honest_200(store, provider):
    with TestClient(app) as client:
        response = lookup(client)

    assert response.status_code == 200
    assert response.json()["offers"] == []


# ------------------------------------------------------------------ cache


def test_the_answer_is_cached_for_a_day(store, provider):
    provider["content"] = json.dumps({"offers": [
        offer("Amazon.de", "https://www.amazon.de/dp/B0ABC12345", 94.99)]})
    with TestClient(app) as client:
        first = lookup(client).json()
        second = lookup(client).json()

    assert len(provider["calls"]) == 1
    assert first["cached"] is False
    assert second["cached"] is True
    assert second["offers"] == first["offers"]


def test_a_stale_cache_is_refreshed(store, table, provider):
    key = haul_offers_api._cache_key("LV", "Logitech MX Master 4")
    table.items[(key["PK"], key["SK"])] = {
        **key, "offers": [], "checkedAt": "2020-01-01T00:00:00+00:00"}
    provider["content"] = json.dumps({"offers": [
        offer("Amazon.de", "https://www.amazon.de/dp/B0ABC12345", 94.99)]})

    with TestClient(app) as client:
        body = lookup(client).json()

    assert len(provider["calls"]) == 1
    assert body["offers"][0]["merchant"] == "Amazon.de"


def test_countries_do_not_share_a_cache(store, provider):
    with TestClient(app) as client:
        lookup(client, country="LV")
        lookup(client, country="DE")

    assert [call["country"] for call in provider["calls"]] == ["LV", "DE"]
    assert provider["calls"][0]["amazonHost"] == provider["calls"][1]["amazonHost"] == "www.amazon.de"


def test_the_united_states_gets_its_own_storefront(store, provider):
    with TestClient(app) as client:
        lookup(client, country="US")

    assert provider["calls"][0]["amazonHost"] == "www.amazon.com"


# ------------------------------------------------------------------ money


def test_the_daily_cap_refuses_with_retry_after(store, provider, monkeypatch):
    monkeypatch.setenv("OFFER_DAILY_CAP", "1")
    with TestClient(app) as client:
        assert lookup(client, name="First Product").status_code == 200
        refused = lookup(client, name="Second Product")

    assert refused.status_code == 429
    assert int(refused.headers["Retry-After"]) > 0
    assert len(provider["calls"]) == 1


def test_a_cache_hit_costs_nothing_against_the_cap(store, provider, monkeypatch):
    monkeypatch.setenv("OFFER_DAILY_CAP", "1")
    with TestClient(app) as client:
        assert lookup(client).status_code == 200
        again = lookup(client)

    assert again.status_code == 200
    assert again.json()["cached"] is True


def test_the_lookup_costs_no_quota(store, provider):
    with TestClient(app) as client:
        assert lookup(client).status_code == 200
    assert store.get_quota().initial_remaining == INITIAL_LIMIT


def test_a_caller_without_a_session_is_refused():
    with TestClient(app) as client:
        response = client.post("/v1/haul/offers", json={"name": "x", "country": "LV"})
    assert response.status_code == 401


# ------------------------------------------------------------------ provider failure


def test_a_provider_failure_is_a_502(store, provider):
    provider["content"] = RuntimeError("openrouter said no")
    with TestClient(app) as client:
        assert lookup(client).status_code == 502


def test_malformed_provider_json_is_a_502(store, provider):
    provider["content"] = "I could not find any shops, sorry!"
    with TestClient(app) as client:
        assert lookup(client).status_code == 502


def test_code_fences_around_the_json_are_tolerated(store, provider):
    payload = json.dumps({"offers": [offer("Kept", "https://kept.example/p/1", 12.0)]})
    provider["content"] = f"```json\n{payload}\n```"
    with TestClient(app) as client:
        body = lookup(client).json()

    assert [entry["merchant"] for entry in body["offers"]] == ["Kept"]


def test_a_failed_lookup_is_not_cached(store, provider):
    provider["content"] = RuntimeError("openrouter said no")
    with TestClient(app) as client:
        assert lookup(client).status_code == 502
        provider["content"] = json.dumps({"offers": [
            offer("Amazon.de", "https://www.amazon.de/dp/B0ABC12345", 94.99)]})
        recovered = lookup(client).json()

    assert recovered["offers"][0]["merchant"] == "Amazon.de"



# ------------------------------------------------------------------ picture

BRAND = "https://www.logitech.com/products/mx-master-4"
OTHER = "https://www.1a.lv/p/mx-master-4"
AMAZON = "https://www.amazon.de/dp/B0ABC12345"


def test_the_brand_pages_og_image_rides_on_its_offer(store, provider, pages):
    provider["content"] = json.dumps({"offers": [
        offer("Amazon.de", AMAZON, 94.99), offer("Logitech", BRAND, 99.0, brand=True)]})
    pages["pages"][BRAND] = og_page("https://cdn.logitech.com/mx-master-4.png")

    with TestClient(app) as client:
        body = lookup(client).json()

    by_merchant = {entry["merchant"]: entry for entry in body["offers"]}
    assert by_merchant["Logitech"]["imageURL"] == "https://cdn.logitech.com/mx-master-4.png"
    assert "imageURL" not in by_merchant["Amazon.de"]
    # Amazon answers bots with a captcha page, so it is never asked.
    assert pages["fetched"] == [BRAND]


def test_a_brand_page_without_a_picture_falls_through_to_the_next_shop(store, provider, pages):
    provider["content"] = json.dumps({"offers": [
        offer("Logitech", BRAND, 99.0, brand=True), offer("1a.lv", OTHER, 96.9)]})
    pages["pages"][BRAND] = "<html><head><title>Logitech</title></head></html>"
    pages["pages"][OTHER] = og_page("https://img.1a.lv/mx.jpg")

    with TestClient(app) as client:
        body = lookup(client).json()

    by_merchant = {entry["merchant"]: entry for entry in body["offers"]}
    assert "imageURL" not in by_merchant["Logitech"]
    assert by_merchant["1a.lv"]["imageURL"] == "https://img.1a.lv/mx.jpg"
    assert sorted(pages["fetched"]) == sorted([BRAND, OTHER])


def test_a_page_failure_costs_only_the_picture(store, provider, pages):
    provider["content"] = json.dumps({"offers": [offer("Logitech", BRAND, 99.0, brand=True)]})
    pages["pages"][BRAND] = RuntimeError("connection reset")

    with TestClient(app) as client:
        response = lookup(client)

    assert response.status_code == 200
    assert [entry["merchant"] for entry in response.json()["offers"]] == ["Logitech"]
    assert "imageURL" not in response.json()["offers"][0]


def test_the_picture_is_cached_with_the_offers(store, provider, pages):
    provider["content"] = json.dumps({"offers": [offer("Logitech", BRAND, 99.0, brand=True)]})
    pages["pages"][BRAND] = og_page("https://cdn.logitech.com/mx-master-4.png")

    with TestClient(app) as client:
        lookup(client)
        second = lookup(client).json()

    assert second["cached"] is True
    assert second["offers"][0]["imageURL"] == "https://cdn.logitech.com/mx-master-4.png"
    assert pages["fetched"] == [BRAND]


def test_og_image_reads_either_attribute_order_and_unescapes():
    html = """<head>
      <meta content="https://x.example/a.jpg?w=1&amp;h=2" property='og:image' />
      <meta property="og:image" content="https://x.example/b.jpg">
    </head>"""
    assert haul_offers_api.og_image(html) == "https://x.example/a.jpg?w=1&h=2"
    assert haul_offers_api.og_image('<meta property="og:image" content="/relative.jpg">') is None
    assert haul_offers_api.og_image("<head></head>") is None




# ------------------------------------------------------------------ dead links


def test_an_offer_whose_page_is_gone_is_dropped(store, provider, pages):
    # Measured on the live box: the model invents plausible product URLs that 404, and the
    # pick page was sending buyers to them.
    provider["content"] = json.dumps({"offers": [
        offer("Logitech", BRAND, 99.0, brand=True), offer("1a.lv", OTHER, 96.9)]})
    pages["pages"][BRAND] = (404, "")
    pages["pages"][OTHER] = og_page("https://img.1a.lv/mx.jpg")

    with TestClient(app) as client:
        body = lookup(client).json()

    assert [entry["merchant"] for entry in body["offers"]] == ["1a.lv"]
    assert body["offers"][0]["imageURL"] == "https://img.1a.lv/mx.jpg"


def test_a_bot_blocked_shop_keeps_its_offer(store, provider, pages):
    # Aesop answers a server fetch with 403. That is not proof the product page is missing,
    # and dropping it would lose a real shop over a bot check.
    provider["content"] = json.dumps({"offers": [offer("Aesop", BRAND, 99.0, brand=True)]})
    pages["pages"][BRAND] = (403, "")

    with TestClient(app) as client:
        body = lookup(client).json()

    assert [entry["merchant"] for entry in body["offers"]] == ["Aesop"]
    assert "imageURL" not in body["offers"][0]


def test_an_unreachable_shop_keeps_its_offer(store, provider, pages):
    provider["content"] = json.dumps({"offers": [offer("Logitech", BRAND, 99.0, brand=True)]})
    pages["pages"][BRAND] = RuntimeError("connection reset")

    with TestClient(app) as client:
        body = lookup(client).json()

    assert [entry["merchant"] for entry in body["offers"]] == ["Logitech"]


def test_a_server_error_at_the_shop_keeps_its_offer(store, provider, pages):
    provider["content"] = json.dumps({"offers": [offer("Logitech", BRAND, 99.0, brand=True)]})
    pages["pages"][BRAND] = (503, "")

    with TestClient(app) as client:
        body = lookup(client).json()

    assert [entry["merchant"] for entry in body["offers"]] == ["Logitech"]


def test_amazon_is_never_fetched_and_always_survives(store, provider, pages):
    provider["content"] = json.dumps({"offers": [
        offer("Amazon.de", AMAZON, 94.99), offer("1a.lv", OTHER, 96.9)]})
    pages["pages"][OTHER] = (404, "")

    with TestClient(app) as client:
        body = lookup(client).json()

    assert [entry["merchant"] for entry in body["offers"]] == ["Amazon.de"]
    assert pages["fetched"] == [OTHER]


def test_every_shop_dead_is_an_empty_answer(store, provider, pages):
    provider["content"] = json.dumps({"offers": [
        offer("Logitech", BRAND, 99.0, brand=True), offer("1a.lv", OTHER, 96.9)]})
    pages["pages"][BRAND] = (404, "")
    pages["pages"][OTHER] = (410, "")

    with TestClient(app) as client:
        body = lookup(client).json()

    assert body["offers"] == []


def test_each_shop_is_checked_exactly_once(store, provider, pages):
    provider["content"] = json.dumps({"offers": [
        offer("Logitech", BRAND, 99.0, brand=True), offer("1a.lv", OTHER, 96.9),
        offer("Amazon.de", AMAZON, 94.99)]})
    pages["pages"][BRAND] = og_page("https://cdn.logitech.com/mx.png")
    pages["pages"][OTHER] = og_page("https://img.1a.lv/mx.jpg")

    with TestClient(app) as client:
        lookup(client)

    assert sorted(pages["fetched"]) == sorted([BRAND, OTHER])


def test_a_dead_brand_page_does_not_steal_the_picture(store, provider, pages):
    # The brand site is asked first for the photo, but a 404 there must not stop a live shop
    # further down the list from supplying one.
    provider["content"] = json.dumps({"offers": [
        offer("Logitech", BRAND, 99.0, brand=True), offer("1a.lv", OTHER, 96.9)]})
    pages["pages"][BRAND] = (404, "")
    pages["pages"][OTHER] = og_page("https://img.1a.lv/mx.jpg")

    with TestClient(app) as client:
        body = lookup(client).json()

    assert body["offers"][0]["imageURL"] == "https://img.1a.lv/mx.jpg"


# ------------------------------------------------------------------ search retry


class FakePost:
    """Stands in for requests.post, answering a scripted sequence of statuses."""

    def __init__(self, *statuses, elapsed=0.0):
        self.statuses = list(statuses)
        self.calls = 0
        self.elapsed = elapsed   # seconds each attempt appears to take

    def __call__(self, *args, **kwargs):
        self.calls += 1
        status = self.statuses[min(self.calls - 1, len(self.statuses) - 1)]
        return FakeResponse(status)


class FakeResponse:
    def __init__(self, status):
        self.status_code = status

    def json(self):
        payload = json.dumps({"offers": [
            {"merchant": "Logitech", "url": "https://logi.example/p/mx", "price": "€99",
             "amount": 99.0, "currency": "EUR", "isBrandSite": True}]})
        return {"choices": [{"message": {"content": payload}}]}


def with_key(monkeypatch):
    """The real _search runs in these tests, and it refuses without a configured key."""
    monkeypatch.setattr(haul_offers_api.stash_secrets, "secret",
                        lambda name: "sk-test" if name == "OPENROUTER_API_KEY" else "")


def fake_clock(monkeypatch, per_attempt):
    """Make each attempt appear to take `per_attempt` seconds."""
    ticks = {"now": 0.0}

    def monotonic():
        value = ticks["now"]
        ticks["now"] += per_attempt
        return value

    monkeypatch.setattr(haul_offers_api.time, "monotonic", monotonic)


def test_a_fast_504_is_retried_and_the_second_answer_is_used(store, monkeypatch):
    with_key(monkeypatch)
    post = FakePost(504, 200)
    monkeypatch.setattr(haul_offers_api.requests, "post", post)
    fake_clock(monkeypatch, 11.0)   # a 504 comes back fast, as measured against the live box

    with TestClient(app) as client:
        response = lookup(client)

    assert response.status_code == 200
    assert post.calls == 2
    assert [entry["merchant"] for entry in response.json()["offers"]] == ["Logitech"]


def test_a_permanent_400_is_not_retried(store, monkeypatch):
    with_key(monkeypatch)
    post = FakePost(400)
    monkeypatch.setattr(haul_offers_api.requests, "post", post)
    fake_clock(monkeypatch, 1.0)

    with TestClient(app) as client:
        assert lookup(client).status_code == 502
    assert post.calls == 1


def test_a_slow_failure_is_not_retried(store, monkeypatch):
    # A 504 that took most of the caller's budget leaves no room for a second attempt, which
    # would only make the app wait longer for the same 502.
    with_key(monkeypatch)
    post = FakePost(504, 200)
    monkeypatch.setattr(haul_offers_api.requests, "post", post)
    fake_clock(monkeypatch, 60.0)

    with TestClient(app) as client:
        assert lookup(client).status_code == 502
    assert post.calls == 1


def test_retrying_stops_after_the_attempt_limit(store, monkeypatch):
    with_key(monkeypatch)
    post = FakePost(504)
    monkeypatch.setattr(haul_offers_api.requests, "post", post)
    fake_clock(monkeypatch, 1.0)

    with TestClient(app) as client:
        assert lookup(client).status_code == 502
    assert post.calls == haul_offers_api.SEARCH_ATTEMPTS


# ------------------------------------------------------------------ input


def test_a_blank_name_is_refused(store, monkeypatch):
    refuse(monkeypatch)
    with TestClient(app) as client:
        response = client.post("/v1/haul/offers", json={"name": "   ", "country": "LV"})
    assert response.status_code == 422


def test_a_bad_country_code_is_refused(store, monkeypatch):
    refuse(monkeypatch)
    with TestClient(app) as client:
        response = client.post("/v1/haul/offers", json={"name": "x", "country": "Latvia"})
    assert response.status_code == 422
