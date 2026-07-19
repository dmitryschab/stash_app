from types import SimpleNamespace

from cloud_import_aws import instance_role_session


def test_instance_role_session_hands_refreshable_credentials_to_session():
    # A stand-in for botocore's RefreshableCredentials: the session must receive
    # this *object* so it can refresh, not a point-in-time copy of its keys.
    credentials = SimpleNamespace(
        access_key="role-access",
        secret_key="role-secret",
        token="role-token",
    )
    provider = SimpleNamespace(load=lambda: credentials)
    calls = {}

    def session_factory(**kwargs):
        calls.update(kwargs)
        return "role-session"

    assert instance_role_session(provider=provider, session_factory=session_factory) == "role-session"
    assert calls["region_name"] == "eu-north-1"
    # The refreshable credentials object is handed over verbatim — no frozen copy.
    assert calls["botocore_session"].get_credentials() is credentials
    assert "aws_access_key_id" not in calls
