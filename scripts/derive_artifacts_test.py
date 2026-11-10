#!/usr/bin/env python3
"""Self-contained check for derive_artifacts.py. No framework: run it directly.

    python3 scripts/derive_artifacts_test.py

It builds a throwaway server.json + llms-full.txt in a temp dir, runs the real script
there as a subprocess (the script keys off the current working directory and the
LLMS_SPLIT_MARKER env var), and asserts the two derived files.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "derive_artifacts.py"

SERVER = {
    "name": "io.github.example/thing",
    "title": "Thing",
    "description": "Example server",
    "version": "1.2.3",
    "repository": {"url": "https://github.com/example/thing", "source": "github"},
    "websiteUrl": "https://example.com/thing",
    "packages": [
        {
            "identifier": "mcp-thing",
            "version": "1.2.3",
            "environmentVariables": [
                {"name": "THING_TOKEN", "description": "API token", "isRequired": True, "isSecret": True},
                {"name": "THING_URL", "description": "Base URL", "isRequired": True, "isSecret": False},
                # Neither required nor secret, not MCP_READ_ONLY: excluded from the plugin bundle.
                {"name": "THING_READ_ONLY", "description": "alias", "isRequired": False, "isSecret": False},
                {"name": "MCP_READ_ONLY", "description": "lock", "isRequired": False, "isSecret": False},
                # Two HTTP-transport-only secrets: excluded from the plugin bundle (kept by Gemini).
                {"name": "THING_HTTP_BEARER_TOKEN", "description": "bearer", "isRequired": False, "isSecret": True},
                {"name": "THING_OAUTH_CLIENT_SECRET", "description": "oauth", "isRequired": False, "isSecret": True},
            ],
        },
        {
            # A second package (oci) must not affect the derived artifacts: both
            # derive_artifacts.py and pin_install_snippets.sh read packages[0] (pypi).
            "registryType": "oci",
            "identifier": "ghcr.io/example/mcp-thing:1.2.3",
            "version": "1.2.3",
            "transport": {"type": "stdio"},
            "environmentVariables": [],
        }
    ],
}

PYPROJECT = '[project]\nname = "mcp-thing"\nrequires-python = ">=3.11"\n'

# The Python line is stale (>=3.10) on purpose: the script must rewrite it from
# requires-python before it splits llms.txt off the prefix.
LLMS_FULL = "# Thing\n\n- **Python**: >=3.10\n\nIntro line.\n\n## Configuration\n\nfull-only section\n"


def main() -> int:
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        (root / "server.json").write_text(json.dumps(SERVER), encoding="utf-8")
        (root / "pyproject.toml").write_text(PYPROJECT, encoding="utf-8")
        (root / "llms-full.txt").write_text(LLMS_FULL, encoding="utf-8")

        subprocess.run(  # noqa: S603 - fixed argv, trusted script path
            [sys.executable, "-I", str(SCRIPT)],
            cwd=root,
            check=True,
            env={"LLMS_SPLIT_MARKER": "\n## Configuration", "PATH": ""},
        )

        gemini = json.loads((root / "gemini-extension.json").read_text(encoding="utf-8"))
        assert gemini["name"] == "mcp-thing", gemini
        assert gemini["version"] == "1.2.3", gemini
        assert gemini["mcpServers"]["mcp-thing"] == {"command": "uvx", "args": ["mcp-thing@1.2.3"]}
        assert [s["name"] for s in gemini["settings"]] == [
            "THING_TOKEN",
            "THING_URL",
            "THING_READ_ONLY",
            "MCP_READ_ONLY",
            "THING_HTTP_BEARER_TOKEN",
            "THING_OAUTH_CLIENT_SECRET",
        ], gemini
        assert gemini["settings"][0] == {
            "name": "THING_TOKEN",
            "description": "API token",
            "required": True,
            "sensitive": True,
        }, gemini

        # plugin.json: metadata + one userConfig option per surfaced env var (required
        # or secret, plus MCP_READ_ONLY). THING_READ_ONLY is neither; THING_HTTP_BEARER_TOKEN
        # and THING_OAUTH_CLIENT_SECRET are HTTP-transport-only secrets. All three are excluded.
        plugin = json.loads((root / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))
        assert plugin["name"] == "mcp-thing", plugin
        assert plugin["displayName"] == "Thing", plugin
        assert plugin["version"] == "1.2.3", plugin
        assert plugin["homepage"] == "https://example.com/thing", plugin
        assert plugin["repository"] == "https://github.com/example/thing", plugin
        assert plugin["license"] == "MIT", plugin
        assert set(plugin["userConfig"]) == {
            "thing_token",
            "thing_url",
            "mcp_read_only",
        }, plugin
        assert "thing_http_bearer_token" not in plugin["userConfig"], plugin
        assert "thing_oauth_client_secret" not in plugin["userConfig"], plugin
        assert plugin["userConfig"]["thing_token"] == {
            "type": "string",
            "title": "THING_TOKEN",
            "description": "API token",
            "required": True,
            "sensitive": True,
        }, plugin
        assert plugin["userConfig"]["thing_url"]["required"] is True
        assert plugin["userConfig"]["thing_url"]["sensitive"] is False

        # .mcp.json: uvx launch pinned to the version, env mapped to ${user_config.<key>},
        # server key dropping the mcp- prefix (-> plugin:mcp-thing:thing in Claude Code).
        mcp = json.loads((root / ".mcp.json").read_text(encoding="utf-8"))
        assert set(mcp["mcpServers"]) == {"thing"}, mcp
        srv = mcp["mcpServers"]["thing"]
        assert srv["command"] == "uvx", srv
        assert srv["args"] == ["mcp-thing@1.2.3"], srv
        assert srv["env"] == {
            "THING_TOKEN": "${user_config.thing_token}",
            "THING_URL": "${user_config.thing_url}",
            "MCP_READ_ONLY": "${user_config.mcp_read_only}",
        }, srv
        assert "THING_HTTP_BEARER_TOKEN" not in srv["env"], srv
        assert "THING_OAUTH_CLIENT_SECRET" not in srv["env"], srv

        # The Python floor was rewritten from requires-python in llms-full.txt (and so
        # in the derived prefix), not left at the stale >=3.10.
        full = (root / "llms-full.txt").read_text(encoding="utf-8")
        assert "- **Python**: >=3.11" in full and ">=3.10" not in full, repr(full)
        llms = (root / "llms.txt").read_text(encoding="utf-8")
        assert llms == "# Thing\n\n- **Python**: >=3.11\n\nIntro line.\n", repr(llms)

        # An empty LLMS_SPLIT_MARKER falls back to the default instead of crashing.
        (root / "llms.txt").unlink()
        subprocess.run(  # noqa: S603 - fixed argv, trusted script path
            [sys.executable, "-I", str(SCRIPT)],
            cwd=root,
            check=True,
            env={"LLMS_SPLIT_MARKER": "", "PATH": ""},
        )
        llms = (root / "llms.txt").read_text(encoding="utf-8")
        assert llms == "# Thing\n\n- **Python**: >=3.11\n\nIntro line.\n", repr(llms)

    print("ok   derive_artifacts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
