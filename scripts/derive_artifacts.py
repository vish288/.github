#!/usr/bin/env python3
"""Derive the release-tracked artifacts from their sources.

All stay committed on purpose: the Gemini CLI installs ``gemini-extension.json``
straight from the repo, Claude Code reads ``.claude-plugin/plugin.json`` and
``.mcp.json`` from a cloned plugin, and ``llms.txt`` is fetched from ``main``.
Hand-maintaining them let their versions drift from ``server.json``; instead a
release bumps only the sources and runs this script.

- ``gemini-extension.json``: derived entirely from ``server.json`` -- ``name`` and
  ``version`` from the package identifier and version, ``description`` from the
  registry description, ``settings`` from ``environmentVariables`` under Gemini's
  field names (``required``/``sensitive``).
- ``.claude-plugin/plugin.json`` + ``.mcp.json``: the Claude Code plugin bundle,
  also from ``server.json``. ``plugin.json`` carries the metadata and a
  ``userConfig`` prompt per surfaced environment variable (``sensitive`` on the
  secrets); ``.mcp.json`` launches ``uvx <identifier>@<version>`` and maps each
  var to its ``${user_config.<key>}`` reference. "Surfaced" means required or
  secret, plus ``MCP_READ_ONLY``, minus the HTTP-transport-only vars (the HTTP
  bearer token and the OAuth-proxy settings; see ``_is_http_transport_only``) that
  a stdio launch never uses -- and ``_plugin_env_vars`` explains why every kept var
  is safe left blank. The same set backs both files, so every ``${user_config.KEY}``
  the server config references is a declared ``userConfig`` option (which
  ``claude plugin validate`` requires).
- ``llms.txt``: the byte-exact prefix of ``llms-full.txt`` up to the first
  section that only the full document carries. The heading that marks that cut
  differs per server (``## Configuration``, ``## Environment Variables``,
  ``## Setup Examples``), so it is read from ``$LLMS_SPLIT_MARKER`` and defaults
  to ``\n## Configuration``. Before the split, the ``- **Python**: >=X.Y`` line
  in ``llms-full.txt`` is rewritten from ``pyproject.toml``'s ``requires-python``
  so the stated floor (which lands in the prefix too) cannot drift from the code.

Run from the repo root (the release workflow runs it there, after the version
bump); it rewrites both files in place. Stdlib only, so the release workflow
needs no dependencies to invoke it.
"""

from __future__ import annotations

import json
import os
import re
import sys
import tomllib
from pathlib import Path

ROOT = Path.cwd()
SERVER_JSON = ROOT / "server.json"
PYPROJECT = ROOT / "pyproject.toml"
LLMS_FULL = ROOT / "llms-full.txt"
LLMS_SPLIT_MARKER = os.environ.get("LLMS_SPLIT_MARKER") or "\n## Configuration"


def derive_gemini_extension() -> str:
    """gemini-extension.json from server.json — the single source, as in the
    sibling servers. Settings are the registry's environment variables under
    Gemini's field names; the description is the registry description."""
    server = json.loads(SERVER_JSON.read_text(encoding="utf-8"))
    pkg = server["packages"][0]
    identifier = pkg["identifier"]
    data = {
        "name": identifier,
        "version": server["version"],
        "description": server["description"],
        "mcpServers": {identifier: {"command": "uvx", "args": [f"{identifier}@{server['version']}"]}},
        "settings": [
            {
                "name": env["name"],
                "description": env["description"],
                "required": env["isRequired"],
                "sensitive": env["isSecret"],
            }
            for env in pkg["environmentVariables"]
        ],
    }
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def _is_http_transport_only(name: str) -> bool:
    """Whether an env var only does something under an HTTP transport, making it a dead
    prompt in a stdio plugin launch (``uvx <id>@<ver>``, the only thing .mcp.json runs):

    - ``*_HTTP_BEARER_TOKEN`` gates a non-loopback HTTP bind; stdio never reaches that code.
    - ``*_OAUTH_*`` configures the OAuth 2.1 proxy, which the server refuses on any transport
      but streamable-http (mcp-gitlab ``__init__.py:141``: ``auth == "oauth" and transport !=
      "streamable-http"`` exits 2). No other surfaced var is HTTP-only -- the upstream API
      token/URL/PAT and MCP_READ_ONLY all apply over stdio.

    The patterns track a stable naming convention across the fleet; the justification is the
    behaviour above, confirmed against the servers on origin/main, not the names alone."""
    return name.endswith("_HTTP_BEARER_TOKEN") or "_OAUTH_" in name


def _plugin_env_vars(pkg: dict) -> list[dict]:
    """Environment variables surfaced to the Claude Code plugin: required or secret, plus
    MCP_READ_ONLY as an optional toggle, minus the HTTP-transport-only vars
    (``_is_http_transport_only``).

    Everything kept is safe when left blank: Claude Code substitutes an unset optional option
    as an empty string (verified against the CLI), and every server reads these via
    ``os.getenv(...)`` with a falsy/``or`` fallback, so empty reads as "not set" -- an empty
    token yields no auth header, and an empty MCP_READ_ONLY does not lock (``_FALSEY`` includes
    ``""``). The same set backs plugin.json's userConfig and .mcp.json's env, so no
    ``${user_config.KEY}`` reference is left undeclared."""
    return [
        env
        for env in pkg["environmentVariables"]
        if (env["isRequired"] or env["isSecret"] or env["name"] == "MCP_READ_ONLY")
        and not _is_http_transport_only(env["name"])
    ]


def derive_plugin_json() -> str:
    """.claude-plugin/plugin.json from server.json. homepage must parse as a URL
    (Claude Code refuses the plugin otherwise), so it falls back to the repository
    URL when websiteUrl is absent."""
    server = json.loads(SERVER_JSON.read_text(encoding="utf-8"))
    pkg = server["packages"][0]
    identifier = pkg["identifier"]
    data = {
        "name": identifier,
        "displayName": server.get("title") or identifier,
        "version": server["version"],
        "description": server["description"],
        "author": {"name": "vish288"},
        "homepage": server.get("websiteUrl") or server["repository"]["url"],
        "repository": server["repository"]["url"],
        "license": "MIT",
        "userConfig": {
            env["name"].lower(): {
                "type": "string",
                "title": env["name"],
                "description": env["description"],
                "required": env["isRequired"],
                "sensitive": env["isSecret"],
            }
            for env in _plugin_env_vars(pkg)
        },
    }
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def derive_mcp_json() -> str:
    """.mcp.json from server.json: launch uvx with the pinned identifier and map each
    surfaced env var to its ${user_config.<key>} reference. The server key drops the
    mcp- prefix so Claude Code lists it as plugin:<identifier>:<short>."""
    server = json.loads(SERVER_JSON.read_text(encoding="utf-8"))
    pkg = server["packages"][0]
    identifier = pkg["identifier"]
    short = identifier.removeprefix("mcp-") or identifier
    data = {
        "mcpServers": {
            short: {
                "command": "uvx",
                "args": [f"{identifier}@{server['version']}"],
                "env": {env["name"]: f"${{user_config.{env['name'].lower()}}}" for env in _plugin_env_vars(pkg)},
            }
        }
    }
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def rewrite_python_floor() -> None:
    """Rewrite the ``- **Python**: >=X.Y`` line in llms-full.txt from pyproject's
    ``requires-python`` so llms.txt (its prefix) cannot drift from the real floor.

    A no-op when either file is absent or no floor is stated; the line lives in the
    llms.txt prefix, so this must run before derive_llms_txt."""
    if not (PYPROJECT.exists() and LLMS_FULL.exists()):
        return
    requires = tomllib.loads(PYPROJECT.read_text(encoding="utf-8")).get("project", {}).get("requires-python", "")
    floor = re.search(r">=\s*(\d+\.\d+)", requires)
    if not floor:
        return
    text = LLMS_FULL.read_text(encoding="utf-8")
    new = re.sub(r"(?m)^- \*\*Python\*\*: .*$", f"- **Python**: >={floor.group(1)}", text)
    if new != text:
        LLMS_FULL.write_text(new, encoding="utf-8")


def derive_llms_txt() -> str:
    """Return llms.txt: the prefix of llms-full.txt before ## Configuration."""
    full = LLMS_FULL.read_text(encoding="utf-8")
    if LLMS_SPLIT_MARKER not in full:
        msg = (
            f"llms-full.txt has no {LLMS_SPLIT_MARKER!r} section; llms.txt can no "
            "longer be derived as its prefix -- update scripts/derive_artifacts.py."
        )
        raise SystemExit(msg)
    return full.split(LLMS_SPLIT_MARKER, 1)[0]


def main() -> int:
    (ROOT / "gemini-extension.json").write_text(derive_gemini_extension(), encoding="utf-8")
    plugin_dir = ROOT / ".claude-plugin"
    plugin_dir.mkdir(exist_ok=True)
    (plugin_dir / "plugin.json").write_text(derive_plugin_json(), encoding="utf-8")
    (ROOT / ".mcp.json").write_text(derive_mcp_json(), encoding="utf-8")
    rewrite_python_floor()
    (ROOT / "llms.txt").write_text(derive_llms_txt(), encoding="utf-8")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
