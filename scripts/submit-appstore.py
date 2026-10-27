# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt", "cryptography"]
# ///
"""Submit the build in App/project.yml to App Store review, released as soon as it is approved.

Run by release-testflight.sh after the upload, or alone to submit a build that is already up:
    ISSUER_ID=<asc-issuer-id> uv run scripts/submit-appstore.py [--dry-run]
WHATS_NEW overrides the release notes a new version gets.

What it does, in order:
- waits for the build to finish processing;
- releases a version that was approved but held for a manual release — App Store Connect will not
  open a new version while one is waiting, and under this script approved means released;
- creates the version (or reuses one still being prepared), attaches the build, sets AFTER_APPROVAL;
- submits it. A version already waiting for or in review is left alone: replacing its build would
  put it at the back of the queue, so the new build waits on TestFlight for the next run.
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import jwt

BUNDLE_ID = "dev.dmitryschab.Stash"
API = "https://api.appstoreconnect.apple.com"
PROJECT = Path(__file__).resolve().parent.parent / "App" / "project.yml"
DEFAULT_WHATS_NEW = "Fixes and improvements."

# A version in one of these states still takes a new build and can be submitted.
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"}
IN_REVIEW = {"WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE"}


def token() -> str:
    key_id = os.environ.get("KEY_ID", "8L6SFDBBSN")
    key_path = os.environ.get("KEY_PATH", os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8"))
    issuer = os.environ.get("ISSUER_ID") or sys.exit("set ISSUER_ID to the App Store Connect API issuer id")
    now = int(time.time())
    return jwt.encode({"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
                      Path(key_path).read_text(), algorithm="ES256", headers={"kid": key_id})


def call(method: str, path: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as err:
        raise SystemExit(f"{method} {path} -> {err.code}\n{err.read().decode()}") from None
    return json.loads(raw) if raw else {}


def ref(kind: str, id_: str) -> dict:
    return {"data": {"type": kind, "id": id_}}


def project_versions() -> tuple[str, str]:
    text = PROJECT.read_text()
    marketing = re.search(r'MARKETING_VERSION: "([^"]+)"', text).group(1)
    build = re.search(r'CURRENT_PROJECT_VERSION: "([^"]+)"', text).group(1)
    return marketing, build


def wait_for_build(app_id: str, marketing: str, number: str) -> str:
    path = (f"/v1/builds?filter[app]={app_id}&filter[version]={number}"
            f"&filter[preReleaseVersion.version]={marketing}&limit=1")
    deadline = time.time() + 45 * 60
    while True:
        found = call("GET", path)["data"]
        state = found[0]["attributes"]["processingState"] if found else "NOT_UPLOADED_YET"
        if state == "VALID":
            return found[0]["id"]
        if state in {"FAILED", "INVALID"} or time.time() > deadline:
            sys.exit(f"build {marketing} ({number}) is {state}; not submitting")
        print(f"build {marketing} ({number}): {state}, checking again in 30 s")
        time.sleep(30)


def main() -> None:
    dry_run = "--dry-run" in sys.argv
    marketing, number = project_versions()
    app_id = call("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"][0]["id"]
    build_id = wait_for_build(app_id, marketing, number)
    versions = call("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=10")["data"]

    held = [v for v in versions if v["attributes"]["appStoreState"] == "PENDING_DEVELOPER_RELEASE"
            and v["attributes"]["versionString"] != marketing]
    target = next((v for v in versions if v["attributes"]["versionString"] == marketing), None)
    state = target["attributes"]["appStoreState"] if target else None

    if state in IN_REVIEW:
        print(f"{marketing} is {state}; build {number} stays on TestFlight until the next run")
        return
    if target and state not in EDITABLE and state != "PENDING_DEVELOPER_RELEASE":
        sys.exit(f"{marketing} is {state}: that train is closed, bump MARKETING_VERSION in App/project.yml")

    plan = [f"release held version {v['attributes']['versionString']}" for v in held]
    if state == "PENDING_DEVELOPER_RELEASE":
        plan.append(f"release {marketing}, already approved (build {number} waits for the next version)")
    else:
        plan.append(f"{'reuse' if target else 'create'} version {marketing}, attach build {number}, AFTER_APPROVAL")
        plan.append("submit for review")
    print("plan:\n  " + "\n  ".join(plan))
    if dry_run:
        return

    for v in held + ([target] if state == "PENDING_DEVELOPER_RELEASE" else []):
        call("POST", "/v1/appStoreVersionReleaseRequests",
             {"data": {"type": "appStoreVersionReleaseRequests",
                       "relationships": {"appStoreVersion": ref("appStoreVersions", v["id"])}}})
        print(f"released {v['attributes']['versionString']}")
    if state == "PENDING_DEVELOPER_RELEASE":
        return

    if target:
        version_id = target["id"]
        call("PATCH", f"/v1/appStoreVersions/{version_id}",
             {"data": {"type": "appStoreVersions", "id": version_id, "attributes": {"releaseType": "AFTER_APPROVAL"}}})
        call("PATCH", f"/v1/appStoreVersions/{version_id}/relationships/build", ref("builds", build_id))
    else:
        body = {"data": {"type": "appStoreVersions",
                         "attributes": {"platform": "IOS", "versionString": marketing, "releaseType": "AFTER_APPROVAL"},
                         "relationships": {"app": ref("apps", app_id), "build": ref("builds", build_id)}}}
        # A version released a moment ago is still "processing" and can block a new one for a few minutes.
        for attempt in range(20):
            try:
                version_id = call("POST", "/v1/appStoreVersions", body)["data"]["id"]
                break
            except SystemExit as err:
                if attempt == 19 or "409" not in str(err).split("\n")[0]:
                    raise
                print("App Store Connect is not ready for a new version yet, retrying in 30 s")
                time.sleep(30)
        print(f"created version {marketing}")

    whats_new = os.environ.get("WHATS_NEW")
    for loc in call("GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations")["data"]:
        if whats_new or not loc["attributes"].get("whatsNew"):
            call("PATCH", f"/v1/appStoreVersionLocalizations/{loc['id']}",
                 {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"],
                           "attributes": {"whatsNew": whats_new or DEFAULT_WHATS_NEW}}})

    # A draft left by an earlier, interrupted run is reused: an app gets one open submission at a time.
    drafts = call("GET", f"/v1/reviewSubmissions?filter[app]={app_id}&filter[platform]=IOS"
                         f"&filter[state]=READY_FOR_REVIEW,UNRESOLVED_ISSUES&limit=1")["data"]
    submission_id = drafts[0]["id"] if drafts else call("POST", "/v1/reviewSubmissions", {
        "data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"},
                 "relationships": {"app": ref("apps", app_id)}}})["data"]["id"]
    items = call("GET", f"/v1/reviewSubmissions/{submission_id}/items")["data"]
    if not items:
        call("POST", "/v1/reviewSubmissionItems",
             {"data": {"type": "reviewSubmissionItems",
                       "relationships": {"reviewSubmission": ref("reviewSubmissions", submission_id),
                                         "appStoreVersion": ref("appStoreVersions", version_id)}}})
    call("PATCH", f"/v1/reviewSubmissions/{submission_id}",
         {"data": {"type": "reviewSubmissions", "id": submission_id, "attributes": {"submitted": True}}})
    print(f"submitted {marketing} ({number}) for review; it goes live as soon as Apple approves it")


if __name__ == "__main__":
    main()
