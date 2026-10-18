# vish288/.github

Shared GitHub Actions for the `mcp-*` servers (`mcp-gitlab`, `mcp-atlassian-extended`,
`mcp-argocd`, `mcp-coda`). The six workflows below live here once as reusable
(`workflow_call`) workflows; each server keeps a thin stub that calls them. A CI fix is now
one PR here plus a tag bump, instead of the same change landing in four repos.

## Reusable workflows

| Workflow | Trigger in the server | Inputs |
| --- | --- | --- |
| `tests.yml` | push, pull_request | `coverage_min` (number, 95), `upload_coverage` (bool, true) |
| `lint.yml` | push, pull_request | `pyright` (bool, false) |
| `link-check.yml` | weekly schedule | — |
| `release.yml` | workflow_dispatch | `bump`, `version`, `dry_run`, `publish_fail_at`, `coverage_min`, `pyright`, `llms_split_marker`; secret `RELEASE_PAT` |
| `publish.yml` | workflow_dispatch (dispatched by `release.yml` on the tag) | `dry_run`, `fail_at` |
| `reconcile.yml` | schedule + `workflow_run` of Publish + dispatch | — |

The shared `scripts/ci/*.sh` (state/retry/reconcile) and `scripts/derive_artifacts.py` live
here too. `release.yml`, `publish.yml` and `reconcile.yml` check this repo out into `.ci/`
at their own ref (`github.job_workflow_sha`) and run the scripts from there; the scripts
operate on the current working directory, which is the calling server's checkout.

## Using it from a server repo

Pin every stub to a tag (`@v1`). Example `tests.yml`:

```yaml
name: Tests
on: [push, pull_request]
jobs:
  test:
    uses: vish288/.github/.github/workflows/tests.yml@v1
    with:
      coverage_min: 98
```

See `AGENTS.md` for the full stub contract, including the `publish.yml` / PyPI
trusted-publishing requirement.

## Versioning

Tags are `vN` majors (`v1`) that move forward within a compatible line, so stubs pin `@v1`
and pick up fixes on a tag re-point. A breaking change to an input or contract is `v2`.

## License

MIT — see `LICENSE`.
