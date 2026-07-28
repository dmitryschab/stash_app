#!/usr/bin/env python3
"""Account administration: invite codes and quota grants. Runs ON the box, never an API route.

    sudo -u stash /opt/stash-webhook/venv/bin/python manage_invites.py mint --uses 1
    sudo -u stash /opt/stash-webhook/venv/bin/python manage_invites.py mint --uses 50 --demo
    sudo -u stash /opt/stash-webhook/venv/bin/python manage_invites.py list
    sudo -u stash /opt/stash-webhook/venv/bin/python manage_invites.py revoke STASH-4KQ9-7WTM
    sudo -u stash /opt/stash-webhook/venv/bin/python manage_invites.py accounts
    sudo -u stash /opt/stash-webhook/venv/bin/python manage_invites.py grant-quota <userID> --units 900

Deliberately a CLI and not an admin endpoint: an invite minter reachable over HTTP is a
second authentication surface to get right, and there is exactly one operator.

Codes always carry an expiresAt so the redemption condition in stash_auth stays a plain
AND chain — a code written by hand without one can never be redeemed.

`--demo` marks the App Review code: accounts created from it come back `"demo": true`
from /v1/auth/apple and /v1/me, and the app seeds its own sample library off that.
"""

from __future__ import annotations

import argparse
import secrets
import sys
import time

from boto3.dynamodb.conditions import Attr

from cloud_import_models import INITIAL_LIMIT, MONTH_LIMIT
from cloud_import_store import _is_conditional_failure, shared_table

# No I/O/0/1: these get read aloud and typed in by hand.
ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
DEFAULT_EXPIRY_DAYS = 365


def generate_code() -> str:
    body = "".join(secrets.choice(ALPHABET) for _ in range(8))
    return f"STASH-{body[:4]}-{body[4:]}"


def mint(table, uses: int, expiry_days: int, label: str, demo: bool = False) -> dict:
    code = generate_code()
    now = int(time.time())
    item = {
        "PK": f"INVITE#{code}",
        "SK": "META",
        "code": code,
        "maxUses": uses,
        "usedCount": 0,
        "createdAt": now,
        "expiresAt": now + expiry_days * 86400,
        "label": label,
        "demo": demo,
    }
    table.put_item(Item=item, ConditionExpression="attribute_not_exists(PK)")
    return item


def list_invites(table) -> list[dict]:
    """Scan: invite codes are their own partitions, and there will be tens of them."""
    invites, start_key = [], None
    while True:
        arguments = {"FilterExpression": Attr("SK").eq("META")}
        if start_key:
            arguments["ExclusiveStartKey"] = start_key
        page = table.scan(**arguments)
        invites.extend(item for item in page.get("Items", []) if str(item["PK"]).startswith("INVITE#"))
        start_key = page.get("LastEvaluatedKey")
        if not start_key:
            return sorted(invites, key=lambda item: int(item.get("createdAt", 0)))


def revoke(table, code: str) -> bool:
    """Expire the code in place rather than deleting it, so `list` still shows it was used."""
    try:
        table.update_item(
            Key={"PK": f"INVITE#{code}", "SK": "META"},
            UpdateExpression="SET expiresAt = :past",
            ConditionExpression="attribute_exists(PK)",
            ExpressionAttributeValues={":past": 0},
        )
    except Exception as error:
        if _is_conditional_failure(error):
            return False  # no such code
        raise  # a permissions or network problem must not read as "not found"
    return True


def list_accounts(table) -> list[str]:
    """Every account partition. Same scan-is-fine reasoning as `list_invites`."""
    users, start_key = set(), None
    while True:
        arguments = {"ProjectionExpression": "PK"}
        if start_key:
            arguments["ExclusiveStartKey"] = start_key
        page = table.scan(**arguments)
        for item in page.get("Items", []):
            key = str(item["PK"])
            if key.startswith("INSTALL#"):
                users.add(key[len("INSTALL#"):])
        start_key = page.get("LastEvaluatedKey")
        if not start_key:
            return sorted(users)


def grant_quota(table, user_id: str, units: int) -> dict:
    """Add `units` to an account's initial budget.

    Writes the row directly rather than going through `DynamoImportStore.refund_quota`, which
    clamps at INITIAL_LIMIT/MONTH_LIMIT — correct for paying back a charge, useless for lifting
    a ceiling. Re-analysing a whole library costs one unit per video, which is what this exists
    for; there is no in-app path to it and no reason for one.
    """
    key = {"PK": f"INSTALL#{user_id}", "SK": "QUOTA"}
    item = table.get_item(Key=key).get("Item") or {}
    initial = int(item.get("initialRemaining", INITIAL_LIMIT))
    month = int(item.get("monthRemaining", MONTH_LIMIT))
    reset = int(item.get("monthResetAt", 0)) or int(time.time()) + 30 * 86400
    updated = {**key, "initialRemaining": initial + units, "monthRemaining": month,
               "monthResetAt": reset, "updatedAt": int(time.time())}
    table.put_item(Item=updated)
    return updated


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Stash invite code administration")
    commands = parser.add_subparsers(dest="command", required=True)

    minter = commands.add_parser("mint", help="create a new invite code")
    minter.add_argument("--uses", type=int, default=1, help="how many accounts may redeem it")
    minter.add_argument("--expires-days", type=int, default=DEFAULT_EXPIRY_DAYS)
    minter.add_argument("--label", default="", help="free-text note, e.g. who it went to")
    minter.add_argument("--demo", action="store_true",
                        help="accounts made with it seed the in-app demo library (App Review)")

    commands.add_parser("list", help="show every invite code and its usage")

    revoker = commands.add_parser("revoke", help="expire an invite code immediately")
    revoker.add_argument("code")

    commands.add_parser("accounts", help="list account user IDs")

    granter = commands.add_parser("grant-quota", help="add units to an account's initial budget")
    granter.add_argument("user_id")
    granter.add_argument("--units", type=int, required=True)

    args = parser.parse_args(argv)
    table = shared_table()

    if args.command == "mint":
        if args.uses < 1:
            parser.error("--uses must be at least 1")
        item = mint(table, args.uses, args.expires_days, args.label, args.demo)
        print(f"{item['code']}  uses=0/{item['maxUses']}  expires={item['expiresAt']}"
              f"{'  demo' if item['demo'] else ''}")
        return 0

    if args.command == "list":
        now = int(time.time())
        for item in list_invites(table):
            expires = int(item.get("expiresAt", 0))
            state = "expired" if expires <= now else (
                "spent" if int(item.get("usedCount", 0)) >= int(item.get("maxUses", 0)) else "open")
            print(f"{item.get('code', item['PK']):<20} {item.get('usedCount', 0)}/{item.get('maxUses', 0)}"
                  f"  {state:<8} {'demo ' if item.get('demo') else ''}{item.get('label', '')}")
        return 0

    if args.command == "accounts":
        for user_id in list_accounts(table):
            print(user_id)
        return 0

    if args.command == "grant-quota":
        if args.units < 1:
            parser.error("--units must be at least 1")
        item = grant_quota(table, args.user_id.strip(), args.units)
        print(f"{args.user_id}  initial={item['initialRemaining']}  month={item['monthRemaining']}")
        return 0

    code = args.code.strip().upper()
    if not revoke(table, code):
        print(f"no such invite: {code}", file=sys.stderr)
        return 1
    print(f"revoked {code}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
