#!/usr/bin/env bash
# Fan out a template release to the four mcp-* servers: one signed branch + PR per repo.
#
#   scripts/fleet-update.sh vX.Y.Z [--codemod <path>] [--dry-run] [--repos-dir <dir>]
#
# For each repo, in order argocd -> coda -> atlassian-extended -> gitlab:
#   git switch -c chore/fleet-vX.Y.Z <main>
#   copier update --trust --defaults --conflict rej -r vX.Y.Z   (-r pins the tag)
#   stop if any *.rej appeared (a template-owned file was edited locally; owner resolves)
#   optional: run the codemod over src/ tests/
#   uv run ruff format . && uv run ruff check --fix .
#   uv run pytest -q && uv run ruff check .  [&& uv run pyright]   (the server's own gates)
#   signed commit via ~/.local/bin/iterm-run (the sandbox shell has no 1Password login), poll
#     git log up to 120 s
#   push the branch, open a PR with `gh`
#
# Stops on the FIRST .rej or red gate and prints the resume command (it never leaves an unsigned
# commit on a pushed branch). Repo paths come from --repos-dir or $MCP_FLEET_ROOT; nothing here
# hard-codes a machine path.
set -euo pipefail

REPOS=(mcp-argocd mcp-coda mcp-atlassian-extended mcp-gitlab)
SIGN_TIMEOUT=120

# --- cleanup / signals --------------------------------------------------------------------
_current_repo=""
cleanup() {
  local code=$1
  if [ -n "$_current_repo" ]; then
    echo "fleet-update: interrupted while in $_current_repo (exit $code)." >&2
    echo "  Its branch is left in place; inspect it, then re-run with the same version to resume." >&2
  fi
}
trap 'cleanup 130; exit 130' INT
trap 'cleanup 143; exit 143' TERM

die() { echo "fleet-update: $*" >&2; exit 1; }

# --- argument parsing (pure; exercised by --self-test) ------------------------------------
VERSION=""; CODEMOD=""; DRY_RUN=0; REPOS_DIR=""
parse_args() {
  VERSION=""; CODEMOD=""; DRY_RUN=0; REPOS_DIR="${MCP_FLEET_ROOT:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --codemod)   CODEMOD="${2:-}"; [ -n "$CODEMOD" ] || return 2; shift 2 ;;
      --repos-dir) REPOS_DIR="${2:-}"; [ -n "$REPOS_DIR" ] || return 2; shift 2 ;;
      --dry-run)   DRY_RUN=1; shift ;;
      -*)          echo "unknown flag: $1" >&2; return 2 ;;
      *)           [ -z "$VERSION" ] || return 2; VERSION="$1"; shift ;;
    esac
  done
  [ -n "$VERSION" ] || { echo "version argument (vX.Y.Z) is required" >&2; return 2; }
  [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be semver vX.Y.Z, got: $VERSION" >&2; return 2; }
  return 0
}

# Echo-and-run; in --dry-run the mutating commands are printed, not executed.
run() {
  if [ "$DRY_RUN" = 1 ]; then echo "DRY  $*"; else echo "RUN  $*"; "$@"; fi
}

# Same, but inside a repo dir (portable cd-subshell; macOS env lacks GNU's -C).
in_repo() {
  local d=$1; shift
  if [ "$DRY_RUN" = 1 ]; then echo "DRY  (cd $d) $*"; else echo "RUN  (cd $d) $*"; ( cd "$d" && "$@" ); fi
}

signed_commit() {  # $1 = repo path, $2 = message-file, $3 = expected subject
  local repo=$1 msgfile=$2 subject=$3
  if [ "$DRY_RUN" = 1 ]; then echo "DRY  iterm-run git -C $repo commit -S -F $msgfile"; return 0; fi
  local attempt
  for attempt in 1 2; do
    ~/.local/bin/iterm-run "git -C '$repo' commit -S -F '$msgfile'" || true
    local waited=0
    while [ "$waited" -lt "$SIGN_TIMEOUT" ]; do
      if git -C "$repo" log --oneline -1 --format='%s' | grep -qF "$subject"; then
        echo "  signed commit landed: $(git -C "$repo" log --oneline -1)"; return 0
      fi
      sleep 3; waited=$((waited + 3))
    done
    echo "  signing attempt $attempt did not produce a commit within ${SIGN_TIMEOUT}s" >&2
  done
  return 1
}

update_one() {  # $1 = repo path
  local repo=$1 name branch msg subject
  name=$(basename "$repo")
  branch="chore/fleet-$VERSION"
  _current_repo="$name"
  echo "═══ $name ═══"

  [ -d "$repo/.git" ] || die "$repo is not a git checkout"
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    if [ "$DRY_RUN" = 1 ]; then echo "WARN $name is dirty; a real run would refuse it (copier needs a clean tree)";
    else die "$name working tree is dirty; copier refuses a dirty tree"; fi
  fi

  run git -C "$repo" fetch origin --quiet
  run git -C "$repo" switch -c "$branch" origin/main

  in_repo "$repo" uvx copier update --trust --defaults --conflict rej -r "$VERSION"

  if [ "$DRY_RUN" != 1 ] && find "$repo" -name '*.rej' -print -quit | grep -q .; then
    echo "::stop:: conflicts (*.rej) in $name — resolve, commit, then re-run for the rest" >&2
    find "$repo" -name '*.rej' >&2
    exit 1
  fi

  if [ -n "$CODEMOD" ]; then
    in_repo "$repo" uv run --with libcst python "$CODEMOD" src tests
  fi

  in_repo "$repo" uv run ruff format .
  in_repo "$repo" uv run ruff check --fix .
  in_repo "$repo" uv run pytest -q
  in_repo "$repo" uv run ruff check .
  if [ "$DRY_RUN" != 1 ] && grep -q '^pyright: true' "$repo/.copier-answers.yml" 2>/dev/null; then
    in_repo "$repo" uv run pyright
  fi

  subject="chore(fleet): template $VERSION"
  msg="$repo/.internal/fleet-msg.txt"
  if [ "$DRY_RUN" != 1 ]; then
    mkdir -p "$repo/.internal"
    printf '%s\n\nAdopt vish288/.github template %s (stubs, Dockerfile, ruff.toml, dependabot).\n' "$subject" "$VERSION" > "$msg"
    git -C "$repo" add -A
  fi

  signed_commit "$repo" "$msg" "$subject" || {
    echo "::stop:: signing failed in $name after one retry — nothing pushed; re-sign locally, then re-run" >&2
    exit 1
  }

  run git -C "$repo" push -u origin "$branch"
  in_repo "$repo" env -u GH_TOKEN gh pr create --fill --label fleet
  _current_repo=""
}

main() {
  parse_args "$@" || exit 2
  [ -n "$REPOS_DIR" ] || die "set --repos-dir or \$MCP_FLEET_ROOT to the directory holding the mcp-* checkouts"
  [ -d "$REPOS_DIR" ] || die "repos dir not found: $REPOS_DIR"
  echo "fleet-update $VERSION  (dry-run=$DRY_RUN, codemod=${CODEMOD:-none}, repos-dir=$REPOS_DIR)"
  for r in "${REPOS[@]}"; do
    update_one "$REPOS_DIR/$r"
  done
  echo "fleet-update: all repos done."
}

# --- self-test: argument handling only, no side effects -----------------------------------
self_test() {
  set +e  # parse_args returns non-zero on purpose below; do not let set -e abort
  local rc
  parse_args v1.2.0 >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ "$VERSION" = v1.2.0 ] && [ "$DRY_RUN" = 0 ] || { echo "FAIL: plain version"; return 1; }
  parse_args v1.2.0 --dry-run --codemod /x/cm.py >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ "$DRY_RUN" = 1 ] && [ "$CODEMOD" = /x/cm.py ] || { echo "FAIL: flags"; return 1; }
  parse_args --repos-dir /tmp/r v2.0.1 >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ "$REPOS_DIR" = /tmp/r ] && [ "$VERSION" = v2.0.1 ] || { echo "FAIL: repos-dir"; return 1; }
  parse_args >/dev/null 2>&1; [ $? = 2 ] || { echo "FAIL: missing version not rejected"; return 1; }
  parse_args 1.2.0 >/dev/null 2>&1; [ $? = 2 ] || { echo "FAIL: non-v semver not rejected"; return 1; }
  parse_args v1.2 >/dev/null 2>&1; [ $? = 2 ] || { echo "FAIL: short semver not rejected"; return 1; }
  parse_args v1.2.0 v1.3.0 >/dev/null 2>&1; [ $? = 2 ] || { echo "FAIL: two versions not rejected"; return 1; }
  parse_args v1.2.0 --bogus >/dev/null 2>&1; [ $? = 2 ] || { echo "FAIL: unknown flag not rejected"; return 1; }
  parse_args v1.2.0 --codemod >/dev/null 2>&1; [ $? = 2 ] || { echo "FAIL: --codemod needs an argument"; return 1; }
  echo "fleet-update self-test: OK"
}

if [ "${1:-}" = "--self-test" ]; then self_test; exit $?; fi
main "$@"
