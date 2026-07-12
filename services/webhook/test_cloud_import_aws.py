from types import SimpleNamespace

from cloud_import_aws import instance_role_session


def test_instance_role_session_uses_instance_profile_credentials():
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
    assert calls == {
        "aws_access_key_id": "role-access",
        "aws_secret_access_key": "role-secret",
        "aws_session_token": "role-token",
        "region_name": "eu-north-1",
    }
