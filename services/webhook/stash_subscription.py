# stash_subscription.py
#
# The paywall's server half.
#
# Until 1.0 the App Store price was the gate: a stranger could not reach an authenticated
# route without first paying €5. 1.1 is free to download, so that gate is gone and this
# replaces it — every route that spends Bedrock or Groq money now requires an entitlement,
# and an entitlement only ever comes from something Apple signed.
#
# The client posts the JWS blobs StoreKit 2 hands it: the signed transaction for the
# subscription, and the app's own AppTransaction. Both are verified locally against Apple's
# root CA — no App Store Server API key, no outbound call to Apple, nothing extra to rotate.
# A client claiming "I am subscribed" without a blob Apple signed gets nothing.
#
# ponytail: entitlement refreshes only when the app posts one (launch, purchase, restore).
# A subscription cancelled mid-month stays entitled in our table until the next post, i.e.
# at most one launch of grace, and the stored expiry still cuts it off at the period end.
# App Store Server Notifications V2 is the upgrade path if that grace ever matters — this
# service is already a webhook, so it is a route and a verifier call, not an architecture.

from __future__ import annotations

import time
from pathlib import Path
from typing import Any

from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier, VerificationException

BUNDLE_ID = "dev.dmitryschab.Stash"
APP_APPLE_ID = 6789977520
PRODUCT_ID = "dev.dmitryschab.Stash.pro.monthly"

# The last build sold as a paid app. Anyone whose AppTransaction says their first download
# was at or below this paid €5 up front, so they own the app outright and must never meet
# the paywall. Apple requires that; it is also the only decent way to treat them.
LAST_PAID_BUILD = 24

# Accounts created before this are entitled outright. Two groups are inside it, and both have
# to be: everyone who bought Stash at €5 while 1.0 was the paid app, and everyone who downloads
# the still-live build 24 during the window between the price going Free and 1.1 replacing it
# on the store. Build 24 has no StoreKit in it at all, so neither group can prove anything —
# a shorter cutoff would leave real people holding an app that 402s on every tap.
#
# 2026-09-18, three weeks out: long enough to cover review and release, short enough that it
# is not a standing giveaway. It has to be a date and not "when the price flips", because the
# box cannot see the price. Once 1.1 is live this stops mattering — build 25 sends the
# AppTransaction that sets `lifetime` permanently for anyone who genuinely bought 1.0.
PAID_ERA_ENDS = 1789683004

_ROOT_CA = Path(__file__).with_name("AppleRootCA-G3.cer")


def _verifier(environment: Environment) -> SignedDataVerifier:
    return SignedDataVerifier([_ROOT_CA.read_bytes()], True, environment, BUNDLE_ID, APP_APPLE_ID)


def _decode(jws: str, method: str) -> tuple[Any, Environment]:
    """Verify against production, then sandbox.

    The same binary emits sandbox blobs under TestFlight and App Review and production blobs
    on the App Store, and nothing readable on the outside of the blob says which. Trying both
    is Apple's own documented answer.
    """
    failure: Exception | None = None
    for environment in (Environment.PRODUCTION, Environment.SANDBOX):
        try:
            return getattr(_verifier(environment), method)(jws), environment
        except VerificationException as error:
            failure = error
    raise failure if failure else VerificationException("no verifier ran")


def _epoch_seconds(milliseconds: Any) -> int:
    try:
        return int(milliseconds) // 1000
    except (TypeError, ValueError):
        return 0


def read_subscription(jws: str) -> int:
    """Seconds-since-epoch this subscription lapses, or 0 if it grants nothing.

    Zero covers every "no" in one value: wrong product, refunded, already expired. The caller
    stores it and compares against now, so a lapsed blob is not an error — it is an expiry in
    the past, which is exactly what it means.
    """
    payload, _ = _decode(jws, "verify_and_decode_signed_transaction")
    if getattr(payload, "productId", None) != PRODUCT_ID:
        return 0
    # A refund or a family-sharing revocation ends the entitlement regardless of the period.
    if getattr(payload, "revocationDate", None):
        return 0
    return _epoch_seconds(getattr(payload, "expiresDate", None))


def read_paid_owner(jws: str) -> bool:
    """True if this AppTransaction says the account bought the app back when it cost money.

    Only in production. Sandbox and TestFlight report an `originalApplicationVersion` of
    "1.0", which parses to 1 and would hand every App Review tester a free lifetime pass —
    and would mean the paywall never gets exercised by the one person who has to see it work.
    """
    payload, environment = _decode(jws, "verify_and_decode_app_transaction")
    if environment is not Environment.PRODUCTION:
        return False
    if getattr(payload, "receiptType", None) is not Environment.PRODUCTION:
        return False
    raw = getattr(payload, "originalApplicationVersion", None)
    try:
        # iOS puts CFBundleVersion here — a build number, so "24", not "1.0".
        return int(str(raw).split(".")[0]) <= LAST_PAID_BUILD
    except (TypeError, ValueError):
        return False


def entitlement(*, signed_transaction: str | None, signed_app_transaction: str | None) -> dict:
    """Fold whatever the client sent into the two fields the user record keeps.

    Neither blob is required: a fresh subscriber has no AppTransaction worth having, and a
    grandfathered owner has no subscription at all.
    """
    expires_at = read_subscription(signed_transaction) if signed_transaction else 0
    lifetime = read_paid_owner(signed_app_transaction) if signed_app_transaction else False
    return {"subscriptionExpiresAt": expires_at, "lifetime": lifetime}


def is_entitled(user: dict[str, Any] | None) -> bool:
    """The one question every metered route asks.

    Demo accounts pass unconditionally. App Review redeems a `--demo` code to get a seeded
    library, and a reviewer who then hits a paywall they cannot pass is a 2.1 rejection —
    they get the app, not the checkout.
    """
    user = user or {}
    if user.get("demo") or user.get("lifetime"):
        return True
    if 0 < int(user.get("createdAt", 0) or 0) < PAID_ERA_ENDS:
        return True
    return int(user.get("subscriptionExpiresAt", 0) or 0) > int(time.time())


def selftest() -> bool:
    """Cheap invariants: the entitlement predicate, which is the money boundary."""
    now = int(time.time())
    assert is_entitled({"demo": True})
    assert is_entitled({"lifetime": True})
    assert is_entitled({"subscriptionExpiresAt": now + 60})
    assert not is_entitled({"subscriptionExpiresAt": now - 60})
    assert not is_entitled({"subscriptionExpiresAt": 0})
    assert not is_entitled({})
    assert not is_entitled(None)
    # The paid era: an account that predates the gate bought the app at €5.
    assert is_entitled({"createdAt": PAID_ERA_ENDS - 1})
    assert not is_entitled({"createdAt": PAID_ERA_ENDS + 1})
    assert not is_entitled({"createdAt": 0})
    assert _epoch_seconds(1_700_000_000_000) == 1_700_000_000
    assert _epoch_seconds(None) == 0
    assert _ROOT_CA.exists(), "AppleRootCA-G3.cer must ship beside this module"
    return True


if __name__ == "__main__":
    assert selftest()
    print("stash_subscription selftest ok")
