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
    uses: vish288/.github/.github/workflows/<name>.yml@<sha> # v1.0.0
    # with: ...          inputs
    # secrets: { NAME: ${{ secrets.NAME }} }   pass by name, never `inherit`
    # permissions: ...    the reusable can only narrow what the caller grants
```

Rules:

- **Pin the commit SHA with a `# vX.Y.Z` comment** naming the release tag it points at —
  an immutable ref. Copier renders these pins from the template tag and `scripts/fleet-update.sh`
  moves them on each release; Dependabot ignores `vish288/.github` refs (see the template section).
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

Tags are semver only (`vX.Y.Z`) and never move; there is no floating major tag. Servers pin the
tag's commit SHA with a `# vX.Y.Z` comment
(`uses: vish288/.github/.github/workflows/<name>.yml@<sha> # v1.0.0`), so the ref is immutable.
Copier renders these pins from the template tag's commit and `scripts/fleet-update.sh` moves them
on each release; Dependabot **ignores** `vish288/.github` refs (the templated `dependabot.yml`
carries the ignore) so it does not fight Copier over the pins — it keeps bumping only the
third-party actions that live inside the reusables here. Breaking an input or the stub contract
bumps the major (`v2.0.0`).

## Copier template

The `template/` directory is a [Copier](https://copier.readthedocs.io) template that renders the
~20 non-runtime files every server must carry: the six workflow stubs, `Dockerfile`,
`.github/dependabot.yml`, `LICENSE`, `.gitignore`, `.dockerignore`, `ruff.toml` and the
`.copier-answers.yml` tracker. `copier.yml` at the repo root declares `_subdirectory: template`,
so only `template/` is rendered — `copier.yml`, `scripts/` and `tests/` stay out of the output.

### Answers (four questions)

| answer | type | used in | argocd / gitlab / atlassian / coda |
| --- | --- | --- | --- |
| `service` | str (`^mcp-[a-z-]+$`) | Dockerfile, release-stub comment | mcp-argocd / mcp-gitlab / mcp-atlassian-extended / mcp-coda |
| `coverage_min` | int | tests + release stubs | 98 / 98 / 95 / 99 |
| `pyright` | bool | lint + release stubs | false / false / false / true |
| `llms_split_marker` | str | lint + release stubs (derive drift) | `\n## Configuration` / `…` / `\n## Environment Variables` / `\n## Setup Examples` |

The stubs forward `coverage_min` always, `pyright` only when true, and `llms_split_marker` only
when it differs from the default — so argocd (all defaults) renders byte-identical to its
hand-written stubs.

### Bracket delimiters (why `${{ }}` survives)

The stubs must emit GitHub Actions `${{ … }}` verbatim, which collides with Jinja's default
`{{ }}`. `copier.yml` `_envops` switches Jinja to the bracket set — `[[ ]]`, `[% %]`, `[# #]` —
so `${{ … }}` passes through untouched. The answers-file **name**
(`template/[[ _copier_conf.answers_file ]].jinja`) uses the same brackets; with `{{ }}` Copier
writes a literal-named file and a later `update` fails to find the template.

### Stub SHA pins — how a tag pins its own commit

A template cannot contain its own commit SHA (the content and the commit are written together).
Copier resolves this: each stub renders
`uses: vish288/.github/.github/workflows/<name>.yml@[[ _copier_conf.vcs_ref_hash ]] # [[ _copier_answers._commit ]]`.
`_copier_conf.vcs_ref_hash` is the commit of the ref Copier rendered from, and `_copier_answers._commit`
is that ref's describe. So `copier copy -r vX.Y.Z` checks out the tag `vX.Y.Z`, and the pin
becomes that tag's own commit SHA with a `# vX.Y.Z` comment — the stub for version X.Y.Z pins
X.Y.Z's commit, atomically. (`_copier_conf.vcs_ref` is **not** stable across copy/update; only
`vcs_ref_hash` and `_copier_answers._commit` are.)

### ruff config → `ruff.toml`

`template/ruff.toml` carries the ruff config (Ruff reads `ruff.toml` in preference to
`pyproject.toml`, and ignores a pyproject with no `[tool.ruff]`). On adoption,
`scripts/migrations/drop_tool_ruff.py` (tomlkit, idempotent) removes the now-redundant
`[tool.ruff*]` tables from the server's `pyproject.toml`. This runs at adoption, **not** as a
Copier `_migrations` entry: adoption is `copier copy`, and `_migrations` only run on
`copier update`.

### Tests

`tests/answers/*.yml` hold the four answer sets; `tests/golden/<svc>/` hold the expected
rendered trees. `ci.yml`'s `template` job renders each set (`tests/render.sh`), diffs against the
golden tree, and runs actionlint over the rendered stubs. `tests/render.sh` normalises the
version-dependent pin (`@<sha> # <ref>` → `@PIN`) and the machine-specific answers lines
(`_commit`, `_src_path`), so golden stays commit-stable and free of local paths. After any
template change, run `tests/regen-golden.sh` and commit the result — the golden diff IS the
rendered effect of the change, ×4. `template/` is outside `.github/workflows` and uses `.jinja`
suffixes, so it is out of this repo's root actionlint and Dependabot scope; it is linted only
through its rendered output here.

### Fan-out (`scripts/fleet-update.sh`)

A template release reaches the servers through `scripts/fleet-update.sh vX.Y.Z [--codemod <path>]`,
run by the owner locally. It loops argocd → coda → atlassian-extended → gitlab:
`copier update --trust --defaults --conflict rej -r vX.Y.Z` (the `-r` pins the tag), optional
codemod over `src/ tests/`, `ruff format` + `ruff check --fix`, then the server's own gates
(`pytest -q`, `ruff check`, `pyright` when the repo ships it), a signed commit, a branch push and
a PR (ensuring the `fleet` label first). The commit goes through `$FLEET_COMMIT_RUNNER` — a
command that runs a shell string in a login session that can reach the signing agent (a sandbox
shell cannot) — falling back to `git commit -S` directly; the script verifies HEAD moved **and**
carries a `gpgsig` header before pushing, so an unsigned commit is never pushed (fail closed). It
stops on the first `*.rej`, red gate or unsigned/failed commit, prints the resume command, and a
re-run skips repos already on the version and resumes a pushed branch. `--dry-run` previews; repo
paths come from `--repos-dir` or `$MCP_FLEET_ROOT` (no
machine path is baked in). Dependabot `ignore`s `vish288/.github` refs in the templated
`dependabot.yml` so it does not fight Copier over the stub pins; the reusable `lint.yml` carries
an advisory drift warning comparing `.copier-answers` `_commit` against the latest semver tag.

## Conventions

- Third-party actions are pinned by commit SHA with a trailing `# vX.Y.Z` comment.
- `release.yml` calls the sibling `tests.yml` / `lint.yml` with the `$/.github/workflows/<name>.yml`
  same-repo syntax (resolves to THIS repo at THIS commit). A local `./` path would resolve
  against the calling server's checkout — the wrong repo — and `uses:` cannot take an
  expression ref, so `$/` is the only correct option.
- Least-privilege `permissions:` per job; secrets are passed by name, not `inherit`
  (`release.yml` takes `RELEASE_PAT`); the publish/reconcile jobs use only `github.token`.
- Signed commits, linear history, conventional-commit subjects.
