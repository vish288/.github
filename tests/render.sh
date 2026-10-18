#!/usr/bin/env bash
# Render one answer set and normalise the two volatile outputs so the result is stable across
# commits and carries no machine-specific path:
#   * stub `uses: …@<40-hex-sha> # <ref>`  -> `…@PIN`   (the pin tracks the template version)
#   * .copier-answers.yml `_commit:` / `_src_path:`      (git describe + absolute source path)
# Used by both tests/regen-golden.sh and .github/workflows/ci.yml, so golden generation and the
# CI check normalise identically.
#
# Usage: tests/render.sh <answers-file> <out-dir> [vcs-ref]
set -euo pipefail

cleanup() { [ -n "${_tmp:-}" ] && rm -rf "$_tmp"; }
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

answers=$1
out=$2
ref=${3:-HEAD}
here=$(cd "$(dirname "$0")/.." && pwd)   # template repo root (copier.yml lives here)

rm -rf "$out"
uvx copier copy --trust --defaults --data-file "$answers" -r "$ref" "$here" "$out" >/dev/null

# Normalise the version-dependent stub pins.
find "$out/.github/workflows" -name '*.yml' -print0 | while IFS= read -r -d '' f; do
  sed -E 's|@[0-9a-f]{40} #.*|@PIN|' "$f" > "$f.norm" && mv "$f.norm" "$f"
done

# Drop the machine-/version-specific answer-file lines.
ans="$out/.copier-answers.yml"
if [ -f "$ans" ]; then
  grep -vE '^(_commit|_src_path):' "$ans" > "$ans.norm" && mv "$ans.norm" "$ans"
fi
