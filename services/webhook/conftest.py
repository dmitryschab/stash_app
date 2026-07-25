"""Shared test doubles: an in-memory DynamoDB table and an Apple signing key.

`ConditionalTable` actually evaluates ConditionExpressions instead of ignoring them,
because every safety property this backend has is a conditional write — single-use invite
redemption, refresh-token rotation, the quota compare-and-set. A fake that waved those
through would let all three tests pass green while production overspent and double-redeemed.

It raises NotImplementedError on any expression shape it does not understand, so a future
condition cannot silently degrade to "always true".
"""

from __future__ import annotations

import operator
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa


class ConditionalCheckFailed(Exception):
    """Named to match what cloud_import_store._is_conditional_failure looks for."""


_COMPARATORS = {  # "<>" and "<=" must be tried before "<"
    "<>": operator.ne, "<=": operator.le, ">=": operator.ge,
    "<": operator.lt, ">": operator.gt, "=": operator.eq,
}


def _resolve(token: str, item: dict, names: dict, values: dict):
    token = token.strip()
    if token.startswith(":"):
        return values[token]
    return item.get(names.get(token, token))


def evaluate_condition(expression: str, item: dict, names: dict, values: dict) -> bool:
    for term in (part.strip() for part in expression.split(" AND ")):
        for function, expected_present in (("attribute_exists(", True), ("attribute_not_exists(", False)):
            if term.startswith(function) and term.endswith(")"):
                present = _resolve(term[len(function):-1], item, names, values) is not None
                if present != expected_present:
                    return False
                break
        else:
            for symbol, compare in _COMPARATORS.items():
                left, separator, right = term.partition(f" {symbol} ")
                if not separator:
                    continue
                a = _resolve(left, item, names, values)
                b = _resolve(right, item, names, values)
                if a is None or b is None or not compare(a, b):
                    return False
                break
            else:
                raise NotImplementedError(f"fake table cannot evaluate {term!r}")
    return True


def apply_update(item: dict, expression: str, names: dict, values: dict) -> None:
    if not expression.startswith("SET "):
        raise NotImplementedError(f"fake table cannot apply {expression!r}")
    for assignment in expression[4:].split(", "):
        name, value = [part.strip() for part in assignment.split("=", 1)]
        field = names.get(name, name)
        for symbol, combine in ((" + ", operator.add), (" - ", operator.sub)):
            if symbol in value:
                base, operand = [part.strip() for part in value.split(symbol, 1)]
                item[field] = combine(item.get(names.get(base, base), 0), values[operand])
                break
        else:
            if value not in values:
                raise NotImplementedError(f"fake table cannot evaluate {value!r}")
            item[field] = values[value]


class FakeTable:
    """Permissive table: conditions on put are ignored, and there is no update_item, so
    the store takes its non-transactional fallback path. Used by the import-state tests."""

    def __init__(self):
        self.items = {}

    def put_item(self, *, Item, **_kwargs):
        self.items[(Item["PK"], Item["SK"])] = dict(Item)

    def get_item(self, *, Key, **_kwargs):
        item = self.items.get((Key["PK"], Key["SK"]))
        return {"Item": dict(item)} if item else {}

    def delete_item(self, *, Key, **_kwargs):
        self.items.pop((Key["PK"], Key["SK"]), None)

    def scan(self, *, FilterExpression=None, ExclusiveStartKey=None, **_kwargs):
        """Only the shape manage_invites uses: Attr(<name>).eq(<value>) over everything."""
        rows = [dict(item) for item in self.items.values()]
        if FilterExpression is not None:
            expression = FilterExpression.get_expression()
            if expression["operator"] != "=":
                raise NotImplementedError(f"fake table cannot scan on {expression['operator']!r}")
            name, value = expression["values"][0].name, expression["values"][1]
            rows = [item for item in rows if item.get(name) == value]
        return {"Items": rows}

    def query(self, *, KeyConditionExpression=None, Limit=None, ExclusiveStartKey=None, **_kwargs):
        pk, prefix = KeyConditionExpression
        rows = sorted(
            (dict(item) for (item_pk, sort_key), item in self.items.items()
             if item_pk == pk and sort_key.startswith(prefix)),
            key=lambda item: item["SK"],
        )
        if ExclusiveStartKey:
            rows = [item for item in rows if item["SK"] > ExclusiveStartKey["SK"]]
        page = rows if Limit is None else rows[:Limit]
        result = {"Items": page}
        if Limit is not None and len(rows) > Limit:
            result["LastEvaluatedKey"] = {"PK": page[-1]["PK"], "SK": page[-1]["SK"]}
        return result


class ConditionalTable(FakeTable):
    """Honours ConditionExpression on put/update/delete and supports update_item."""

    def put_item(self, *, Item, ConditionExpression=None, **_kwargs):
        key = (Item["PK"], Item["SK"])
        if ConditionExpression and not evaluate_condition(
                ConditionExpression, dict(self.items.get(key, {})), {}, {}):
            raise ConditionalCheckFailed(ConditionExpression)
        self.items[key] = dict(Item)

    def delete_item(self, *, Key, ConditionExpression=None, **_kwargs):
        key = (Key["PK"], Key["SK"])
        if ConditionExpression and not evaluate_condition(
                ConditionExpression, dict(self.items.get(key, {})), {}, {}):
            raise ConditionalCheckFailed(ConditionExpression)
        self.items.pop(key, None)

    def update_item(self, *, Key, UpdateExpression, ConditionExpression=None,
                    ExpressionAttributeNames=None, ExpressionAttributeValues=None,
                    ReturnValues=None, **_kwargs):
        names, values = ExpressionAttributeNames or {}, ExpressionAttributeValues or {}
        key = (Key["PK"], Key["SK"])
        item = dict(self.items.get(key, {}))
        if ConditionExpression and not evaluate_condition(ConditionExpression, item, names, values):
            raise ConditionalCheckFailed(ConditionExpression)
        item = item or dict(Key)
        apply_update(item, UpdateExpression, names, values)
        self.items[key] = item
        # Withheld unless asked for, exactly like Dynamo: a caller that forgot ReturnValues
        # must see the empty response here too, not a fake that is more generous than prod.
        if ReturnValues is None:
            return {}
        if ReturnValues != "ALL_NEW":
            raise NotImplementedError(f"fake table cannot return {ReturnValues!r}")
        return {"Attributes": dict(item)}


# ------------------------------------------------------------------ Apple test identity

APPLE_KID = "test-kid"


class AppleSigner:
    """Mints identity tokens the way Apple does, so the verifier is exercised for real."""

    def __init__(self, kid: str = APPLE_KID):
        self.kid = kid
        self.private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    def jwks_entry(self) -> dict:
        public = jwt.algorithms.RSAAlgorithm.to_jwk(self.private_key.public_key(), as_dict=True)
        return {**public, "kid": self.kid, "alg": "RS256", "use": "sig"}

    def token(self, sub: str = "apple-sub-1", *, audience: str = "dev.dmitryschab.Stash",
              issuer: str = "https://appleid.apple.com", expires_in: int = 600) -> str:
        now = int(time.time())
        return jwt.encode(
            {"iss": issuer, "aud": audience, "sub": sub, "iat": now, "exp": now + expires_in},
            self.private_key, algorithm="RS256", headers={"kid": self.kid},
        )


@pytest.fixture
def apple() -> AppleSigner:
    return AppleSigner()
