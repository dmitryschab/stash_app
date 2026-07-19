"""AWS session helpers for cloud-import infrastructure access."""

from __future__ import annotations

import os
from collections.abc import Callable

import boto3
from botocore.credentials import InstanceMetadataFetcher, InstanceMetadataProvider
from botocore.session import Session as BotocoreSession


def instance_role_session(
    *,
    provider=None,
    session_factory: Callable[..., object] = boto3.Session,
):
    """Build a session from the EC2 instance profile, not environment keys.

    `provider.load()` returns *refreshable* instance-metadata credentials. We hand
    that object to the session so boto3 re-fetches when the ~6 h STS token nears
    expiry. Copying `.access_key`/`.secret_key`/`.token` into the session instead
    (the previous version) froze them at process start, so every call failed with
    `ExpiredToken` a few hours in and the worker crash-looped.
    """
    provider = provider or InstanceMetadataProvider(
        iam_role_fetcher=InstanceMetadataFetcher(timeout=2, num_attempts=2)
    )
    credentials = provider.load()
    if credentials is None:
        raise RuntimeError("EC2 instance profile credentials are unavailable")
    region = os.environ.get("AWS_REGION", "eu-north-1")
    botocore_session = BotocoreSession()
    botocore_session._credentials = credentials  # the refreshable object, not a snapshot
    botocore_session.set_config_variable("region", region)
    return session_factory(botocore_session=botocore_session, region_name=region)
