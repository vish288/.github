#!/usr/bin/env bash
# Regenerate the committed golden trees from the four answer sets. Run after any template
# change; review the resulting diff (it IS the rendered effect of the change, ×4). CI renders
# the same way and fails if the result differs from what is committed here.
#
# Usage: tests/regen-golden.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
for a in "$here"/answers/*.yml; do
  svc=$(basename "$a" .yml)
  "$here/render.sh" "$a" "$here/golden/$svc"
done
echo "regenerated golden for: $(cd "$here/answers" && ls *.yml | sed 's/.yml//' | tr '\n' ' ')"
