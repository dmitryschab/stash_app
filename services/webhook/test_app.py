"""Self-check for the signature path. Run: python test_app.py (from this dir)."""
import hashlib
import hmac

import app as m


def main():
    m.CLIENT_SECRET = ""
    assert m.verify_signature(b"x", None) is True, "dev mode should pass through"

    m.CLIENT_SECRET = "secret"
    body = b'{"a":1}'
    good = hmac.new(b"secret", body, hashlib.sha256).hexdigest()
    assert m.verify_signature(body, good) is True, "valid signature should pass"
    assert m.verify_signature(body, "deadbeef") is False, "wrong signature should fail"
    assert m.verify_signature(body, None) is False, "missing signature should fail"
    print("OK: signature checks pass")


if __name__ == "__main__":
    main()
