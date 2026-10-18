#!/usr/bin/env python3
"""Delete the ``[tool.ruff*]`` tables from a server's pyproject.toml.

The fleet moves ruff config to a template-owned ``ruff.toml`` (which Ruff reads in preference
to pyproject, and Ruff ignores a pyproject that has no ``[tool.ruff]`` section). This migration
removes the now-redundant blocks and preserves every other comment, key and ordering via
tomlkit. It is idempotent (a second run is a no-op) and exits 0 when there is nothing to remove,
so it is safe to run on a repo that has not adopted the template yet.

Run it at adoption time (the fan-out / adoption step), not as a Copier ``_migrations`` entry:
Copier adoption is ``copier copy``, and ``_migrations`` only run on ``copier update``.

    uv run --with tomlkit python scripts/migrations/drop_tool_ruff.py path/to/pyproject.toml

Run Python with ``-I`` when invoking on an untrusted tree so a planted module cannot shadow an
import.
"""

from __future__ import annotations

import sys
from pathlib import Path

import tomlkit


def drop_tool_ruff(text: str) -> tuple[str, bool]:
    """Return (new_text, changed) with every ``tool.ruff*`` table removed."""
    doc = tomlkit.parse(text)
    tool = doc.get("tool")
    if tool is None or "ruff" not in tool:
        return text, False
    del tool["ruff"]  # nested tool.ruff.lint[.per-file-ignores] go with it
    return tomlkit.dumps(doc), True


def main(argv: list[str]) -> int:
    path = Path(argv[0]) if argv else Path("pyproject.toml")
    if not path.is_file():
        print(f"drop_tool_ruff: {path} not found; nothing to do")
        return 0
    new_text, changed = drop_tool_ruff(path.read_text())
    if changed:
        path.write_text(new_text)
        print(f"drop_tool_ruff: removed [tool.ruff*] from {path}")
    else:
        print(f"drop_tool_ruff: no [tool.ruff*] in {path}; nothing to do")
    return 0


def _self_test() -> int:
    before = (
        '[project]\nname = "mcp-x"\n\n'
        '[tool.ruff]\nline-length = 100\n\n'
        '[tool.ruff.lint]\nselect = ["E"]\n\n'
        '[tool.ruff.lint.per-file-ignores]\n"tests/**" = ["S101"]\n\n'
        '[tool.pytest.ini_options]\ntestpaths = ["tests"]\n'
    )
    out, changed = drop_tool_ruff(before)
    assert changed is True, "should report a change"
    assert "tool.ruff" not in out, f"ruff tables survived:\n{out}"
    assert "[project]" in out and 'name = "mcp-x"' in out, "clobbered [project]"
    assert "[tool.pytest.ini_options]" in out, "clobbered [tool.pytest]"
    # Idempotent: second pass is a no-op.
    out2, changed2 = drop_tool_ruff(out)
    assert changed2 is False and out2 == out, "second run must be a no-op"
    # Absent is fine.
    _, changed3 = drop_tool_ruff('[project]\nname = "x"\n')
    assert changed3 is False, "absent ruff must report no change"
    print("drop_tool_ruff self-test: OK")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "--self-test":
        raise SystemExit(_self_test())
    raise SystemExit(main(args))
