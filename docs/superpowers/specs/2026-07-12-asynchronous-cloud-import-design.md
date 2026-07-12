# Asynchronous cloud import for large TikTok libraries

Date: 2026-07-12. Status: approved for implementation planning.

## Problem

The current import is resumable, but iOS still orchestrates every video. After the
export is parsed into SwiftData, `PipelineCenter` keeps the app alive while
`PipelineRunner` performs enrichment and synchronous cloud calls per video.
`BGProcessingTask` only supplies opportunistic execution windows; it cannot promise
that a 900-video import finishes after the user leaves the app.

The replacement must let a user submit an import, close the app immediately, and
receive a notification when processing is complete. The first release supports one
owner and a small TestFlight group of at most 20 installations. A typical 900-video
import should finish as quickly as practical while keeping variable processing cost
below EUR 1.

## Goals

- The app is needed only to parse and submit the export and later synchronize results.
- Cloud work survives app termination, worker restarts, deployments, and transient
  provider failures.
- A 900-video caption-first pass normally finishes in 15–30 minutes.
- Selective transcript enhancement normally finishes in 30–90 minutes when providers
  are healthy.
- Variable provider and job-infrastructure cost is capped at USD 0.80 per import.
- Progress and partial results are visible whenever the app is opened.
- A visible APNs notification announces completion, but correctness never depends on
  notification delivery.

## Non-goals

- Public signup, user accounts, subscriptions, billing, or organization support.
- Guaranteed completion time while TikTok or model providers are throttling.
- Transcribing every video regardless of cost.
- Uploading or retaining the complete TikTok data export.
- Kubernetes, a general microservice platform, or multi-region availability.
- Replacing the existing keep-offline download endpoint.

## Architecture decision

Use a small hybrid asynchronous system:

- The existing FastAPI service remains the public API and worker host.
- Amazon SQS provides durable, at-least-once work delivery.
- DynamoDB stores installations, imports, video-stage state, progress counters, and
  estimated cost.
- S3 stores thumbnails and paginated result manifests.
- Existing EC2 capacity performs network-bound TikTok fetching and provider calls.
- APNs sends the completion alert.

This is deliberately not a microservice migration. The API and worker code remain one
deployable service with separately invoked process roles. Managed AWS primitives are
used only where durability is difficult to reproduce safely on the single EC2 box.

### Alternatives rejected

1. **In-process or SQLite-only queue on EC2.** This is the shortest implementation,
   but a bad deployment, disk issue, or queue bug can strand imports. It also makes
   safe concurrency and visibility leases bespoke work.
2. **ECS/Fargate for the complete system.** Scale-to-zero is attractive, but it adds
   container orchestration and deployment work that is not justified for 20 testers.
   Fargate remains the migration path if concurrent imports saturate the box.
3. **Full synchronous transcription.** The expected 36 audio hours in a 900-video
   library cost about USD 1.44 at USD 0.04/audio-hour before analysis, exceeding the
   product constraint.
4. **Full Groq Batch transcription as the default.** At the 50% batch discount it fits
   the variable budget, but the supported completion window begins at 24 hours. It is
   retained as an optional slower deep-import mode after the fast path is proven.

## Identity and authentication

Accounts are unnecessary for the TestFlight phase. Each app installation creates a
random installation ID and secret, stores them in Keychain, and exchanges a tester
invite code for a scoped installation credential.

- `POST /v1/installations` accepts an invite code and the installation public ID.
- The response credential is shown only once and stored in Keychain.
- Subsequent calls authenticate the installation, not a globally compiled app token.
- `PUT /v1/installations/push-token` refreshes the APNs token. The app registers on
  every launch because APNs device tokens can change.
- An installation may have one active import and at most 1,200 videos per import.
- Invite codes can be revoked without invalidating already registered testers.

The existing shared bearer token may remain temporarily for developer endpoints, but
new import endpoints must not depend on a secret compiled into TestFlight builds.

## Submission contract

The app parses the selected TikTok JSON or folder locally with `ExportParser`. It sends
only normalized bookmark records:

```json
{
  "clientImportID": "uuid",
  "videos": [
    {
      "videoID": "7651237687638101270",
      "url": "https://www.tiktok.com/@creator/video/7651237687638101270",
      "bookmarkedAt": "2026-07-01T12:00:00Z"
    }
  ]
}
```

`POST /v1/imports` validates the installation, TikTok HTTPS host, numeric video ID,
batch size, and idempotency key. It writes the import and video rows before returning:

```json
{
  "importID": "uuid",
  "state": "accepted",
  "accepted": 900,
  "duplicates": 0
}
```

The request is idempotent by installation ID plus `clientImportID`. Retrying after a
lost response returns the existing import and never duplicates charges or videos.

## Processing flow

Import states are monotonic:

`accepted -> fast_pass -> selecting -> deep_pass -> completed`

An import may also become `cancelled`; completed imports may contain partial failures.

### 1. Fast pass

The submitter enqueues one `fast-pass` SQS message per new video. A worker:

1. Claims the video stage idempotently.
2. Fetches TikTok metadata with bounded concurrency and per-host throttling.
3. Downloads the expiring cover image and writes it to S3.
4. Runs caption-first Gemma analysis using caption, hashtags, author, and sound data.
5. Stores the public result plus internal `confidence` and `needsTranscript` signals.
6. Atomically increments the import counter and estimated provider cost.

Unavailable, private, deleted, and region-locked videos become terminal
`unavailable`; they do not block the import.

### 2. Selection and cost allocation

The last completed fast-pass task triggers selection through an idempotent conditional
write. Videos receive a deterministic priority score using:

- missing or very short caption;
- low model confidence or explicit `needsTranscript`;
- recipe results missing ingredients or steps;
- coding results with little actionable detail;
- disagreement between caption, hashtags, and predicted category;
- known speech-heavy duration and available audio.

The selector orders candidates and enqueues them only while the import's remaining
budget permits. The server reserves USD 0.20 for analysis, retries, and rounding, and
allows at most USD 0.60 of synchronous Whisper Turbo transcription. At USD 0.04 per
audio hour, the expected allowance is 15 audio hours, or roughly 375 average
2.4-minute videos.

Duration discovered during metadata extraction is used for reservation. A provider's
actual billed duration replaces the reservation after completion. No worker may start
an unreserved paid stage.

### 3. Deep pass

A deep-pass worker downloads audio to a temporary directory, sends it to Groq Whisper
Large v3 Turbo, applies the existing repetition filter, and re-analyzes the video with
the transcript. Temporary audio is deleted in success and error paths. The result
replaces the fast-pass analysis only after the complete enhanced result validates.

Videos not selected retain their caption-first result and are still complete. They may
be enhanced by a future explicit deep-import feature without changing the base import
contract.

### 4. Finalization

When every selected video is terminal, one conditional finalizer:

1. Writes paginated result manifests to S3.
2. Marks the import `completed` with totals, partial-failure count, and final cost.
3. Sends a visible APNs alert containing only the import ID and navigation target.

APNs is a signal, not a transport for results.

## Status and result synchronization

`GET /v1/imports/{id}` returns monotonic progress:

```json
{
  "state": "deep_pass",
  "fastPass": { "done": 900, "total": 900 },
  "deepPass": { "done": 212, "total": 375 },
  "unavailable": 18,
  "partialFailures": 3,
  "estimatedCostUSD": 0.61,
  "updatedAt": "2026-07-12T18:00:00Z"
}
```

`GET /v1/imports/{id}/results?cursor=...` returns validated result pages and the next
cursor. Each result is versioned by video ID and analysis revision. The app upserts it
into SwiftData, so foreground polling, notification opens, and interrupted downloads
are all safe to repeat.

The app acknowledges the highest fully applied result revision. Cloud results and
thumbnails expire seven days after successful acknowledgement. Unacknowledged imports
expire after 30 days to prevent indefinite storage.

## iOS behavior

`PipelineCenter` stops executing the per-video pipeline for production imports and
becomes the owner of cloud job submission and synchronization.

- Parsing and submission remain foreground operations and should finish in seconds.
- After acceptance the UI explicitly says the app may be closed.
- The import card displays cloud state and separate fast/deep progress.
- Every app launch and foreground transition polls active import status.
- Partial fast-pass result pages may be synchronized before deep processing completes.
- Notification permission is requested after the first import is accepted, when the
  benefit is concrete.
- Tapping the completion notification opens the library and starts a result sync.
- Silent notification delivery may opportunistically refresh results, but the app does
  not rely on it.

The current local pipeline remains available behind a developer-only feature flag
during rollout. It is removed from the production path after the cloud import passes
the full-library test.

## Retry and failure semantics

- SQS delivery is at least once; every stage key is `(importID, videoID, stage)` and all
  writes are idempotent.
- Workers extend the visibility timeout while active.
- Network, TikTok throttling, HTTP 429, and provider 5xx errors retry up to five times
  with exponential backoff and jitter.
- Invalid input, provider 4xx other than 429, and malformed validated output are hard
  per-video failures.
- Exhausted tasks enter a dead-letter queue and increment `partialFailures`; they do
  not hold the import open forever.
- Worker shutdown stops claiming work and returns unfinished messages to the queue.
- Atomic conditional counters prevent duplicated deliveries from inflating progress.
- A provider outage delays completion without requiring the app to reopen.

## Security and privacy

- Only `https://www.tiktok.com`, `https://tiktok.com`, `https://vm.tiktok.com`, and
  `https://vt.tiktok.com` are accepted; every redirect is revalidated against the same
  allowlist to prevent SSRF.
- API and APNs credentials are server-side environment secrets.
- DynamoDB, S3, and EBS use encryption at rest; all public traffic uses TLS.
- S3 objects are private. The API streams results or returns short-lived signed URLs.
- Raw export files and permanent audio are never stored in the cloud.
- Logs contain installation/import IDs, stage, status, duration, and cost, but not full
  captions or transcripts.
- Per-installation rate limits and the active-import constraint limit abuse.

## Cost model

The expected 900-video library contains about 36 audio hours. Current reference costs:

- Groq Whisper Large v3 Turbo: USD 0.04/audio-hour synchronously.
- Gemma 4 26B-A4B in Bedrock Frankfurt: USD 0.16/M input tokens and USD 0.48/M
  output tokens.
- The measured 43-video pilot averaged about 528 input and 137 output tokens per video.

A normal selective import is expected to cost:

| Item | Expected USD |
|---|---:|
| Caption-first analysis of 900 videos | 0.14 |
| 15 hours of synchronous transcription | 0.60 |
| Transcript re-analysis and AWS request/storage overhead | 0.06 |
| **Hard ceiling** | **0.80** |

Actual reservations, usage, and final cost are stored on the import. The selector
stops before the hard ceiling rather than relying on an after-the-fact alert.

The existing EC2 box has an approximately USD 14 monthly fixed cost: about USD 7.88
for t3.micro compute, USD 1.67 for 20 GB gp3, USD 3.65 for the public IPv4 address,
and the remainder for DNS/logging/storage. The attached EIP is not free. At 20 active
testers this is about EUR 0.61 per tester per month before imports. The EUR 1 target is
therefore a marginal per-import goal while the existing shared box remains running;
it is not an all-in per-user TCO guarantee at this small scale.

## Observability

Structured events cover import acceptance, stage transition, retry, dead-letter,
provider duration/cost, finalization, notification response, and result acknowledgement.
Minimum dashboards/alarms:

- oldest SQS message age;
- active imports by state;
- fast/deep throughput and p50/p95 stage duration;
- retry and dead-letter counts;
- provider 429/5xx rate;
- cost per import and imports approaching the hard ceiling;
- imports with no progress for 15 minutes.

Logs retain seven days for the test phase. Alerts should be cheap CloudWatch alarms or
the existing monitoring stack, not a new paid observability service.

## Verification

### Backend contracts

- Installation registration, revocation, and APNs token refresh.
- Import authentication, validation, size limit, and idempotency.
- SSRF and redirect-host rejection.
- Status monotonicity and paginated result cursors.
- Duplicate SQS delivery and atomic counter correctness.
- Retry, visibility extension, dead-letter, and worker-restart behavior.
- Cost reservation under concurrent workers and hard-ceiling enforcement.
- Temporary audio deletion on success, timeout, cancellation, and exception.

### iOS contracts

- Keychain installation credential persistence.
- Submission retry with the same `clientImportID`.
- Cloud progress survives navigation, termination, and relaunch.
- Result pages upsert without duplicates or regression to an older revision.
- Partial results remain usable when some videos fail.
- Notification deep-link and foreground polling both converge on the same state.

### Release gates

1. A 50-video vertical slice completes after the app is force-closed.
2. Measured cost and duration are within 20% of the model above.
3. A worker is restarted mid-import without lost or duplicated results.
4. A real 900-video import completes under USD 0.80 variable cost, or stops paid work
   at the ceiling while completing all caption-first results.
5. A physical TestFlight device receives the completion notification and synchronizes
   the library.

## Rollout and migration

1. Add AWS resources, installation auth, asynchronous API contracts, and worker roles.
2. Run the 50-video backend vertical slice without changing the production app path.
3. Add the iOS cloud client, result mapper, progress UI, and APNs handling behind a
   feature flag.
4. Run the real 900-video import and tune worker concurrency against TikTok throttling.
5. Enable two testers, inspect cost/failures, then expand to 20.
6. Remove production use of the local per-video orchestrator after the cloud path is
   stable. Keep focused developer tooling for direct endpoint tests.

## Migration triggers

- Move workers from EC2 to ECS/Fargate when simultaneous imports keep the oldest SQS
  message above 15 minutes or memory limits constrain safe concurrency.
- Add user accounts when installations must span multiple devices or tester invite
  codes are no longer an adequate trust boundary.
- Offer full Groq Batch transcription when users accept a completion window of up to
  24 hours in exchange for deeper coverage under the same marginal budget.
