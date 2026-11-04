# vish288/.github

Shared GitHub Actions for the `mcp-*` servers (`mcp-gitlab`, `mcp-atlassian-extended`,
`mcp-argocd`, `mcp-coda`). The six workflows below live here once as reusable
(`workflow_call`) workflows; each server keeps a thin stub that calls them. A CI fix is now
one PR here plus a tag bump, instead of the same change landing in four repos.

## Reusable workflows

| Workflow | Trigger in the server | Inputs |
| --- | --- | --- |
| `tests.yml` | push, pull_request | `coverage_min` (number, 95), `upload_coverage` (bool, true) |
| `lint.yml` | push, pull_request | `pyright` (bool, false), `llms_split_marker` |
| `link-check.yml` | weekly schedule | — |
| `release.yml` | workflow_dispatch | `bump`, `version`, `dry_run`, `publish_fail_at`, `coverage_min`, `pyright`, `llms_split_marker`; secret `RELEASE_PAT` |
| `publish-prepare.yml` | — (called by the server's `publish.yml` stub) | `dry_run` → outputs `pypi`/`release`/`registry` |
| `publish-finish.yml` | — (called by the server's `publish.yml` stub) | `dry_run`, `fail_at`, `pypi_state` |
| `reconcile.yml` | schedule + `workflow_run` of Publish + dispatch | — |

PyPI trusted publishing cannot run inside a reusable workflow (PyPI checks the OIDC
`job_workflow_ref`), so the `pypa/gh-action-pypi-publish` job stays a top-level job in the
server's own `publish.yml` stub; `publish-prepare.yml` and `publish-finish.yml` carry
everything around it. See `AGENTS.md`.

The shared `scripts/ci/*.sh` (state/retry/reconcile) and `scripts/derive_artifacts.py` live
here too. `release.yml`, the publish phases, `reconcile.yml` and the `lint.yml` drift check
check this repo out into `.ci/` at their own commit (`job.workflow_repository` /
`job.workflow_sha`) and run the scripts from there; the scripts operate on the current working
directory, which is the calling server's checkout.

### Version-pinned install snippets

`uvx` install snippets are pinned to the released version (`uvx mcp-x@X.Y.Z`) so a copied
command installs the version the docs describe. `derive_artifacts.py` emits the pinned form in
`gemini-extension.json` (`args: ["mcp-x@X.Y.Z"]`), and on every release `release.yml` runs
`scripts/pin_install_snippets.sh`, which rewrites `<pkg>[extras]@X.Y.Z` in `README.md` and
`llms-full.txt` (both files are in the release commit). The rewrite is anchored on the server's
own package identifier with a strict `X.Y.Z`, so it leaves another tool's pin (`uvx ruff@0.6.9`),
trailing punctuation and a bare `uvx mcp-x` "try it" line alone, while covering extras, JSON args
and `uvx --from mcp-x@…`. `ci.yml` runs the script's `--self-test`. Each server does a one-time
`docs:` change adding `@<current>` to its snippets; release keeps them current after that.

## Using it from a server repo

Pin every stub to a release commit SHA. Example `tests.yml`:

```yaml
name: Tests
on: [push, pull_request]
jobs:
  test:
    uses: vish288/.github/.github/workflows/tests.yml@<sha> # v1.0.0
    with:
      coverage_min: 98
```

Pin the commit SHA with a `# vX.Y.Z` comment so the ref is immutable. Copier renders these pins
from the template tag and `scripts/fleet-update.sh` moves them on each release; Dependabot ignores
`vish288/.github` refs. See `AGENTS.md` for the full stub contract, including the `publish.yml` /
PyPI trusted-publishing requirement.

## Copier template

`template/` is a [Copier](https://copier.readthedocs.io) template that renders the non-runtime
files every server carries — the six workflow stubs, `Dockerfile`, `dependabot.yml`, `LICENSE`,
`.gitignore`, `.dockerignore` and `ruff.toml` — from four answers (`service`, `coverage_min`,
`pyright`, `llms_split_marker`). One template release updates all four servers' stubs and their
SHA pins in one command.

Adopt or update a server (run with Copier 9.19+ via `uvx`, no global install):

```bash
# first adoption
uvx copier copy --trust -r vX.Y.Z gh://vish288/.github .
# later updates (fan-out script does this for all four)
uvx copier update --trust --defaults --conflict rej -r vX.Y.Z
```

The stub SHA pins render from the template tag's own commit (`_copier_conf.vcs_ref_hash`), so a
stub generated from `vX.Y.Z` pins `vX.Y.Z`'s commit. The owner fans a release out with
`scripts/fleet-update.sh vX.Y.Z [--codemod <path>]` (one signed branch + PR per repo; `--dry-run`
to preview; repo paths from `--repos-dir` or `$MCP_FLEET_ROOT`). `ci.yml` renders the four
committed answer sets, golden-diffs them and actionlints the output. See `AGENTS.md` for the
answers table, the bracket-delimiter requirement, the `ruff.toml` move and the drift check.

## Versioning

Tags are semver only (`vX.Y.Z`) and never move. Servers pin the tag's commit SHA with a
`# vX.Y.Z` comment; Copier and `scripts/fleet-update.sh` own those pins and move them on each
release, and Dependabot ignores `vish288/.github` refs. A breaking change to an input or contract
bumps the major (`v2.0.0`).

### v1.2.0 — breaking for adopters

Despite the minor version, **v1.2.0 is a breaking update for a server that adopts it**, so a
fan-out PR cannot be a no-op:

- The test matrix drops Python 3.10 (3.11–3.14). A server that moves to this pin must also
  raise `requires-python` to `>=3.11`, or its `test (3.10)` job disappears while 3.10 code lingers.
- Install snippets are version-pinned. The drift check now expects `gemini-extension.json` (and
  `llms.txt`) regenerated by this tag's `derive_artifacts.py`, so `fleet-update.sh` regenerates
  them in the fan-out commit; a stale server that only bumps the pin fails the check.

Note the brief window during a release where the commit pins a version (in README, `llms-full.txt`
and `gemini-extension.json`) before that version is live on PyPI — a `uvx mcp-x@<new>` copied in
those minutes fails until the publish job finishes.

## License

MIT — see `LICENSE`.
