"""Quota: initial budget first, then the calendar month, and never more than exists.

Plus the counter beside it: the deep pass spends no quota, so a per-UTC-day cap is what
bounds it instead.
"""

import time
from datetime import datetime, timezone

import pytest

from cloud_import_models import INITIAL_LIMIT, MONTH_LIMIT
from cloud_import_store import QUOTA_CAS_ATTEMPTS, DynamoImportStore, _next_month_reset
from conftest import ConditionalTable

QUOTA_KEY = ("INSTALL#user-a", "QUOTA")
DEEP_PASS_KEY = ("INSTALL#user-a", "DEEPPASS")


def store(table=None):
    return DynamoImportStore(table=table or ConditionalTable(), user_id="user-a")


def test_a_fresh_account_starts_at_the_documented_limits():
    quota = store().get_quota()
    assert (quota.initial_remaining, quota.month_remaining) == (INITIAL_LIMIT, MONTH_LIMIT)
    assert (quota.initial_limit, quota.month_limit) == (INITIAL_LIMIT, MONTH_LIMIT)
    assert quota.month_reset_at > int(time.time())


def test_reading_quota_does_not_create_or_spend_anything():
    table = ConditionalTable()
    store(table).get_quota()
    assert QUOTA_KEY not in table.items


def test_initial_budget_drains_before_the_monthly_one():
    subject = store()
    first = subject.reserve_quota(400)
    assert (first.initial_remaining, first.month_remaining) == (INITIAL_LIMIT - 400, MONTH_LIMIT)

    # Spills across the boundary: the last 100 initial units, then 50 monthly ones.
    second = subject.reserve_quota(150)
    assert (second.initial_remaining, second.month_remaining) == (0, MONTH_LIMIT - 50)
    assert subject.get_quota().month_remaining == MONTH_LIMIT - 50


def test_a_request_larger_than_the_remaining_budget_is_refused_whole():
    subject = store()
    subject.reserve_quota(INITIAL_LIMIT + MONTH_LIMIT - 5)
    assert subject.reserve_quota(6) is None
    assert subject.get_quota().month_remaining == 5  # nothing was taken on the way out


def test_exhausted_quota_reserves_nothing():
    subject = store()
    subject.reserve_quota(INITIAL_LIMIT + MONTH_LIMIT)
    assert subject.reserve_quota(1) is None
    quota = subject.get_quota()
    assert (quota.initial_remaining, quota.month_remaining) == (0, 0)


def test_refund_restores_the_budget_it_came_from_and_cannot_inflate_it():
    subject = store()
    subject.reserve_quota(10)
    assert subject.refund_quota(10).initial_remaining == INITIAL_LIMIT
    assert subject.refund_quota(50).initial_remaining == INITIAL_LIMIT
    assert subject.get_quota().month_remaining == MONTH_LIMIT


def test_a_refund_of_month_units_does_not_survive_the_month_reset():
    """The dangerous shape: the initial budget is gone, so the spend comes out of the month
    bucket. Refunding it into the initial bucket would balance today and mint 50 permanent
    units on the 1st, because only the month bucket is reset.
    """
    table = ConditionalTable()
    subject = store(table)
    subject.reserve_quota(INITIAL_LIMIT)
    spent = subject.reserve_quota(50)
    assert (spent.initial_remaining, spent.month_remaining) == (0, MONTH_LIMIT - 50)

    refunded = subject.refund_quota(50)
    assert (refunded.initial_remaining, refunded.month_remaining) == (0, MONTH_LIMIT)

    table.items[QUOTA_KEY]["monthResetAt"] = int(time.time()) - 1
    after_reset = subject.get_quota()
    assert after_reset.initial_remaining + after_reset.month_remaining == MONTH_LIMIT


def test_month_window_resets_and_the_roll_persists():
    table = ConditionalTable()
    subject = store(table)
    subject.reserve_quota(INITIAL_LIMIT + 50)
    table.items[QUOTA_KEY]["monthResetAt"] = int(time.time()) - 1

    rolled = subject.get_quota()
    assert rolled.month_remaining == MONTH_LIMIT
    assert rolled.month_reset_at > int(time.time())

    after = subject.reserve_quota(1)
    assert after.month_remaining == MONTH_LIMIT - 1
    assert int(table.items[QUOTA_KEY]["monthResetAt"]) == rolled.month_reset_at


@pytest.mark.parametrize("now,expected", [
    (datetime(2026, 7, 25, 12, 0, tzinfo=timezone.utc), datetime(2026, 8, 1, tzinfo=timezone.utc)),
    (datetime(2026, 12, 31, 23, 59, tzinfo=timezone.utc), datetime(2027, 1, 1, tzinfo=timezone.utc)),
])
def test_reset_lands_on_the_first_of_the_next_month_utc(now, expected):
    assert _next_month_reset(now) == int(expected.timestamp())


def test_concurrent_reservations_cannot_both_spend_the_last_unit():
    """Two callers read the same state; only one write may land.

    The stale read is injected rather than threaded so the interleaving is deterministic:
    it reproduces exactly the case where request A reads, request B reads and writes, and
    then A tries to write against a state that no longer exists.
    """
    table = ConditionalTable()
    loser, winner = store(table), store(table)
    loser.reserve_quota(INITIAL_LIMIT + MONTH_LIMIT - 1)
    assert loser.get_quota().month_remaining == 1

    stale = table.get_item(Key={"PK": QUOTA_KEY[0], "SK": QUOTA_KEY[1]})["Item"]
    assert winner.reserve_quota(1) is not None

    pending = [{"Item": stale}]
    live_get_item = table.get_item
    table.get_item = lambda **kwargs: pending.pop(0) if pending else live_get_item(**kwargs)

    assert loser.reserve_quota(1) is None
    assert int(table.items[QUOTA_KEY]["monthRemaining"]) == 0


def test_the_retry_budget_covers_the_clients_own_concurrency():
    """N writers racing on one row need N attempts in the worst case, and the app drains
    its queue at concurrency 3 on the metered transcript route. A budget that ran out
    raised *after* Groq had already been paid for and the transcript produced.
    """
    table = ConditionalTable()
    subject = store(table)
    subject.reserve_quota(1)
    stale = table.get_item(Key={"PK": QUOTA_KEY[0], "SK": QUOTA_KEY[1]})["Item"]

    # Every other writer lands first, so this one loses its condition once per round.
    losses = 4
    pending = [{"Item": dict(stale)} for _ in range(losses)]
    live_get_item = table.get_item
    table.get_item = lambda **kwargs: pending.pop(0) if pending else live_get_item(**kwargs)

    assert losses < QUOTA_CAS_ATTEMPTS
    assert subject.reserve_quota(1) is not None
    assert int(table.items[QUOTA_KEY]["initialRemaining"]) == INITIAL_LIMIT - 2


def test_the_deep_pass_cap_counts_up_and_then_refuses():
    subject = store()
    assert subject.charge_deep_pass(2) is True
    assert subject.charge_deep_pass(2) is True
    assert subject.charge_deep_pass(2) is False
    assert subject.get_quota().initial_remaining == INITIAL_LIMIT  # a separate counter entirely


def test_the_deep_pass_cap_rolls_over_at_the_next_utc_day():
    """No scheduled sweep: yesterday's day key is what makes today's first call start at one."""
    table = ConditionalTable()
    subject = store(table)
    assert subject.charge_deep_pass(1) is True
    assert subject.charge_deep_pass(1) is False

    table.items[DEEP_PASS_KEY]["utcDay"] = "2020-01-01"
    assert subject.charge_deep_pass(1) is True
    assert int(table.items[DEEP_PASS_KEY]["usedToday"]) == 1


def test_two_deep_pass_calls_cannot_both_take_the_last_one():
    """The same stale-read interleaving the quota row is protected against."""
    table = ConditionalTable()
    loser, winner = store(table), store(table)
    assert loser.charge_deep_pass(2) is True
    stale = table.get_item(Key={"PK": DEEP_PASS_KEY[0], "SK": DEEP_PASS_KEY[1]})["Item"]
    assert winner.charge_deep_pass(2) is True  # that was the last one

    pending = [{"Item": dict(stale)}]
    live_get_item = table.get_item
    table.get_item = lambda **kwargs: pending.pop(0) if pending else live_get_item(**kwargs)

    assert loser.charge_deep_pass(2) is False
    assert int(table.items[DEEP_PASS_KEY]["usedToday"]) == 2


def test_contention_that_never_settles_is_loud_not_silent():
    """A compare-and-set that keeps losing must raise, never quietly report success."""
    table = ConditionalTable()
    subject = store(table)
    subject.reserve_quota(1)
    stale = table.get_item(Key={"PK": QUOTA_KEY[0], "SK": QUOTA_KEY[1]})["Item"]
    table.items[QUOTA_KEY]["monthRemaining"] = MONTH_LIMIT - 1  # someone else moved it
    table.get_item = lambda **_kwargs: {"Item": dict(stale)}

    with pytest.raises(RuntimeError, match="contention"):
        subject.reserve_quota(1)
