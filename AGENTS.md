# vish288/.github — Agent Context

Shared CI for the `mcp-*` servers. The reusable (`workflow_call`) workflows and the shared
`scripts/` live here once; each server keeps a thin stub per workflow. Changing CI is one PR
here plus a tag bump, not four PRs across the servers.

There is no application code here — no Python package. This repo's own CI
(`.github/workflows/ci.yml`) is where the real workflow YAML and shared scripts are linted:
actionlint over `.github/workflows/*`, shellcheck over `scripts/ci/*.sh`, the scripts'
self-tests, and the `derive_artifacts.py` unit test. The reusable `lint.yml` lints the
server's Python (ruff + optional pyright) and checks its derived artifacts for drift; it does
not re-run actionlint/shellcheck. The server stubs are themselves valid workflow files and
are checked by GitHub's own workflow parser and, after they land, by each server's push/PR
events — the duplication of running actionlint in every server adds little over linting the
real workflows here.

## Layout

| Path | Contents |
| --- | --- |
| `.github/workflows/tests.yml` | reusable pytest matrix (3.10–3.13); inputs `coverage_min`, `upload_coverage` |
| `.github/workflows/lint.yml` | reusable ruff check + format; input `pyright` |
| `.github/workflows/link-check.yml` | reusable weekly doc-link check (`pytest -m network`) |
| `.github/workflows/release.yml` | reusable release: gate on tests/lint, bump versions, derive artifacts, verified release commit + tag, dispatch publish |
| `.github/workflows/publish-prepare.yml` | reusable publish phase 1: `status` (+ outputs) and `build` |
| `.github/workflows/publish-finish.yml` | reusable publish phase 2: `confirm-pypi → github-release → registry` |
| `.github/workflows/reconcile.yml` | reusable release reconciler (cron + Publish failure path) |
| `.github/workflows/ci.yml` | this repo's own gate: actionlint, shellcheck, script self-tests, `derive_artifacts` unit test |
| `scripts/ci/state.sh` | publish-state engine (PyPI / GitHub release / MCP registry) and write paths |
| `scripts/ci/retry.sh` | transient-vs-permanent retry wrapper used by state/reconcile |
| `scripts/ci/reconcile.sh` | scans the last 3 tags and dispatches publish for any not fully released |
| `scripts/derive_artifacts.py` | derives `gemini-extension.json` and `llms.txt` from `server.json` / `llms-full.txt` |

### Scripts are location-independent

`state.sh`, `reconcile.sh` and `derive_artifacts.py` operate on the **current working
directory** (the server checkout), not on their own location, and resolve sibling scripts
via `$(dirname "$0")`. This is what lets them run both in-repo (if ever) and when checked
out into `.ci/`. Do not reintroduce a `cd "$(dirname "$0")/../.."`; it would make the
scripts read this repo's (absent) `pyproject.toml` / `server.json`.

`derive_artifacts.py` reads the llms.txt cut heading from `$LLMS_SPLIT_MARKER` (default
`\n## Configuration`). The servers differ: argocd/gitlab `## Configuration`, atlassian
`## Environment Variables`, coda `## Setup Examples` — each passes its own via the
`release.yml` input `llms_split_marker`.

## The stub contract (what each server keeps)

Each server replaces its six workflows with stubs of the form:

```yaml
jobs:
  <job>:
    uses: vish288/.github/.github/workflows/<name>.yml@<sha> # v1
    # with: ...          inputs
    # secrets: { NAME: ${{ secrets.NAME }} }   pass by name, never `inherit`
    # permissions: ...    the reusable can only narrow what the caller grants
```

Rules:

- **Pin the commit SHA with a `# v1` comment**, not the moving `@v1` tag — immutable ref,
  Dependabot-bumpable. During the R1 pilot the stubs pin the R1a branch head SHA so CI can run
  before `v1` exists; the orchestrator re-points them to the `v1` commit SHA after R1a lands
  and is tagged.
- **Triggers stay on the stub.** `schedule`, `workflow_run`, `workflow_dispatch`, `push`,
  `pull_request` only fire for a workflow that physically lives in the server repo, so the
  stub owns `on:` and forwards inputs. A reusable workflow can only be entered via
  `workflow_call`.
- **`permissions` on a `uses` job can only narrow** what the caller's token already grants.
  So the publish and release stubs must grant the needed scopes (e.g. `id-token: write`),
  and the reusable jobs narrow per job.
- **`github.*` inside a reusable workflow is the caller's.** `github.repository`,
  `github.ref_name`, `github.event.*` all refer to the server that called in — that is why
  `actions/checkout` with no `repository:` checks out the server, and the release/publish
  scripts act on the server. To fetch the shared scripts, the workflows check THIS repo out
  into `.ci/` using the `job.workflow_*` contexts (added 2026-04), which — unlike `github.*` —
  resolve to the reusable workflow's own repo and commit:
  `repository: ${{ job.workflow_repository }}`, `ref: ${{ job.workflow_sha }}`. A guard step
  fails loudly if `job.workflow_sha` is empty.

### `publish.yml` and PyPI trusted publishing (important)

PyPI trusted publishing **cannot run inside a reusable workflow.** Warehouse's
`_check_job_workflow_ref` requires the OIDC `job_workflow_ref` claim to equal
`<owner>/<server-repo>/.github/workflows/publish.yml@<ref>`, but inside a reusable workflow
that claim points at `vish288/.github` — so the mint fails (warehouse#11096; the
`pypa/gh-action-pypi-publish` README says to keep the publishing job top-level). Therefore:

- The `pypi` job that runs `pypa/gh-action-pypi-publish` is a **normal top-level job in the
  server's own `publish.yml` stub**, with `environment: pypi`, `permissions: { id-token: write }`,
  an `actions/download-artifact` of the `dist` artifact, and an inline `fail_at` gate. Keeping
  it in the stub makes `job_workflow_ref` the server's `publish.yml`, which is what PyPI checks.
- Everything around it is reusable: `publish-prepare.yml` (status + build, outputs the three
  target states and uploads `dist`) and `publish-finish.yml` (confirm on PyPI, create the
  GitHub release, publish to the MCP registry). The stub wires `prepare → pypi → finish`.
- Leave the PyPI trusted-publisher config as workflow `publish.yml` + environment `pypi`.
- `state.sh` also verifies PyPI provenance names `"<owner>/<repo> publish.yml"`
  (`cmd_pypi_fetch`). Because the publishing job is the server's own `publish.yml`, the
  provenance should match; the pilot (R1c) confirms it before rollout.

## Versioning

Tags are `vN` majors (`v1`) that move forward within a compatible line. Servers do **not**
pin the moving `@v1` tag directly; they pin the commit SHA with a `# v1` comment
(`uses: vish288/.github/.github/workflows/<name>.yml@<sha> # v1`) so the ref is immutable and
Dependabot's `github-actions` updater bumps the SHA when `v1` moves. Breaking an input or the
stub contract is a new major (`v2`).

## Conventions

- Third-party actions are pinned by commit SHA with a trailing `# vX.Y.Z` comment.
- `release.yml` calls the sibling `tests.yml` / `lint.yml` with the `$/.github/workflows/<name>.yml`
  same-repo syntax (resolves to THIS repo at THIS commit). A local `./` path would resolve
  against the calling server's checkout — the wrong repo — and `uses:` cannot take an
  expression ref, so `$/` is the only correct option.
- Least-privilege `permissions:` per job; secrets are passed by name, not `inherit`
  (`release.yml` takes `RELEASE_PAT`); the publish/reconcile jobs use only `github.token`.
- Signed commits, linear history, conventional-commit subjects.
