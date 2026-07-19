# Cloud Import Backend Vertical Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove that a 50-video import can be submitted once, processed durably after the client exits, inspected through status/results APIs, and resumed after a worker restart.

**Architecture:** Extend the existing FastAPI deployable with focused import API, store, queue, and worker modules. DynamoDB is authoritative job state, SQS provides at-least-once delivery, and the existing EC2 box runs a separate systemd worker process. This phase uses the existing bearer token and stores compact results in DynamoDB; installation auth, S3 manifests/thumbnails, APNs, selective deep-pass budgeting, and iOS integration are later plans.

**Tech Stack:** Python 3.11, FastAPI, Pydantic, boto3, DynamoDB, SQS, pytest, Terraform/AWS, systemd.

## Global Constraints

- Work in `/Users/dmitryschab/Documents/projects/stash_app` on a feature branch or isolated worktree.
- Read `docs/superpowers/specs/2026-07-12-asynchronous-cloud-import-design.md` before editing.
- Preserve `/webhook/tiktok`, `/v1/videos/transcript`, `/v1/chat/completions`, and `/v1/tiktok/download/{id}` behavior.
- Accept only `https://www.tiktok.com`, `https://tiktok.com`, `https://vm.tiktok.com`, and `https://vt.tiktok.com`; revalidate redirects.
- Maximum vertical-slice import size is 50 videos; one message represents one video fast pass.
- Every state mutation is idempotent by `(importID, videoID, stage)`.
- Do not add Redis, Celery, Lambda, Fargate, user accounts, APNs, or iOS changes in this plan.
- Never commit AWS credentials, provider keys, bearer tokens, captions, transcripts, or raw export files.

## File map

- `services/webhook/cloud_import_models.py`: API/domain enums and Pydantic contracts only.
- `services/webhook/cloud_import_store.py`: DynamoDB import/video state and atomic counters.
- `services/webhook/cloud_import_queue.py`: SQS send/receive/delete/visibility operations.
- `services/webhook/cloud_import_pipeline.py`: one-video TikTok metadata and caption analysis.
- `services/webhook/cloud_import_api.py`: authenticated submit/status/results routes.
- `services/webhook/cloud_import_worker.py`: polling loop and idempotent message handler.
- `services/webhook/test_cloud_import_*.py`: isolated contract, adapter, API, and worker tests.
- `infra/aws-box/main.tf`: queue, dead-letter queue, table, IAM role/profile, and instance attachment.
- `services/webhook/stash-import-worker.service`: independent systemd worker.
- `services/webhook/smoke_cloud_import.py`: submit/poll/assert 50-video live smoke tool.

---

### Task 1: Domain contracts and URL validation

**Files:**
- Create: `services/webhook/cloud_import_models.py`
- Create: `services/webhook/test_cloud_import_models.py`

**Interfaces:**
- Produces: `ImportState`, `VideoState`, `BookmarkInput`, `CreateImportRequest`, `CreateImportResponse`, `ImportStatus`, `VideoResult`, and `validate_tiktok_url(url: str) -> str`.

- [ ] **Step 1: Write failing contract tests**

```python
from datetime import datetime, timezone
import pytest
from pydantic import ValidationError
from cloud_import_models import BookmarkInput, CreateImportRequest

def test_accepts_canonical_tiktok_url():
    item = BookmarkInput(videoID="7651237687638101270", url="https://www.tiktok.com/@x/video/7651237687638101270", bookmarkedAt=datetime.now(timezone.utc))
    assert item.videoID in item.url

@pytest.mark.parametrize("url", ["http://www.tiktok.com/@x/video/1", "https://evil.test/video/1", "file:///etc/passwd"])
def test_rejects_non_allowlisted_url(url):
    with pytest.raises(ValidationError):
        BookmarkInput(videoID="1", url=url, bookmarkedAt=datetime.now(timezone.utc))

def test_rejects_more_than_50_items():
    item = {"videoID": "1", "url": "https://www.tiktok.com/@x/video/1", "bookmarkedAt": "2026-07-01T00:00:00Z"}
    with pytest.raises(ValidationError):
        CreateImportRequest(clientImportID="11111111-1111-4111-8111-111111111111", videos=[item] * 51)
```

- [ ] **Step 2: Run tests and confirm missing-module failure**

Run: `cd services/webhook && pytest -q test_cloud_import_models.py`
Expected: FAIL with `ModuleNotFoundError: cloud_import_models`.

- [ ] **Step 3: Implement enums and strict Pydantic models**

Use string enums with `accepted`, `fast_pass`, `completed`, `cancelled` and video states `queued`, `running`, `completed`, `retryable`, `unavailable`, `failed`. Validate HTTPS, exact hostname allowlist, numeric `videoID`, URL/video ID agreement for canonical URLs, UUID `clientImportID`, and `videos` length `1..50`. Define result fields for author, caption, hashtags, thumbnail URL, duration, category, title, summary, topics, unavailable, and error code.

- [ ] **Step 4: Run model tests**

Run: `cd services/webhook && pytest -q test_cloud_import_models.py`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add services/webhook/cloud_import_models.py services/webhook/test_cloud_import_models.py
git commit -m "feat(import): define cloud import contracts"
```

### Task 2: DynamoDB store with idempotent claims and counters

**Files:**
- Create: `services/webhook/cloud_import_store.py`
- Create: `services/webhook/test_cloud_import_store.py`
- Modify: `services/webhook/requirements.txt`

**Interfaces:**
- Consumes: Task 1 contracts.
- Produces: `DynamoImportStore.create_import(request)`, `claim_video(import_id, video_id) -> bool`, `complete_video(import_id, result)`, `fail_video(import_id, video_id, retryable, code)`, `get_status(import_id)`, and `list_results(import_id)`.

- [ ] **Step 1: Add `boto3` and `pytest` to requirements and write failing adapter tests**

Use a fake DynamoDB resource implementing `put_item`, `update_item`, `get_item`, and `query`; assert duplicate `clientImportID` returns the original import, only the first claim succeeds, duplicate completion does not increment `done` twice, and completion changes import state when `done == total`.

- [ ] **Step 2: Run tests and confirm failure**

Run: `cd services/webhook && pytest -q test_cloud_import_store.py`
Expected: FAIL because `DynamoImportStore` is missing.

- [ ] **Step 3: Implement single-table keys and conditional writes**

Use `PK=INSTALL#test-group, SK=CLIENT#<clientImportID>` for idempotency, `PK=IMPORT#<id>, SK=META` for counters, and `PK=IMPORT#<id>, SK=VIDEO#<videoID>` for stage/result state. Claims use a conditional transition from `queued`/`retryable` to `running`; completion conditionally transitions from nonterminal state and increments the META counter in one `TransactWriteItems` call.

- [ ] **Step 4: Run store tests**

Run: `cd services/webhook && pytest -q test_cloud_import_store.py`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add services/webhook/requirements.txt services/webhook/cloud_import_store.py services/webhook/test_cloud_import_store.py
git commit -m "feat(import): add durable import state store"
```

### Task 3: SQS adapter and asynchronous import API

**Files:**
- Create: `services/webhook/cloud_import_queue.py`
- Create: `services/webhook/cloud_import_api.py`
- Create: `services/webhook/test_cloud_import_api.py`
- Modify: `services/webhook/app.py`

**Interfaces:**
- Consumes: `DynamoImportStore` and Task 1 request/response models.
- Produces: `POST /v1/imports`, `GET /v1/imports/{import_id}`, `GET /v1/imports/{import_id}/results` and `SQSImportQueue.enqueue(import_id, video_id)`.

- [ ] **Step 1: Write failing FastAPI tests with injected fake store/queue**

```python
def test_submit_returns_before_processing(client, auth_headers):
    response = client.post("/v1/imports", headers=auth_headers, json=payload(2))
    assert response.status_code == 202
    assert response.json()["state"] == "accepted"
    assert fake_queue.messages == [
        {"importID": response.json()["importID"], "videoID": "1", "stage": "fast_pass"},
        {"importID": response.json()["importID"], "videoID": "2", "stage": "fast_pass"},
    ]

def test_submit_is_idempotent(client, auth_headers):
    first = client.post("/v1/imports", headers=auth_headers, json=payload(2))
    second = client.post("/v1/imports", headers=auth_headers, json=payload(2))
    assert second.json()["importID"] == first.json()["importID"]
    assert len(fake_queue.messages) == 2
```

Also assert 401 without the existing bearer token, 422 for invalid hosts, status counters, and stable result ordering.

- [ ] **Step 2: Run API tests and confirm route failure**

Run: `cd services/webhook && pytest -q test_cloud_import_api.py`
Expected: FAIL with 404 for `/v1/imports`.

- [ ] **Step 3: Implement queue adapter, dependency factories, and routes**

Use environment variables `STASH_IMPORT_TABLE`, `STASH_IMPORT_QUEUE_URL`, `AWS_REGION`, and existing `STASH_API_TOKEN`. Enqueue only when `create_import` reports `created=True`. Return 202 for both first and idempotent submissions.

- [ ] **Step 4: Run API and legacy tests**

Run: `cd services/webhook && pytest -q test_cloud_import_api.py && python test_app.py && python api_v1.py`
Expected: all PASS and both self-checks print OK.

- [ ] **Step 5: Commit**

```bash
git add services/webhook/cloud_import_queue.py services/webhook/cloud_import_api.py services/webhook/test_cloud_import_api.py services/webhook/app.py
git commit -m "feat(import): accept asynchronous cloud imports"
```

### Task 4: One-video fast-pass pipeline and worker

**Files:**
- Create: `services/webhook/cloud_import_pipeline.py`
- Create: `services/webhook/cloud_import_worker.py`
- Create: `services/webhook/test_cloud_import_worker.py`

**Interfaces:**
- Produces: `FastPassPipeline.process(url) -> VideoResult`, `handle_message(message, store, pipeline) -> HandleResult`, and `run_forever()`.

- [ ] **Step 1: Write failing worker tests**

Mock subprocess and Bedrock HTTP responses. Assert metadata maps from yt-dlp JSON, empty metadata becomes unavailable, a second delivery after completion performs no provider calls, transient exceptions call `fail_video(... retryable=True ...)` without deleting the SQS message, hard failures are recorded and deleted, and successful completion deletes the message only after the transaction succeeds.

- [ ] **Step 2: Run tests and confirm missing implementation**

Run: `cd services/webhook && pytest -q test_cloud_import_worker.py`
Expected: FAIL because worker modules are missing.

- [ ] **Step 3: Implement the minimal fast pass**

Run yt-dlp with `--dump-single-json --skip-download --no-warnings --socket-timeout 30`. Map `description`, `tags`, `uploader`, `thumbnail`, `duration`, `track`, and `artist`. Reuse the validated analyzer prompt and Bedrock token logic from `api_v1.py`, but extract shared pure helpers rather than calling the local HTTP endpoint. Classify timeouts, HTTP 429, and 5xx as retryable; validation and other 4xx as hard failures.

- [ ] **Step 4: Run worker and full backend tests**

Run: `cd services/webhook && pytest -q && python test_app.py && python api_v1.py`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add services/webhook/cloud_import_pipeline.py services/webhook/cloud_import_worker.py services/webhook/test_cloud_import_worker.py services/webhook/api_v1.py
git commit -m "feat(import): process durable fast-pass jobs"
```

### Task 5: AWS queue/table/IAM infrastructure

**Files:**
- Modify: `infra/aws-box/main.tf`

**Interfaces:**
- Produces Terraform outputs `import_table_name`, `import_queue_url`, and `import_dead_letter_queue_url`; grants the EC2 instance least-privilege access.

- [ ] **Step 1: Add Terraform resources**

Add an encrypted SQS standard queue with a dead-letter queue, five receives before redrive, 300-second visibility timeout, and 14-day retention. Add a DynamoDB PAY_PER_REQUEST table with string `PK` and `SK`, point-in-time recovery, and server-side encryption. Add an EC2 role, instance profile, and policy restricted to these exact queue/table ARNs; attach the profile to `aws_instance.box`.

- [ ] **Step 2: Format and validate**

Run: `terraform -chdir=infra/aws-box fmt -check && terraform -chdir=infra/aws-box init -backend=false && terraform -chdir=infra/aws-box validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Inspect the plan without applying**

Run: `terraform -chdir=infra/aws-box plan`
Expected: new SQS, DynamoDB, IAM resources and an in-place instance profile attachment; no EC2 replacement.

- [ ] **Step 4: Commit**

```bash
git add infra/aws-box/main.tf
git commit -m "infra(import): provision durable cloud job resources"
```

Do not run `terraform apply` until the user explicitly approves the displayed plan.

### Task 6: Worker service, deployment packaging, and 50-video smoke tool

**Files:**
- Create: `services/webhook/stash-import-worker.service`
- Create: `services/webhook/smoke_cloud_import.py`
- Modify: `services/webhook/deploy.sh`
- Modify: `services/webhook/README.md`

**Interfaces:**
- Consumes all earlier tasks.
- Produces a deployable API/worker pair and a repeatable live release gate.

- [ ] **Step 1: Add independent worker service**

Use the same `stash` user, working directory, venv, and environment file as the API. Set `ExecStart=/opt/stash-webhook/venv/bin/python cloud_import_worker.py`, `Restart=always`, `RestartSec=5`, and a 30-second stop timeout.

- [ ] **Step 2: Fix deployment packaging**

Change `deploy.sh` to install `ffmpeg`, copy every Python module plus both service units and `requirements.txt` into `/opt/stash-webhook`, run `pytest -q`, reload systemd, and enable/restart both services. Preserve the existing health check.

- [ ] **Step 3: Add the live smoke tool**

The tool reads `STASH_BASE_URL`, `STASH_API_TOKEN`, and a JSON array of exactly 50 normalized bookmarks, submits a UUID `clientImportID`, polls every five seconds, prints monotonic progress, fails after 30 minutes, and exits nonzero unless `state=completed`, `done=50`, and results contain 50 unique video IDs. It must never print the bearer token.

- [ ] **Step 4: Run local verification**

Run: `cd services/webhook && pytest -q && python test_app.py && python api_v1.py`
Expected: all PASS.

Run: `git diff --check`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add services/webhook/stash-import-worker.service services/webhook/smoke_cloud_import.py services/webhook/deploy.sh services/webhook/README.md
git commit -m "ops(import): deploy worker and add live smoke gate"
```

## Final checkpoint

Before any production mutation, present the Terraform plan, deployment diff, expected AWS monthly delta, and rollback commands to the user. After approval, apply infrastructure, deploy, run the 50-video smoke import, restart the worker around item 20, and report elapsed time, provider cost, duplicates, unavailable videos, failures, and whether all 50 unique results were returned.
