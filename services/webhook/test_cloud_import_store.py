from datetime import datetime, timedelta, timezone

from cloud_import_models import BookmarkInput, CreateImportRequest, VideoResult
from cloud_import_store import DynamoImportStore


class FakeTable:
    def __init__(self):
        self.items = {}

    def put_item(self, *, Item, **_kwargs):
        key = (Item["PK"], Item["SK"])
        self.items[key] = Item.copy()

    def get_item(self, *, Key, **_kwargs):
        item = self.items.get((Key["PK"], Key["SK"]))
        return {"Item": item.copy()} if item else {}

    def query(self, *, KeyConditionExpression=None, **_kwargs):
        pk = KeyConditionExpression[0]
        prefix = KeyConditionExpression[1]
        items = [
            item.copy()
            for (item_pk, sort_key), item in self.items.items()
            if item_pk == pk and sort_key.startswith(prefix)
        ]
        return {"Items": sorted(items, key=lambda item: item["SK"])}


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


def request(video_ids=("1", "2")):
    return CreateImportRequest(
        clientImportID="11111111-1111-4111-8111-111111111111",
        videos=[
            BookmarkInput(
                videoID=video_id,
                url=f"https://www.tiktok.com/@x/video/{video_id}",
                bookmarkedAt=datetime.now(timezone.utc),
            )
            for video_id in video_ids
        ],
    )


def test_create_is_idempotent_and_claim_is_single_winner():
    table = FakeTable()
    store = DynamoImportStore(table=table, installation_id="test-group")

    first = store.create_import(request())
    second = store.create_import(request())

    assert first.created is True
    assert second.created is False
    assert second.import_id == first.import_id
    assert store.claim_video(first.import_id, "1") is True
    assert store.claim_video(first.import_id, "1") is False


def test_duplicate_completion_does_not_increment_done_twice():
    table = FakeTable()
    store = DynamoImportStore(table=table, installation_id="test-group")
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
    store = DynamoImportStore(table=table, installation_id="test-group")
    created = store.create_import(request(("2", "1")))
    for video_id in ("2", "1"):
        store.claim_video(created.import_id, video_id)
        store.complete_video(created.import_id, VideoResult(videoID=video_id))

    page = store.list_results(created.import_id)
    assert [item.video_id for item in page.results] == ["1", "2"]


def test_total_is_aliased_in_dynamodb_conditions():
    table = FakeTable()
    store = DynamoImportStore(table=table, installation_id="test-group")
    created = store.create_import(request(("1",)))
    store.claim_video(created.import_id, "1")

    client = CaptureClient()
    store._client = client
    assert store.complete_video(created.import_id, VideoResult(videoID="1")) is True
    completion_meta = client.transactions[-1][1]["Update"]
    assert completion_meta["ExpressionAttributeNames"]["#total"] == "total"
    assert "#total" in completion_meta["ConditionExpression"]

    table = UpdateCaptureTable()
    store = DynamoImportStore(table=table, installation_id="test-group")
    import_id = "import-finalize"
    table.put_item(
        Item={
            "PK": f"IMPORT#{import_id}",
            "SK": "META",
            "state": "fast_pass",
            "fastDone": 1,
            "total": 1,
        }
    )
    store._try_finalize(import_id)
    assert table.updates[0]["ExpressionAttributeNames"]["#total"] == "total"


def test_stale_running_video_can_be_reclaimed_after_worker_restart():
    table = FakeTable()
    store = DynamoImportStore(table=table, installation_id="test-group")
    created = store.create_import(request(("1",)))
    key = (f"IMPORT#{created.import_id}", "VIDEO#1")
    table.items[key]["state"] = "running"
    table.items[key]["updatedAt"] = (datetime.now(timezone.utc) - timedelta(seconds=301)).isoformat()

    assert store.claim_video(created.import_id, "1") is True
