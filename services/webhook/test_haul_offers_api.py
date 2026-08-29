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
