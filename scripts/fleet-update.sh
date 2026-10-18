#!/usr/bin/env bash
# Fan out a template release to the four mcp-* servers: one signed branch + PR per repo.
#
#   scripts/fleet-update.sh vX.Y.Z [--codemod <path>] [--dry-run] [--repos-dir <dir>]
#
# For each repo, in order argocd -> coda -> atlassian-extended -> gitlab:
#   skip if origin/main is already on vX.Y.Z, or if a remote fan-out branch already exists
#     (then report its PR); resume a local-only branch by verifying + pushing it
#   git switch -c chore/fleet-vX.Y.Z origin/main
#   copier update --trust --defaults --conflict rej -r vX.Y.Z   (-r pins the tag)
#   stop if any *.rej appeared (a template-owned file was edited locally; owner resolves)
#   optional: run the codemod over src/ tests/
#   uv run ruff format . && uv run ruff check --fix .
#   uv run pytest -q && uv run ruff check .  [&& uv run pyright]   (the server's own gates)
#   signed commit through $FLEET_COMMIT_RUNNER (a command that runs a shell string in a login
#     session that can reach the signing agent); falls back to `git commit -S` directly. The
#     commit must move HEAD AND carry a gpgsig header, or nothing is pushed (fail closed).
#   push the branch, ensure the `fleet` label exists, open a PR with `gh`
#
# Stops on the FIRST .rej, red gate, or unsigned/failed commit and prints the resume command; it
# never leaves an unsigned commit on a pushed branch, and a re-run skips finished repos. Repo
# paths come from --repos-dir or $MCP_FLEET_ROOT; nothing here hard-codes a machine path.
set -Eeuo pipefail

REPOS=(mcp-argocd mcp-coda mcp-atlassian-extended mcp-gitlab)
SIGN_TIMEOUT=120
CHILD_PID=""

die() { echo "fleet-update: $*" >&2; exit 1; }

# --- signals / errors ---------------------------------------------------------------------
_current_repo=""
resume_hint() {
  echo "  next: re-run  scripts/fleet-update.sh ${VERSION:-vX.Y.Z}${CODEMOD:+ --codemod $CODEMOD}${REPOS_DIR_FLAG:+ --repos-dir $REPOS_DIR}" >&2
  echo "        (it skips repos already on ${VERSION:-the version} and resumes a pushed branch)" >&2
}
on_signal() {  # $1 = exit code
  trap - INT TERM ERR
  # Stop any tracked foreground child (uvx/uv/git) so Ctrl-C/TERM does not orphan it.
  # ponytail: kills the tracked subshell; a deep grandchild may outlive it — acceptable here.
  [ -n "$CHILD_PID" ] && kill -TERM "$CHILD_PID" 2>/dev/null || true
  [ -n "$_current_repo" ] && echo "fleet-update: interrupted in $_current_repo (exit $1); its branch is left in place." >&2
  resume_hint
  exit "$1"
}
on_err() {
  local rc=$?
  trap - INT TERM ERR
  echo "::stop:: fleet-update failed in ${_current_repo:-startup} (exit $rc)" >&2
  resume_hint
  exit "$rc"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap on_err ERR

# Run a (possibly long) command as a tracked child so the TERM/INT trap can stop it.
_exec() { "$@" & CHILD_PID=$!; wait "$CHILD_PID"; local rc=$?; CHILD_PID=""; return "$rc"; }

# --- argument parsing (pure; exercised by --self-test) ------------------------------------
VERSION=""; CODEMOD=""; DRY_RUN=0; REPOS_DIR=""; REPOS_DIR_FLAG=""
parse_args() {
  VERSION=""; CODEMOD=""; DRY_RUN=0; REPOS_DIR="${MCP_FLEET_ROOT:-}"; REPOS_DIR_FLAG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --codemod)   CODEMOD="${2:-}"; [ -n "$CODEMOD" ] || return 2; shift 2 ;;
      --repos-dir) REPOS_DIR="${2:-}"; [ -n "$REPOS_DIR" ] || return 2; REPOS_DIR_FLAG=1; shift 2 ;;
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
  if [ "$DRY_RUN" = 1 ]; then echo "DRY  $*"; else echo "RUN  $*"; _exec "$@"; fi
}
# Same, but inside a repo dir (portable cd-subshell; macOS env lacks GNU env's -C).
in_repo() {
  local d=$1; shift
  if [ "$DRY_RUN" = 1 ]; then echo "DRY  (cd $d) $*"; else echo "RUN  (cd $d) $*"; _exec bash -c 'cd "$1" && shift && "$@"' _ "$d" "$@"; fi
}

# --- state probes (testable) --------------------------------------------------------------
answers_commit_on_main() { git -C "$1" show origin/main:.copier-answers.yml 2>/dev/null \
  | sed -n -E 's/^_commit: *["'"'"']?([^"'"'"']*)["'"'"']? *$/\1/p' | head -1; }
remote_branch_exists()   { git -C "$1" ls-remote --exit-code --heads origin "$2" >/dev/null 2>&1; }
local_branch_exists()    { git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }
head_moved()             { [ "$(git -C "$1" rev-parse HEAD)" != "$2" ]; }
head_is_signed()         { git -C "$1" cat-file -p HEAD 2>/dev/null | grep -q '^gpgsig'; }

# A branch is a pushable fleet branch only if: the tree is clean, HEAD is ahead of origin/main,
# and EVERY commit in origin/main..HEAD is signed. A local branch sitting at origin/main (0
# commits ahead) or a dirty/unsigned one is refused — otherwise the resume path would push a
# branch identical to main, fail `gh pr create`, and then the remote-branch skip would block the
# repo for good.
range_all_signed() {  # $1 = repo path
  local repo=$1 c
  [ -z "$(git -C "$repo" status --porcelain)" ] || return 1
  [ "$(git -C "$repo" rev-list --count origin/main..HEAD)" -gt 0 ] || return 1
  for c in $(git -C "$repo" rev-list origin/main..HEAD); do
    git -C "$repo" cat-file -p "$c" 2>/dev/null | grep -q '^gpgsig' || return 1
  done
  return 0
}

ensure_label() {  # idempotent — the `fleet` label exists in none of the repos yet
  in_repo "$1" env -u GH_TOKEN gh label create fleet --color ededed \
    --description "template fan-out" 2>/dev/null || true
}
open_pr() { in_repo "$1" env -u GH_TOKEN gh pr create --fill --label fleet; }

# Did the last commit attempt produce a moved, signed HEAD? 0 = yes; 1 = moved-but-unsigned
# (fail closed); 2 = not moved yet.
_commit_verdict() {  # $1 = repo, $2 = before-sha
  head_moved "$1" "$2" || return 2
  if head_is_signed "$1"; then echo "  signed commit landed: $(git -C "$1" log --oneline -1)"; return 0; fi
  echo "::stop:: commit $(git -C "$1" rev-parse --short HEAD) is UNSIGNED — not pushing" >&2
  return 1
}

signed_commit() {  # $1 = repo path, $2 = message-file ; fail closed on unsigned/no-move
  local repo=$1 msgfile=$2 runner="${FLEET_COMMIT_RUNNER:-}" before attempt waited v
  if [ "$DRY_RUN" = 1 ]; then echo "DRY  commit -S via \${FLEET_COMMIT_RUNNER:-git} in $repo"; return 0; fi
  before=$(git -C "$repo" rev-parse HEAD)
  # No runner: `git commit -S` is synchronous — commit once and check, no poll.
  if [ -z "$runner" ]; then
    git -C "$repo" commit -S -F "$msgfile" || true
    _commit_verdict "$repo" "$before"; v=$?
    [ "$v" = 0 ] && return 0
    [ "$v" = 2 ] && echo "::stop:: git commit -S produced no commit in $(basename "$repo")" >&2
    return 1
  fi
  # Runner (e.g. an iTerm/1Password bridge): the signed commit may land asynchronously; poll.
  for attempt in 1 2; do
    "$runner" "git -C '$repo' commit -S -F '$msgfile'" || true
    waited=0
    while [ "$waited" -lt "$SIGN_TIMEOUT" ]; do
      _commit_verdict "$repo" "$before"; v=$?
      [ "$v" = 0 ] && return 0
      [ "$v" = 1 ] && return 1  # moved but unsigned — do not retry into a second unsigned commit
      sleep 3; waited=$((waited + 3))
    done
    echo "  signing attempt $attempt produced no commit within ${SIGN_TIMEOUT}s" >&2
  done
  return 1
}

update_one() {  # $1 = repo path
  local repo=$1 name branch msg before
  name=$(basename "$repo")
  branch="chore/fleet-$VERSION"
  _current_repo="$name"
  echo "═══ $name ═══"

  [ -d "$repo/.git" ] || die "$repo is not a git checkout"
  run git -C "$repo" fetch origin --quiet

  # Skip: origin/main already carries this template version.
  if [ "$(answers_commit_on_main "$repo")" = "$VERSION" ]; then
    echo "skip $name: origin/main is already on $VERSION"; _current_repo=""; return 0
  fi
  # Skip: a fan-out branch is already pushed — report its PR and leave it for review/landing.
  if remote_branch_exists "$repo" "$branch"; then
    local pr; pr=$( (cd "$repo" && env -u GH_TOKEN gh pr list --head "$branch" --json url --jq '.[0].url' 2>/dev/null) || true)
    echo "skip $name: remote branch $branch already exists (PR: ${pr:-none}); land or close it, then re-run"
    _current_repo=""; return 0
  fi
  # Resume: a local-only branch exists — it must be a clean, ahead-of-main, fully-signed fleet
  # branch before we push it, or we would push a copy of main and poison the repo.
  if local_branch_exists "$repo" "$branch"; then
    echo "resume $name: local $branch exists but is not pushed"
    run git -C "$repo" switch "$branch"
    if [ "$DRY_RUN" != 1 ] && ! range_all_signed "$repo"; then
      echo "::stop:: $name $branch has no fleet commit / is dirty: fix it, or delete it with \`git branch -D $branch\`, then re-run" >&2
      resume_hint; exit 1
    fi
    run git -C "$repo" push -u origin "$branch"
    ensure_label "$repo"; open_pr "$repo"; _current_repo=""; return 0
  fi

  # Fresh run.
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    if [ "$DRY_RUN" = 1 ]; then echo "WARN $name is dirty; a real run would refuse it (copier needs a clean tree)";
    else die "$name working tree is dirty; copier refuses a dirty tree"; fi
  fi

  run git -C "$repo" switch -c "$branch" origin/main
  in_repo "$repo" uvx copier update --trust --defaults --conflict rej -r "$VERSION"

  if [ "$DRY_RUN" != 1 ] && find "$repo" -name '*.rej' -print -quit | grep -q .; then
    echo "::stop:: conflicts (*.rej) in $name — resolve, commit, then re-run for the rest" >&2
    find "$repo" -name '*.rej' >&2
    resume_hint; exit 1
  fi

  [ -n "$CODEMOD" ] && in_repo "$repo" uv run --with libcst python "$CODEMOD" src tests

  in_repo "$repo" uv run ruff format .
  in_repo "$repo" uv run ruff check --fix .
  in_repo "$repo" uv run pytest -q
  in_repo "$repo" uv run ruff check .
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY  (cd $repo) uv run pyright   # only when the answers set pyright: true"
  elif grep -q '^pyright: true' "$repo/.copier-answers.yml" 2>/dev/null; then
    in_repo "$repo" uv run pyright
  fi

  msg="$repo/.internal/fleet-msg.txt"
  if [ "$DRY_RUN" != 1 ]; then
    mkdir -p "$repo/.internal"
    printf 'chore(fleet): template %s\n\nUpdate to the vish288/.github template %s (stubs, Dockerfile, ruff.toml, dependabot).\n' "$VERSION" "$VERSION" > "$msg"
  fi
  run git -C "$repo" add -A

  signed_commit "$repo" "$msg" || {
    echo "::stop:: signing failed in $name — nothing pushed; re-sign locally, then re-run" >&2
    resume_hint; exit 1
  }
  # Same full-range guarantee as the resume path: never push unless the whole range is signed.
  if [ "$DRY_RUN" != 1 ] && ! range_all_signed "$repo"; then
    echo "::stop:: $name origin/main..HEAD is not all signed/clean — not pushing" >&2
    resume_hint; exit 1
  fi

  run git -C "$repo" push -u origin "$branch"
  ensure_label "$repo"; open_pr "$repo"
  _current_repo=""
}

main() {
  parse_args "$@" || exit 2
  [ -n "$REPOS_DIR" ] || die "set --repos-dir or \$MCP_FLEET_ROOT to the directory holding the mcp-* checkouts"
  [ -d "$REPOS_DIR" ] || die "repos dir not found: $REPOS_DIR"
  echo "fleet-update $VERSION  (dry-run=$DRY_RUN, codemod=${CODEMOD:-none}, repos-dir=$REPOS_DIR, runner=${FLEET_COMMIT_RUNNER:-git -S})"
  for r in "${REPOS[@]}"; do
    update_one "$REPOS_DIR/$r"
  done
  echo "fleet-update: all repos done."
}

# --- self-test ----------------------------------------------------------------------------
self_test() {
  set +e
  trap - ERR
  local rc fail=0
  _t() { if "$@"; then echo "  ok   $1"; else echo "  FAIL $*"; fail=1; fi; }

  # argument handling
  parse_args v1.2.0 >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ "$VERSION" = v1.2.0 ] && [ "$DRY_RUN" = 0 ] && echo "  ok   plain version" || { echo "  FAIL plain version"; fail=1; }
  parse_args v1.2.0 --dry-run --codemod /x/cm.py >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ "$DRY_RUN" = 1 ] && [ "$CODEMOD" = /x/cm.py ] && echo "  ok   flags" || { echo "  FAIL flags"; fail=1; }
  parse_args --repos-dir /tmp/r v2.0.1 >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ "$REPOS_DIR" = /tmp/r ] && echo "  ok   repos-dir" || { echo "  FAIL repos-dir"; fail=1; }
  for bad in "" "1.2.0" "v1.2" "v1.2.0 v1.3.0" "v1.2.0 --bogus" "v1.2.0 --codemod"; do
    # shellcheck disable=SC2086
    parse_args $bad >/dev/null 2>&1
    [ $? = 2 ] && echo "  ok   reject [$bad]" || { echo "  FAIL accept [$bad]"; fail=1; }
  done

  # resume/skip + signing probes against throwaway git repos
  local tmp; tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  ( # a bare "origin" plus a clone whose origin/main carries _commit: v1.2.0.
    # origin/main is set with update-ref, not a push: the global signed-push guard blocks
    # unsigned pushes to default branches, and the test commits are deliberately unsigned.
    set -e
    git init -q -b main --bare "$tmp/origin.git"
    git clone -q "$tmp/origin.git" "$tmp/repo"
    cd "$tmp/repo"
    git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    printf '_commit: v1.2.0\n_src_path: x\n' > .copier-answers.yml
    git add -A; git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -m answers
    git update-ref refs/remotes/origin/main HEAD
  ) >/dev/null 2>&1 || { echo "  FAIL could not build temp repos"; return 1; }

  answers_commit_on_main "$tmp/repo" | grep -qx v1.2.0 && echo "  ok   answers_commit_on_main reads _commit" || { echo "  FAIL answers_commit_on_main"; fail=1; }
  VERSION=v1.2.0; [ "$(answers_commit_on_main "$tmp/repo")" = "$VERSION" ] && echo "  ok   skip: on-version detected" || { echo "  FAIL skip on-version"; fail=1; }
  VERSION=v1.3.0; [ "$(answers_commit_on_main "$tmp/repo")" != "$VERSION" ] && echo "  ok   no-skip: newer version" || { echo "  FAIL no-skip newer"; fail=1; }

  git -C "$tmp/repo" branch chore/fleet-v9.9.9 >/dev/null 2>&1
  local_branch_exists "$tmp/repo" chore/fleet-v9.9.9 && echo "  ok   local_branch_exists" || { echo "  FAIL local_branch_exists"; fail=1; }
  ! remote_branch_exists "$tmp/repo" chore/fleet-v9.9.9 && echo "  ok   remote_branch_exists false before push" || { echo "  FAIL remote_branch_exists"; fail=1; }
  git -C "$tmp/repo" push -q origin chore/fleet-v9.9.9 >/dev/null 2>&1
  git -C "$tmp/repo" fetch -q origin
  remote_branch_exists "$tmp/repo" chore/fleet-v9.9.9 && echo "  ok   remote_branch_exists true after push" || { echo "  FAIL remote_branch_exists post-push"; fail=1; }

  # HEAD-moved + gpgsig: an ordinary (unsigned) commit must be rejected (fail closed)
  local before; before=$(git -C "$tmp/repo" rev-parse HEAD)
  git -C "$tmp/repo" -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q --allow-empty -m more
  head_moved "$tmp/repo" "$before" && echo "  ok   head_moved detects a new commit" || { echo "  FAIL head_moved"; fail=1; }
  ! head_is_signed "$tmp/repo" && echo "  ok   head_is_signed rejects an unsigned commit" || { echo "  FAIL head_is_signed false-positive"; fail=1; }

  # range_all_signed: a branch sitting at origin/main (0 commits ahead) must be refused, so the
  # resume path never pushes a copy of main.
  git -C "$tmp/repo" switch -q -c at-main origin/main
  ! range_all_signed "$tmp/repo" && echo "  ok   range refuses a branch at origin/main (0 ahead)" || { echo "  FAIL range accepted 0-ahead"; fail=1; }
  # An unsigned commit ahead of main must be refused.
  git -C "$tmp/repo" -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q --allow-empty -m ahead
  ! range_all_signed "$tmp/repo" && echo "  ok   range refuses an unsigned commit ahead of main" || { echo "  FAIL range accepted unsigned-ahead"; fail=1; }
  # A dirty tree must be refused.
  : > "$tmp/repo/dirty.txt"
  ! range_all_signed "$tmp/repo" && echo "  ok   range refuses a dirty tree" || { echo "  FAIL range accepted dirty tree"; fail=1; }
  rm -f "$tmp/repo/dirty.txt"

  [ "$fail" = 0 ] && echo "fleet-update self-test: OK" || { echo "fleet-update self-test: FAILED"; return 1; }
}

if [ "${1:-}" = "--self-test" ]; then self_test; exit $?; fi
main "$@"
