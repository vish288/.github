#!/usr/bin/env python3
"""Derive the two release-tracked artifacts from their sources.

Both files stay committed on purpose: the Gemini CLI installs
``gemini-extension.json`` straight from the repo and ``llms.txt`` is fetched
from ``main``. Hand-maintaining them let their versions drift from
``server.json``; instead a release bumps only the sources and runs this script.

- ``gemini-extension.json``: derived entirely from ``server.json`` -- ``name`` and
  ``version`` from the package identifier and version, ``description`` from the
  registry description, ``settings`` from ``environmentVariables`` under Gemini's
  field names (``required``/``sensitive``).
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
    rewrite_python_floor()
    (ROOT / "llms.txt").write_text(derive_llms_txt(), encoding="utf-8")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
