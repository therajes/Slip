#!/usr/bin/env python3
"""Check the packaged authentication protocol without submitting credentials to Apple."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def main() -> None:
    app = Path(sys.argv[1] if len(sys.argv) > 1 else "native/build/Slip.app").resolve()
    core = app / "Contents/Resources/sideloom-core"
    host = subprocess.run([str(core), "host-identity"], capture_output=True, text=True,
                          timeout=20, check=True)
    identity_event = json.loads(host.stdout.splitlines()[-1])
    assert identity_event["type"] == "hostIdentity"
    checks = 1

    with tempfile.TemporaryDirectory(prefix="SlipAuthProtocol-") as storage:
        base = {"email": "fixture@example.invalid", "password": "local-only-test-fixture",
                "anisetteServer": "", "storagePath": storage,
                "authenticationMode": "remote"}
        cases = [
            ("empty account", "login", {**base, "email": ""}, True),
            ("missing provider", "login", base, True),
            ("insecure provider", "login", {**base, "anisetteServer": "http://127.0.0.1:1"}, True),
            ("provider credentials", "login", {**base, "anisetteServer": "https://user:fixture@example.invalid"}, True),
            ("missing certificate selection", "revoke-certificate", base, False),
            ("missing identifier selection", "delete-app-id", base, False),
        ]
        if identity_event["hostIdentity"].get("localAuthenticationAvailable") is False:
            cases.append(("strict local availability", "login",
                          {**base, "authenticationMode": "local",
                           "anisetteServer": "https://must-not-be-contacted.example.invalid"}, True))
        for label, command, request, structured in cases:
            result = subprocess.run([str(core), command], input=json.dumps(request) + "\n",
                                    capture_output=True, text=True, timeout=20)
            assert result.returncode != 0, label
            events = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
            assert events[-1]["type"] == "error", label
            assert not any(event["type"] == "completed" for event in events), label
            assert not any(event["type"] == "authenticationFallback" for event in events), label
            assert request["password"] not in result.stdout + result.stderr, label
            if structured:
                failure = next(event for event in events if event.get("stage") == "failed")
                assert failure["failedStage"] == "preparing", label
                assert failure["provider"] == request["authenticationMode"], label
                assert isinstance(failure["retryable"], bool), label
                assert failure["code"], label
            checks += 1
            print(f"PASS: {label}")
        assert not (Path(storage) / "dev_session.json").exists()
    print(f"{checks} packaged protocol checks passed; no Apple credentials submitted.")


if __name__ == "__main__":
    main()
