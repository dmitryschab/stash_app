"""AWS session helpers for cloud-import infrastructure access."""

from __future__ import annotations

import os
from collections.abc import Callable

import boto3
from botocore.credentials import InstanceMetadataFetcher, InstanceMetadataProvider


def instance_role_session(
    *,
    provider=None,
    session_factory: Callable[..., object] = boto3.Session,
):
    """Build a session from the EC2 instance profile, not environment keys."""
    provider = provider or InstanceMetadataProvider(
        iam_role_fetcher=InstanceMetadataFetcher(timeout=2, num_attempts=2)
    )
    credentials = provider.load()
    if credentials is None:
        raise RuntimeError("EC2 instance profile credentials are unavailable")
    return session_factory(
        aws_access_key_id=credentials.access_key,
        aws_secret_access_key=credentials.secret_key,
        aws_session_token=credentials.token,
        region_name=os.environ.get("AWS_REGION", "eu-north-1"),
    )
