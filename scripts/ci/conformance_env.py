#!/usr/bin/env python3
"""Derive the dummy environment for the conformance job from server.json.

Required/secret variables are set to ``x``; ``*_URL`` variables to
``https://127.0.0.1:9``; ``MCP_READ_ONLY=true`` is added. HTTP-transport-only auth
variables (``*_HTTP_BEARER_TOKEN``, ``*_OAUTH_*``) are excluded: a bearer token gates
``/mcp`` and a short one makes gitlab exit at startup. Optional overrides in
``.github/conformance-env`` (``NAME=value`` lines, rendered from the ``conformance_env``
answer) win.

Usage: python scripts/ci/conformance_env.py [--self-test]
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from derive_artifacts import _is_http_transport_only  # noqa: E402


def derive() -> dict[str, str]:
    root = Path.cwd()
    server = json.loads((root / "server.json").read_text(encoding="utf-8"))
    env: dict[str, str] = {}
    for var in server["packages"][0].get("environmentVariables", []):
        name = var["name"]
        if _is_http_transport_only(name):
            continue
        if name.upper().endswith("_URL"):
            env[name] = "https://127.0.0.1:9"
        elif var.get("isRequired") or var.get("isSecret"):
            env[name] = "x"
    env["MCP_READ_ONLY"] = "true"
    override = root / ".github" / "conformance-env"
    if override.exists():
        for line in override.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and "=" in line:
                key, _, value = line.partition("=")
                env[key.strip()] = value
    return env


def _self_test() -> int:
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        (root / ".github").mkdir()
        (root / "server.json").write_text(
            json.dumps(
                {
                    "packages": [
                        {
                            "environmentVariables": [
                                {"name": "GITLAB_URL", "isRequired": True},
                                {"name": "GITLAB_TOKEN", "isRequired": True, "isSecret": True},
                                {"name": "GITLAB_HTTP_BEARER_TOKEN", "isSecret": True},
                                {"name": "GITLAB_OAUTH_CLIENT_SECRET", "isSecret": True},
                                {"name": "MCP_READ_ONLY"},
                            ]
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
        tricky = "a b$c"  # space + shell metachar: must round-trip through `. file` unchanged
        (root / ".github" / "conformance-env").write_text(
            f"EXTRA=1\nTRICKY={tricky}\n", encoding="utf-8"
        )
        old = os.getcwd()
        os.chdir(root)
        try:
            env = derive()
        finally:
            os.chdir(old)
        assert env["GITLAB_URL"] == "https://127.0.0.1:9"
        assert env["GITLAB_TOKEN"] == "x"
        assert env["MCP_READ_ONLY"] == "true"
        assert env["EXTRA"] == "1"
        assert env["TRICKY"] == tricky
        assert "GITLAB_HTTP_BEARER_TOKEN" not in env
        assert "GITLAB_OAUTH_CLIENT_SECRET" not in env
        # Render as the CLI does and source it through bash to prove the quoting round-trips.
        envfile = root / "rendered.env"
        envfile.write_text(
            "".join(f"{k}={shlex.quote(v)}\n" for k, v in env.items()), encoding="utf-8"
        )
        sourced = subprocess.run(
            ["bash", "-c", f'set -a; . {shlex.quote(str(envfile))}; set +a; printf %s "$TRICKY"'],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        assert sourced == tricky, f"round-trip changed value: {sourced!r} != {tricky!r}"
    print("ok   conformance_env")
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return _self_test()
    env = derive()
    for key in sorted(env):
        # shlex.quote so a value with spaces or shell metacharacters survives `set -a; . file`.
        print(f"{key}={shlex.quote(env[key])}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
