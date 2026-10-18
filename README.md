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

## Using it from a server repo

Pin every stub to a tag (`@v1`). Example `tests.yml`:

```yaml
name: Tests
on: [push, pull_request]
jobs:
  test:
    uses: vish288/.github/.github/workflows/tests.yml@<sha> # v1
    with:
      coverage_min: 98
```

Pin the commit SHA with a `# v1` comment (not the moving `@v1` tag) so Dependabot bumps it.
See `AGENTS.md` for the full stub contract, including the `publish.yml` / PyPI
trusted-publishing requirement.

## Versioning

Tags are `vN` majors (`v1`) that move forward within a compatible line. Servers pin the
commit SHA with a `# v1` comment so the ref is immutable and Dependabot bumps the SHA when
`v1` moves. A breaking change to an input or contract is `v2`.

## License

MIT — see `LICENSE`.
