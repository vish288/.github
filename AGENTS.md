# vish288/.github — Agent Context

Shared CI for the `mcp-*` servers. Six reusable (`workflow_call`) workflows and the shared
`scripts/` live here once; each server keeps a thin stub per workflow. Changing CI is one PR
here plus a tag bump, not four PRs across the servers.

There is no application code — no Python package, no tests of its own. This repo's own CI
(`.github/workflows/ci.yml`) lints the workflow YAML (actionlint) and the scripts
(shellcheck) and runs the scripts' self-tests. That is why the reusable `lint.yml` does NOT
run actionlint / shellcheck / script self-tests: the servers hold only stubs and no
`scripts/ci`, so there is nothing of that kind to lint there.

## Layout

| Path | Contents |
| --- | --- |
| `.github/workflows/tests.yml` | reusable pytest matrix (3.10–3.13); inputs `coverage_min`, `upload_coverage` |
| `.github/workflows/lint.yml` | reusable ruff check + format; input `pyright` |
| `.github/workflows/link-check.yml` | reusable weekly doc-link check (`pytest -m network`) |
| `.github/workflows/release.yml` | reusable release: gate on tests/lint, bump versions, derive artifacts, verified release commit + tag, dispatch publish |
| `.github/workflows/publish.yml` | reusable publish pipeline: `status → build → pypi → github-release → registry` |
| `.github/workflows/reconcile.yml` | reusable release reconciler (cron + Publish failure path) |
| `.github/workflows/ci.yml` | this repo's own gate: actionlint, shellcheck, script self-tests |
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
    uses: vish288/.github/.github/workflows/<name>.yml@<ref>
    # with: ...        inputs
    # secrets: inherit  where the reusable needs the caller's secrets
    # permissions: ...  the reusable can only narrow what the caller grants
```

Rules:

- **Pin `<ref>`** to a tag (`@v1`) once this repo is tagged. During the R1 pilot the stubs
  pin the R1a branch head SHA so CI can run before `v1` exists; the orchestrator flips them
  to `@v1` after R1a lands.
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
  scripts act on the server. The one exception the workflows rely on is
  `github.job_workflow_sha`, the SHA of the reusable workflow file in THIS repo, used to
  check this repo out into `.ci/` at the matching ref.

### `publish.yml` and PyPI trusted publishing (important)

- Keep the caller stub **named `publish.yml`** and give it `permissions: id-token: write`
  (plus `contents: write`, `actions: read`). PyPI's trusted publisher is configured against
  the caller's workflow filename, so the name must not change.
- The `pypi` **environment lives on the reusable workflow's `pypi` job**, not on the stub:
  GitHub forbids `environment:` on a `uses` job. Configure the PyPI trusted publisher with
  workflow `publish.yml` and environment `pypi`. The OIDC `environment` claim is set by that
  job here.
- `state.sh` additionally verifies PyPI provenance names `"<owner>/<repo> publish.yml"`
  (`cmd_pypi_fetch`). Whether a reusable publish workflow records the caller's `publish.yml`
  or this repo's in the attestation is verified by the pilot (R1c) before rollout; if it
  records this repo's, that check and the trusted-publisher config must be updated together.

## Versioning

Tags are `vN` moving majors (`v1`). Stubs pin `@v1` and pick up fixes when the tag
re-points. Breaking an input or the stub contract is a new major (`v2`). Never force-push a
moving tag onto an incompatible change.

## Conventions

- Third-party actions are pinned by commit SHA with a trailing `# vX.Y.Z` comment. First-
  party `actions/*` reusable calls use the repo-relative `./.github/workflows/...` form
  inside `release.yml`.
- Least-privilege `permissions:` per job; `secrets: inherit` only where a job needs the
  caller's secrets (`release.yml`'s `RELEASE_PAT`).
- Signed commits, linear history, conventional-commit subjects. No `CLAUDE.md`.
