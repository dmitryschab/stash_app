from datetime import datetime, timedelta, timezone

import pytest

from cloud_import_models import BookmarkInput, CreateImportRequest, VideoResult
from cloud_import_store import MAX_FAST_PASS_ATTEMPTS, DynamoImportStore
from conftest import FakeTable

USER = "user-a"
PARTITION = f"INSTALL#{USER}"


class CaptureClient:
    def __init__(self):
        self.transactions = []

    def transact_write_items(self, *, TransactItems):
        self.transactions.append(TransactItems)


class UpdateCaptureTable(FakeTable):
    def __init__(self):
        super().__init__()
        self.updates = []

    def update_item(self, **kwargs):
        self.updates.append(kwargs)


def request(video_ids=("1", "2"), client_import_id="11111111-1111-4111-8111-111111111111"):
    return CreateImportRequest(
        clientImportID=client_import_id,
        videos=[
            BookmarkInput(
                videoID=video_id,
                url=f"https://www.tiktok.com/@x/video/{video_id}",
                bookmarkedAt=datetime.now(timezone.utc),
            )
            for video_id in video_ids
        ],
    )


def test_a_store_cannot_be_built_without_a_user():
    with pytest.raises(TypeError):
        DynamoImportStore(table=FakeTable())
    with pytest.raises(ValueError):
        DynamoImportStore(table=FakeTable(), user_id="")


def test_every_row_lands_in_the_owning_users_partition():
    table = FakeTable()
    store = DynamoImportStore(table=table, user_id=USER)
    created = store.create_import(request(("1",)))

    assert {key[0] for key in table.items} == {PARTITION}
    assert (PARTITION, f"IMPORT#{created.import_id}#META") in table.items
    assert (PARTITION, f"IMPORT#{created.import_id}#VIDEO#1") in table.items


def test_two_users_reusing_a_client_import_id_get_different_import_ids():
    shared_id = "22222222-2222-4222-8222-222222222222"
    first = DynamoImportStore(table=FakeTable(), user_id="user-a").create_import(request(("1",), shared_id))
    second = DynamoImportStore(table=FakeTable(), user_id="user-b").create_import(request(("1",), shared_id))
    assert first.import_id != second.import_id


def test_one_users_import_is_invisible_to_another():
    table = FakeTable()
    owner = DynamoImportStore(table=table, user_id="user-a")
    stranger = DynamoImportStore(table=table, user_id="user-b")
    created = owner.create_import(request(("1",)))

    assert owner.get_status(created.import_id) is not None
    assert stranger.get_status(created.import_id) is None
    assert stranger.list_results(created.import_id).results == []


def test_create_is_idempotent_and_claim_is_single_winner():
    table = FakeTable()
    store = DynamoImportStore(table=table, user_id=USER)

    first = store.create_import(request())
    second = store.create_import(request())

    assert first.created is True
    assert second.created is False
    assert second.import_id == first.import_id
    assert store.claim_video(first.import_id, "1") is True
    assert store.claim_video(first.import_id, "1") is False


def test_a_truncated_import_reports_its_remainder_on_retry_and_on_status():
    """A client that was killed mid-import comes back polling status, so the deferred count
    has to outlive the create response that first reported it."""
    store = DynamoImportStore(table=FakeTable(), user_id=USER)
    created = store.create_import(request(("1",)), deferred=220)

    assert created.deferred == 220
    assert store.create_import(request(("1",))).deferred == 220
    assert store.get_status(created.import_id).deferred == 220


def test_get_client_import_reports_a_prior_submission():
    store = DynamoImportStore(table=FakeTable(), user_id=USER)
    body = request()
    assert store.get_client_import(body.client_import_id) is None
    created = store.create_import(body)
    assert store.get_client_import(body.client_import_id)["importID"] == created.import_id


def test_pending_videos_lists_only_what_still_needs_a_worker():
    """What the retry re-drive sends again: anything a worker has not taken. A claimed row
    is left out so a needless retry does not re-send work already under way."""
    table = FakeTable()
    store = DynamoImportStore(table=table, user_id=USER)
    created = store.create_import(request(("1", "2", "3")))
    store.claim_video(created.import_id, "1")
    store.claim_video(created.import_id, "2")
    assert store.fail_video(created.import_id, "2", retryable=True, code="timeout") is True

    assert store.pending_videos(created.import_id) == [
        ("2", "https://www.tiktok.com/@x/video/2"),
        ("3", "https://www.tiktok.com/@x/video/3"),
    ]


def test_duplicate_completion_does_not_increment_done_twice():
    table = FakeTable()
    store = DynamoImportStore(table=table, user_id=USER)
    created = store.create_import(request(("1",)))
    result = VideoResult(videoID="1", title="A result")

    assert store.claim_video(created.import_id, "1") is True
    assert store.complete_video(created.import_id, result) is True
    assert store.complete_video(created.import_id, result) is False

    status = store.get_status(created.import_id)
    assert status.fast_pass.done == 1
    assert status.state.value == "completed"


def test_results_are_ordered_by_video_id():
    table = FakeTable()
    store = DynamoImportStore(table=table, user_id=USER)
    created = store.create_import(request(("2", "1")))
    for video_id in ("2", "1"):
        store.claim_video(created.import_id, video_id)
        store.complete_video(created.import_id, VideoResult(videoID=video_id))

    page = store.list_results(created.import_id)
    assert [item.video_id for item in page.results] == ["1", "2"]


def test_results_are_paged_from_the_cursor_not_filtered_in_python():
    table = FakeTable()
    store = DynamoImportStore(table=table, user_id=USER)
    created = store.create_import(request(tuple(str(index) for index in range(1, 7))))
    for video_id in (str(index) for index in range(1, 7)):
        store.claim_video(created.import_id, video_id)
        store.complete_video(created.import_id, VideoResult(videoID=video_id))

    first = store.list_results(created.import_id, limit=2)
    assert [item.video_id for item in first.results] == ["1", "2"]
    assert first.next_cursor == "2"

    second = store.list_results(created.import_id, cursor=first.next_cursor, limit=2)
    assert [item.video_id for item in second.results] == ["3", "4"]


def test_results_skip_a_second_import_in_the_same_partition():
    table = FakeTable()
    store = DynamoImportStore(table=table, user_id=USER)
    first = store.create_import(request(("1",), "33333333-3333-4333-8333-333333333333"))
    second = store.create_import(request(("2",), "44444444-4444-4444-8444-444444444444"))
    for created, video_id in ((first, "1"), (second, "2")):
        store.claim_video(created.import_id, video_id)
        store.complete_video(created.import_id, VideoResult(videoID=video_id))

    assert [item.video_id for item in store.list_results(first.import_id).results] == ["1"]


def test_total_is_aliased_in_dynamodb_conditions():
    table = FakeTable()
    store = DynamoImportStore(table=table, user_id=USER)
    created = store.create_import(request(("1",)))
    store.claim_video(created.import_id, "1")

    client = CaptureClient()
    store._client = client
    assert store.complete_video(created.import_id, VideoResult(videoID="1")) is True
    completion_meta = client.transactions[-1][1]["Update"]
    assert completion_meta["ExpressionAttributeNames"]["#total"] == "total"
    assert "#total" in completion_meta["ConditionExpression"]

    table = UpdateCaptureTable()
    store = DynamoImportStore(table=table, user_id=USER)
    import_id = "import-finalize"
    table.put_item(
        Item={
            "PK": PARTITION,
            "SK": f"IMPORT#{import_id}#META",
            "state": "fast_pass",
            "fastDone": 1,
            "total": 1,
        }
    )
    store._try_finalize(import_id)
    assert table.updates[0]["ExpressionAttributeNames"]["#total"] == "total"


def test_transaction_fallback_refuses_expressions_it_cannot_apply():
    # A fallback that guessed would let a wrong arithmetic result pass green in tests.
    store = DynamoImportStore(table=FakeTable(), user_id=USER)
    with pytest.raises(NotImplementedError):
        store._transact([{"Update": {"TableName": "t", "Key": {"PK": PARTITION, "SK": "X"},
                                     "UpdateExpression": "ADD counter :one",
                                     "ExpressionAttributeValues": {":one": 1}}}])
    with pytest.raises(NotImplementedError):
        store._transact([{"ConditionCheck": {"TableName": "t", "Key": {"PK": PARTITION, "SK": "X"}}}])


def test_transaction_fallback_applies_subtraction():
    table = FakeTable()
    store = DynamoImportStore(table=table, user_id=USER)
    table.put_item(Item={"PK": PARTITION, "SK": "X", "left": 10})
    store._transact([{"Update": {"TableName": "t", "Key": {"PK": PARTITION, "SK": "X"},
                                 "UpdateExpression": "SET left = left - :two",
                                 "ExpressionAttributeValues": {":two": 2}}}])
    assert table.items[(PARTITION, "X")]["left"] == 8


def test_retryable_video_finalizes_after_attempt_budget():
    # A video that keeps failing transiently must not stall the import forever: once
    # the attempt budget is spent it fails terminally and the import finalizes.
    table = FakeTable()
    store = DynamoImportStore(table=table, user_id=USER)
    created = store.create_import(request(("1",)))

    for _ in range(MAX_FAST_PASS_ATTEMPTS):  # each cycle = one SQS redelivery
        assert store.claim_video(created.import_id, "1") is True
        store.fail_video(created.import_id, "1", retryable=True, code="provider_503")

    video = store.get_video(created.import_id, "1")
    assert video["state"] == "failed"
    status = store.get_status(created.import_id)
    assert status.fast_pass.done == 1
    assert status.partial_failures == 1
    assert status.state.value == "completed"


def test_whole_library_create_writes_every_video_row():
    # 900 videos exceed DynamoDB's 100-item transaction cap, so create must stage
    # rows individually rather than in one transaction.
    table = FakeTable()
    store = DynamoImportStore(table=table, user_id=USER)
    created = store.create_import(request(tuple(str(i) for i in range(1, 901))))

    assert created.created is True
    assert created.accepted == 900
    rows = [key for key in table.items if "#VIDEO#" in key[1]]
    assert len(rows) == 900
    assert store.get_status(created.import_id).fast_pass.total == 900


def test_stale_running_video_can_be_reclaimed_after_worker_restart():
    table = FakeTable()
    store = DynamoImportStore(table=table, user_id=USER)
    created = store.create_import(request(("1",)))
    key = (PARTITION, f"IMPORT#{created.import_id}#VIDEO#1")
    table.items[key]["state"] = "running"
    table.items[key]["updatedAt"] = (datetime.now(timezone.utc) - timedelta(seconds=301)).isoformat()

    assert store.claim_video(created.import_id, "1") is True


def test_delete_user_items_clears_the_whole_partition():
    table = FakeTable()
    store = DynamoImportStore(table=table, user_id=USER)
    store.create_import(request(("1", "2")))
    store.reserve_quota(2)
    table.put_item(Item={"PK": "INSTALL#user-b", "SK": "USER"})

    removed = store.delete_user_items()

    assert all(key["PK"] == PARTITION for key in removed)
    assert list(table.items) == [("INSTALL#user-b", "USER")]


class PagingTable(FakeTable):
    """Real DynamoDB caps a Query page at 1 MB whether or not Limit was asked for, so a
    partition worth deleting always comes back across several pages. FakeTable only pages
    when Limit is set, which left the account-erasure path reading exactly one page."""

    PAGE = 3

    def query(self, *, KeyConditionExpression=None, Limit=None, ExclusiveStartKey=None, **_kwargs):
        partition, prefix = KeyConditionExpression
        rows = sorted(
            (dict(item) for (item_pk, sort_key), item in self.items.items()
             if item_pk == partition and sort_key.startswith(prefix)),
            key=lambda item: item["SK"],
        )
        if ExclusiveStartKey:
            rows = [item for item in rows if item["SK"] > ExclusiveStartKey["SK"]]
        size = min(self.PAGE, Limit) if Limit else self.PAGE
        page = rows[:size]
        result = {"Items": page}
        if len(rows) > size:
            result["LastEvaluatedKey"] = {"PK": page[-1]["PK"], "SK": page[-1]["SK"]}
        return result


def test_deletion_and_export_follow_every_query_page():
    """Account erasure is an App Store commitment, so 'the first page' is not good enough."""
    table = PagingTable()
    store = DynamoImportStore(table=table, user_id=USER)
    store.create_import(request(tuple(str(index) for index in range(1, 11))))
    store.reserve_quota(3)
    table.put_item(Item={"PK": PARTITION, "SK": "USER", "userID": USER})
    table.put_item(Item={"PK": "INSTALL#user-b", "SK": "USER"})
    stored = sum(1 for key in table.items if key[0] == PARTITION)
    assert stored > PagingTable.PAGE  # otherwise the test proves nothing

    assert len(list(store.iter_user_items())) == stored
    removed = store.delete_user_items()

    assert len(removed) == stored
    assert list(table.items) == [("INSTALL#user-b", "USER")]


def test_failure_counts_tally_failed_and_unavailable_rows_across_imports():
    table = FakeTable()
    store = DynamoImportStore(table=table, user_id=USER)
    first = store.create_import(request(("1", "2", "3")))
    second = store.create_import(request(("1",), "33333333-3333-4333-8333-333333333333"))
    for import_id, video_id, state in ((first.import_id, "1", "failed"), (second.import_id, "1", "failed"),
                                       (first.import_id, "2", "unavailable"), (first.import_id, "3", "completed")):
        table.items[(PARTITION, f"IMPORT#{import_id}#VIDEO#{video_id}")]["state"] = state

    assert store.failure_counts({"1", "2", "3", "4"}) == {"1": 2, "2": 1}


# ---------------------------------------------------------------- map pass

from conftest import ConditionalTable  # noqa: E402 — appended with its tests


def test_the_map_counts_guesses_and_skips_on_meta_only():
    table = ConditionalTable()
    store = DynamoImportStore(table=table, user_id=USER)
    created = store.create_import(request(("1", "2", "3")))

    assert store.get_status(created.import_id).map is None     # no map until it starts

    store.start_map(created.import_id, sampled=3)
    store.guess_video(created.import_id, "1", "coding")
    store.guess_video(created.import_id, "2", "coding")
    store.skip_map_video(created.import_id)

    status = store.get_status(created.import_id)
    assert status.map.sampled == 3
    assert status.map.done == 3
    assert status.map.counts == {"coding": 2}
    assert status.map.guesses == {"1": "coding", "2": "coding"}
    # Nothing landed on the video rows: the status poll must not have to scan them.
    assert "guess" not in table.items[(store.partition, f"IMPORT#{created.import_id}#VIDEO#1")]


def test_two_categories_keep_separate_counters():
    store = DynamoImportStore(table=ConditionalTable(), user_id=USER)
    created = store.create_import(request(("1", "2")))
    store.start_map(created.import_id, sampled=2)
    store.guess_video(created.import_id, "1", "recipe")
    store.guess_video(created.import_id, "2", "music")
    assert store.get_status(created.import_id).map.counts == {"recipe": 1, "music": 1}


from cloud_import_queue import release_due  # noqa: E402
from cloud_import_store import LEASE_FREE, REFILL_AT, SLICE  # noqa: E402


class SliceQueue:
    def __init__(self):
        self.sent = []

    def enqueue(self, user_id, import_id, video_id, url=None):
        self.sent.append(video_id)


def dated_request(count, client_import_id="22222222-2222-4222-8222-222222222222"):
    """Video "n" was saved n hours ago, and the list is submitted oldest-first on purpose:
    the box, not the client, decides what "newest" means."""
    now = datetime.now(timezone.utc)
    return CreateImportRequest(
        clientImportID=client_import_id,
        videos=[
            BookmarkInput(videoID=str(n), url=f"https://www.tiktok.com/@x/video/{n}",
                          bookmarkedAt=now - timedelta(hours=n))
            for n in range(count, 0, -1)
        ],
    )


def sliced(count):
    table = ConditionalTable()
    store = DynamoImportStore(table=table, user_id=USER)
    import_id = store.create_import(dated_request(count)).import_id
    return table, store, import_id


def meta_row(table, store, import_id):
    return table.items[(store.partition, f"IMPORT#{import_id}#META")]


def settle(table, store, import_id, count):
    meta_row(table, store, import_id)["fastDone"] += count


def test_create_orders_rows_newest_first_and_releases_one_slice():
    table, store, import_id = sliced(250)
    rows = {item["videoID"]: item for (_pk, sk), item in table.items.items() if "#VIDEO#" in sk}

    assert rows["1"]["order"] == 0 and rows["250"]["order"] == 249
    assert meta_row(table, store, import_id)["released"] == SLICE
    assert store.slice_videos(import_id, 0, 3) == [
        (str(n), f"https://www.tiktok.com/@x/video/{n}") for n in (1, 2, 3)]


def test_the_next_slice_goes_out_only_when_the_current_one_is_nearly_settled():
    table, store, import_id = sliced(250)
    queue = SliceQueue()

    settle(table, store, import_id, SLICE - REFILL_AT - 1)            # 79 settled
    assert release_due(store, queue, import_id) == 0
    settle(table, store, import_id, 1)                                 # 80
    assert release_due(store, queue, import_id) == 100
    assert queue.sent == [str(n) for n in range(101, 201)]
    assert meta_row(table, store, import_id)["released"] == 200
    assert meta_row(table, store, import_id)["releaseLeaseUntil"] == LEASE_FREE

    settle(table, store, import_id, 100)                               # 180
    assert release_due(store, queue, import_id) == 50                  # the tail
    assert meta_row(table, store, import_id)["released"] == 250
    settle(table, store, import_id, 70)                                # all 250
    assert release_due(store, queue, import_id) == 0


def test_two_releases_racing_send_the_slice_once():
    table, store, import_id = sliced(250)
    settle(table, store, import_id, 80)

    assert store.claim_release(import_id) == (100, 200)
    assert store.claim_release(import_id) is None                      # the lease is held


def test_a_release_that_died_is_retaken_after_the_lease():
    table, store, import_id = sliced(250)
    settle(table, store, import_id, 80)
    assert store.claim_release(import_id) == (100, 200)                # …and then the caller died
    meta_row(table, store, import_id)["releaseLeaseUntil"] = (
        datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()
    queue = SliceQueue()

    assert release_due(store, queue, import_id) == 100
    assert queue.sent == [str(n) for n in range(101, 201)]
    assert meta_row(table, store, import_id)["released"] == 200


def test_an_import_of_exactly_one_slice_never_releases_again():
    table, store, import_id = sliced(SLICE)
    assert meta_row(table, store, import_id)["released"] == SLICE
    settle(table, store, import_id, SLICE)

    assert store.claim_release(import_id) is None


def test_the_retry_redrive_sends_only_released_rows():
    _table, store, import_id = sliced(250)

    assert {video_id for video_id, _url in store.pending_videos(import_id)} == {
        str(n) for n in range(1, 101)}


def test_an_import_from_before_slicing_is_left_alone():
    table, store, import_id = sliced(3)
    del meta_row(table, store, import_id)["released"]
    for (_pk, sk), item in table.items.items():
        if "#VIDEO#" in sk:
            del item["order"]

    assert store.claim_release(import_id) is None
    assert len(store.pending_videos(import_id)) == 3


def test_a_release_that_fails_midway_frees_the_lease_for_the_next_settle():
    """Otherwise the last ~20 settles of the slice all find the lease held, finish, and leave
    nobody to retry until the phone polls again — which can be hours with the app closed."""
    table, store, import_id = sliced(250)
    settle(table, store, import_id, 80)

    class ThrottledQueue(SliceQueue):
        def enqueue(self, *args, **kwargs):
            raise RuntimeError("sqs is throttling")

    with pytest.raises(RuntimeError):
        release_due(store, ThrottledQueue(), import_id)
    assert meta_row(table, store, import_id)["releaseLeaseUntil"] == LEASE_FREE
    assert meta_row(table, store, import_id)["released"] == 100

    queue = SliceQueue()
    assert release_due(store, queue, import_id) == 100


def test_rows_staged_without_a_usable_order_go_out_with_the_last_slice():
    """A create this deploy cut short leaves old-code rows with no `order`, and an earlier
    attempt with a longer body can leave an order past the final total. Neither may strand
    the import short of its total."""
    table, store, import_id = sliced(150)
    rows = {item["videoID"]: item for (_pk, sk), item in table.items.items() if "#VIDEO#" in sk}
    del rows["1"]["order"]                  # staged by the old code
    rows["2"]["order"] = 400                # staged by an attempt with a longer body
    settle(table, store, import_id, 80)
    queue = SliceQueue()

    assert release_due(store, queue, import_id) == 52     # orders 100–149, then both strays
    assert queue.sent[-2:] == ["1", "2"] or queue.sent[-2:] == ["2", "1"]


def test_draining_an_import_sends_every_video_once_newest_first():
    table, store, import_id = sliced(250)
    queue = SliceQueue()
    queue.sent = [video_id for video_id, _url in store.slice_videos(import_id, 0, SLICE)]  # what create_import sends
    settled = 0
    while settled < len(queue.sent):
        settle(table, store, import_id, 1)
        settled += 1
        before = len(queue.sent)
        release_due(store, queue, import_id)
        if len(queue.sent) > before:
            assert before - settled <= REFILL_AT    # a slice only goes out once the last is nearly done

    assert queue.sent == [str(n) for n in range(1, 251)]


def test_the_library_walks_every_import_and_keeps_only_completed_saves():
    table = FakeTable()
    store = DynamoImportStore(table=table, user_id=USER)
    first = store.create_import(request(("1", "2"), "55555555-5555-4555-8555-555555555555"))
    second = store.create_import(request(("1", "3"), "66666666-6666-4666-8666-666666666666"))
    for created, video_id in ((first, "1"), (second, "1"), (second, "3")):
        store.claim_video(created.import_id, video_id)
        store.complete_video(created.import_id, VideoResult(videoID=video_id, category="recipe"))
    # "2" stays queued: nothing sorted, nothing to restore.

    items, cursor, pages = [], None, 0
    while True:
        page = store.list_library(cursor=cursor, limit=2)
        items += page.items
        pages += 1
        cursor = page.next_cursor
        if cursor is None:
            break

    assert pages > 1
    assert sorted(item.result.video_id for item in items) == ["1", "1", "3"]
    assert {item.url for item in items} == {"https://www.tiktok.com/@x/video/1",
                                           "https://www.tiktok.com/@x/video/3"}
    assert all(item.bookmarked_at.tzinfo and item.result.category == "recipe" for item in items)


def test_the_library_never_reads_another_users_partition():
    table = FakeTable()
    other = DynamoImportStore(table=table, user_id="user-b")
    created = other.create_import(request(("9",)))
    other.claim_video(created.import_id, "9")
    other.complete_video(created.import_id, VideoResult(videoID="9"))

    store = DynamoImportStore(table=table, user_id=USER)
    assert store.list_library().items == []
    assert store.list_library(cursor=f"IMPORT#{created.import_id}#VIDEO#0").items == []
