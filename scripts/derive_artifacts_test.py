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
    "description": "Example server",
    "version": "1.2.3",
    "packages": [
        {
            "identifier": "mcp-thing",
            "version": "1.2.3",
            "environmentVariables": [
                {
                    "name": "THING_TOKEN",
                    "description": "API token",
                    "isRequired": True,
                    "isSecret": True,
                }
            ],
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
        assert gemini["settings"] == [
            {
                "name": "THING_TOKEN",
                "description": "API token",
                "required": True,
                "sensitive": True,
            }
        ], gemini

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
