#!/usr/bin/env bash
# Pin the uvx install snippets in README.md and llms-full.txt to a target version, so a copied
# install command installs the version the docs describe. The release pipeline runs this in the
# server checkout after bumping the version; `release.yml` checks this repo out into .ci/ and
# calls `.ci/scripts/pin_install_snippets.sh <version>`.
#
# It rewrites ONLY the server's own pinned form `<pkg>[extras]@X.Y.Z`:
#   - anchored on the package identifier (server.json packages[0].identifier), so a different
#     tool's pin such as `uvx ruff@0.6.9` is never touched;
#   - the version is a strict X.Y.Z, so trailing punctuation (`...@0.21.3.`) is left intact;
#   - optional extras (`<pkg>[http]@X.Y.Z`) are preserved;
#   - it matches wherever the form appears — bare, in `uvx --from <pkg>@<ver>`, or a JSON arg
#     `"<pkg>@<ver>"` — because it keys off the identifier, not a leading `uvx`.
# A bare `uvx <pkg>` "try it" line has no @version, so nothing matches it.
#
# Usage: pin_install_snippets.sh <version>   (reads the package id from ./server.json via jq)
#        pin_install_snippets.sh --self-test
set -euo pipefail

# Rewrite <pkg>[extras]@X.Y.Z -> <pkg>[extras]@<version> in each file, in place and portably
# (BSD sed has no `sed -i <expr>` and no `\b`; write to a temp and move).
pin() {
  local pkg=$1 version=$2 f tmp
  shift 2
  for f in "$@"; do
    [ -f "$f" ] || continue
    tmp="$f.pintmp.$$"
    # Left boundary so `xmcp-gitlab@` is not matched, and `.` in the id is literal.
    sed -E "s#(^|[^A-Za-z0-9_.-])(${pkg//./\\.}(\[[^]]*\])?)@[0-9]+\.[0-9]+\.[0-9]+#\1\2@${version}#g" "$f" > "$tmp"
    mv "$tmp" "$f"
  done
}

_tmpd=""
self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
# Must return 0: on a normal end the EXIT trap's status becomes the script's exit code.
cleanup() { [ -z "$_tmpd" ] || rm -rf "$_tmpd"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

self_test() {
  local d fail=0
  d=$(mktemp -d)
  _tmpd=$d
  cat > "$d/doc.md" <<'EOF'
Run uvx mcp-gitlab@0.21.3.
(uvx mcp-gitlab@0.21.3)
"args": ["mcp-gitlab@0.21.3"]
uvx --from mcp-gitlab@0.21.3 mcp-gitlab
mcp-gitlab[http]@0.21.3
uvx ruff@0.6.9 check
uvx mcp-gitlab
xmcp-gitlab@1.2.3
mcp-gitlab@0.21.30 and "mcp-gitlab@0.1.0"
EOF
  cat > "$d/expect.md" <<'EOF'
Run uvx mcp-gitlab@9.9.9.
(uvx mcp-gitlab@9.9.9)
"args": ["mcp-gitlab@9.9.9"]
uvx --from mcp-gitlab@9.9.9 mcp-gitlab
mcp-gitlab[http]@9.9.9
uvx ruff@0.6.9 check
uvx mcp-gitlab
xmcp-gitlab@1.2.3
mcp-gitlab@9.9.9 and "mcp-gitlab@9.9.9"
EOF
  pin mcp-gitlab 9.9.9 "$d/doc.md"
  if diff -u "$d/expect.md" "$d/doc.md"; then
    echo "ok   pin_install_snippets"
  else
    echo "FAIL pin_install_snippets"; fail=1
  fi
  # The real entry point (as release.yml calls it) must exit 0 and rewrite in place.
  mkdir "$d/srv"
  printf '{"packages":[{"identifier":"mcp-gitlab"}]}' > "$d/srv/server.json"
  printf 'uvx mcp-gitlab@0.1.0\n' > "$d/srv/README.md"
  if (cd "$d/srv" && bash "$self" 1.2.3) && grep -q 'mcp-gitlab@1.2.3' "$d/srv/README.md"; then
    echo "ok   pin_install_snippets main"
  else
    echo "FAIL pin_install_snippets main"; fail=1
  fi
  return "$fail"
}

main() {
  if [ "${1:-}" = "--self-test" ]; then self_test; exit $?; fi
  local version=${1:-${NEXT_VERSION:-}}
  [ -n "$version" ] || { echo "usage: pin_install_snippets.sh <version>  (or set \$NEXT_VERSION)" >&2; exit 2; }
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "pin_install_snippets: version must be X.Y.Z, got '$version'" >&2; exit 2; }
  local pkg
  pkg=$(jq -r '.packages[0].identifier' server.json)
  [ -n "$pkg" ] && [ "$pkg" != null ] || { echo "::error::could not read packages[0].identifier from server.json" >&2; exit 1; }
  pin "$pkg" "$version" README.md llms-full.txt
}

main "$@"
