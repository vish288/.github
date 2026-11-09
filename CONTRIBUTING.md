# Contributing

Thanks for helping out. These rules apply across the `mcp-*` servers and this
shared CI repo.

## Before you open a PR

- **Gates must pass locally.** Run the same checks CI does:
  `uv run pytest -q`, `uv run ruff check .`, `uv run ruff format --check .`,
  and `uv run pyright` on the servers that ship it.
- **Conventional commit subjects** (`feat:`, `fix:`, `docs:`, `refactor:`,
  `chore:`, …). The release pipeline reads them to build the changelog and pick
  the version bump: `feat:` is a minor, `fix:`/`docs:` a patch.
- **Sign your commits.** Unsigned commits do not land.
- **Open a PR.** `main` is protected; every change arrives through a PR with
  green checks. History stays linear — no merge commits.

## Generated files — do not hand-edit

The release pipeline derives these from their sources; editing them by hand
drifts them and fails the lint drift check:

- `llms.txt` — the prefix of `llms-full.txt`.
- `gemini-extension.json` — derived from `server.json`.

Change the source (`llms-full.txt`, `server.json`, `pyproject.toml`) and let
`scripts/derive_artifacts.py` regenerate the rest.

## Versioning and deprecation

- **Semantic versioning.** Breaking changes bump the major, new features the
  minor, fixes the patch. While a server is pre-1.0 (`0.x`), a minor bump may
  carry a breaking change — read the changelog before upgrading.
- **Tool renames** keep the old tool name for **one minor** as a hidden alias,
  then remove it.
- **Environment-variable renames** keep the old name as an alias for **two
  minors**.
- **Deprecations are announced** in `CHANGELOG.md` and warned about at runtime
  on `--help` and on stderr (as the deprecated `--gitlab-token` flag already
  does) before removal.
