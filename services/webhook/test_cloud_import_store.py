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
