#!/usr/bin/env bash
# Publish state of one tag against its targets, and the write paths that complete it.
#   state.sh pypi      TAG [--wait S] [--require STATE]   -> state=done|partial|missing
#   state.sh release   TAG [--wait S] [--require STATE]   -> state=done|draft|missing|mismatch   (exit 2 on mismatch)
#   state.sh registry  TAG [--wait S] [--require STATE]   -> state=done|missing|inactive          (exit 2 on inactive)
#   state.sh image-auth TAG                               -> state=done|missing|na   (authenticated; decides the build)
#   state.sh image-digest TAG                             -> the GHCR manifest digest for VER (empty if absent)
#   state.sh image      TAG                               -> state=done|unknown|na   (anonymous; feeds `all`)
#   state.sh all       TAG            -> pypi=.. release=.. registry=.. image=..   exit 0 all done, 2 unfixable, 1 incomplete
#   state.sh pypi-fetch TAG DIR       download the PyPI files; verify sha256 and trusted-publisher provenance
#   state.sh release-create TAG       delete leftover drafts, fetch from PyPI, create a draft by id, upload the files, then publish it (latest only for the highest tag)
#   state.sh registry-publish TAG     set the version in server.json, validate, login + publish under retry
#   state.sh gate JOB STATE           step summary line; honours the FAIL_AT test hook (dispatch, attempt 1, state != done)
#   state.sh --self-test              classifier fixtures, no network
# Needs curl, jq, gh (GH_TOKEN; GITHUB_REPOSITORY for release commands), python3 >= 3.11 or uv.
set -euo pipefail
trap 'exit 130' INT
trap 'exit 143' TERM
# Operate on the current working directory (the repo being released). The sibling
# scripts are resolved next to this file, so this works whether the scripts live in
# the repo under scripts/ci/ or are checked out from vish288/.github into .ci/.
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
RETRY="$SELF_DIR/retry.sh"
CURL=(curl -sS --retry 5 --retry-all-errors --max-time 60)
REGISTRY=https://registry.modelcontextprotocol.io/v0.1
PY=(python3); python3 -c 'import tomllib' 2>/dev/null || PY=(uv run --no-project --python 3.12 python)

out() { echo "$1"; [ -z "${GITHUB_OUTPUT:-}" ] || echo "$1" >> "$GITHUB_OUTPUT"; }
summary() { echo "$1" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }
fetch() { "${CURL[@]}" -o "$2" -w '%{http_code}' "$1" || true; }   # URL FILE -> prints the HTTP code (000 on failure)

# ---- classifiers: pure functions over JSON, exercised by --self-test ----
classify_pypi() {   # $1 PyPI version JSON
  jq -r 'if ([.urls[]?|select(.packagetype=="bdist_wheel")]|length)>0 and ([.urls[]?|select(.packagetype=="sdist")]|length)>0 then "done"
         elif (.urls|length)>0 then "partial" else "missing" end' <<<"$1"
}
classify_release() {   # $1 releases JSON array, $2 tag, $3 expected asset names (newline-separated)
  # ponytail: superset rule; extra assets on an old (immutable) release are tolerated, a wrong extra asset is not noticed.
  jq -r --arg t "$2" --arg exp "$3" '
    [.[]|select(.tag_name==$t)] as $r | ($exp|split("\n")|map(select(length>0))) as $want
    | ([$r[]|select(.draft|not)]|first) as $pub
    | if $pub then (if ([$want[]|select(. as $w|($pub.assets|map(.name)|index($w))==null)]|length)==0 then "done" else "mismatch" end)
      elif ([$r[]|select(.draft)]|length)>0 then "draft" else "missing" end' <<<"$1"
}
classify_registry() {   # $1 HTTP code, $2 body
  case "$1" in
    404) echo missing ;;
    200) [ "$(jq -r '._meta["io.modelcontextprotocol.registry/official"].status // empty' <<<"$2")" = active ] && echo "done" || echo inactive ;;
    *) echo "::error::registry returned HTTP $1" >&2; return 1 ;;
  esac
}
classify_image() {   # $1 HTTP code from an anonymous manifest HEAD
  case "$1" in
    200) echo "done" ;;
    401|403|404) echo "unknown" ;;   # missing or private; the authenticated check decides
    *) echo "::error::ghcr returned HTTP $1" >&2; return 1 ;;
  esac
}
classify_image_auth() {   # $1 HTTP code from an authenticated GHCR manifest HEAD (000 = no pull token issued)
  case "$1" in
    200) echo "done" ;;
    # 404: not pushed yet. 000: no token issued. 401/403: the token server issued an empty-access
    # token (distribution token spec) because the package does not exist yet. All mean "build";
    # the login step already proved the credentials, so a real auth fault still fails at the push.
    404|000|401|403) echo "missing" ;;
    *) echo "::error::ghcr manifest HEAD returned HTTP $1" >&2; return 1 ;;
  esac
}
draft_ids() {   # $1 releases JSON array, $2 tag -> ids of draft releases for the tag, newest id first (one per line)
  jq -r --arg t "$2" '[.[]|select(.tag_name==$t and .draft)]|sort_by(.id)|reverse|.[].id' <<<"$1"
}

# ---- live state ----
pypi_get() { fetch "https://pypi.org/pypi/$PKG/$VER/json" "$1"; }   # FILE -> prints the HTTP code
pypi_wait() {   # FILE -> prints the final HTTP code; polls until PyPI serves this version (CDN lag after upload)
  # Bounded (PYPI_WAIT s, default 300) with backoff. A 404 here means "not propagated yet", never
  # permanent: this is the ONLY place a PyPI 404 is retried. retry.sh still treats 404 as permanent
  # everywhere else, so only the just-uploaded-release read tolerates the Fastly/CDN lag.
  local f=$1 code d=5 deadline=$(( $(date +%s) + ${PYPI_WAIT:-300} ))
  while :; do
    code=$(pypi_get "$f")
    [ "$code" = 200 ] && { echo "$code"; return 0; }
    [ "$(date +%s)" -ge "$deadline" ] && { echo "$code"; return 1; }
    sleep "$d"; d=$(( d * 2 > 60 ? 60 : d * 2 ))
  done
}
state_pypi() {
  local f code; f=$(mktemp); code=$(pypi_get "$f")
  case "$code" in 200) classify_pypi "$(cat "$f")" ;; 404) echo missing ;; *) echo "::error::pypi.org HTTP $code" >&2; rm -f "$f"; return 1 ;; esac
  rm -f "$f"
}
releases_json() { gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/releases?per_page=100" | jq 'add // []'; }   # --slurp cannot be combined with --jq
expected_assets() { local f; f=$(mktemp); [ "$(pypi_get "$f")" = 200 ] || { rm -f "$f"; return 1; }; jq -r '.urls[].filename' "$f"; rm -f "$f"; }
state_release() { local exp; exp=$(expected_assets) || return 1; classify_release "$(releases_json)" "$TAG" "$exp"; }
state_registry() {
  local f code st; f=$(mktemp)
  code=$(fetch "$REGISTRY/servers/$(jq -rn --arg s "$SERVER" '$s|@uri')/versions/$VER" "$f")
  st=$(classify_registry "$code" "$(cat "$f")") || { rm -f "$f"; return 1; }
  rm -f "$f"; echo "$st"
}
image_pkg() {   # prints "<owner>/<package>" from the oci identifier, or empty when none
  jq -r '.packages[]? | select(.registryType=="oci") | .identifier' server.json 2>/dev/null \
    | head -1 | sed 's/:[^:/]*$//' | sed 's#^ghcr\.io/##'
}
image_repo() {   # the GHCR repository "<owner>/<name>": the oci identifier if present, else GITHUB_REPOSITORY
  local pkg; pkg=$(image_pkg); echo "${pkg:-$GITHUB_REPOSITORY}"
}
ghcr_head() {   # <owner>/<name> VER -> echoes "<code> <digest>"; code 000 when no pull token is issued
  local repo=$1 ver=$2 token hdr code digest
  token=$("${CURL[@]}" -u "${GITHUB_ACTOR:-}:${GH_TOKEN:-$(gh auth token 2>/dev/null || true)}" \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:$repo:pull,push" | jq -r '.token // empty')
  # pull,push like `docker push`: the job holds packages: write, so a not-yet-pushed name gets a
  # token with push access and the manifest HEAD answers 404 instead of 401/403.
  [ -n "$token" ] || { echo "000 "; return 0; }   # token server grants an empty-access token for a
  # never-pushed/denied package (distribution token spec); with no usable token, treat it as missing
  # and let build-push's own push decide loudly.
  hdr=$(mktemp)
  code=$("${CURL[@]}" -I -o /dev/null -D "$hdr" -w '%{http_code}' \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://ghcr.io/v2/$repo/manifests/$ver") || true
  digest=$(grep -i '^docker-content-digest:' "$hdr" | tr -d '\r' | awk '{print $2}')
  rm -f "$hdr"
  echo "$code ${digest:-}"
}
state_image_auth() {   # authenticated; used only inside the logged-in image job. Decides the build.
  # Build whenever a root Dockerfile exists: an image-only first release has no oci entry yet, so the
  # package comes from the oci identifier when present, else from GITHUB_REPOSITORY. na only without one.
  local res
  [ -f Dockerfile ] || { echo na; return 0; }
  res=$(ghcr_head "$(image_repo)" "$VER")
  classify_image_auth "${res%% *}"
}
cmd_image_digest() {   # the manifest digest for VER (empty when the image is not present)
  local res; res=$(ghcr_head "$(image_repo)" "$VER"); echo "${res#* }"
}
state_image() {   # anonymous; done only when the image is publicly pullable
  local ref pkg token code
  ref=$(jq -r '.packages[]? | select(.registryType=="oci") | .identifier' server.json 2>/dev/null | head -1)
  [ -n "$ref" ] || { echo na; return 0; }
  pkg=${ref%%:*}; pkg=${pkg#ghcr.io/}
  token=$("${CURL[@]}" "https://ghcr.io/token?service=ghcr.io&scope=repository:$pkg:pull" | jq -r '.token // empty')
  [ -n "$token" ] || { echo unknown; return 0; }
  code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://ghcr.io/v2/$pkg/manifests/$VER") || true
  classify_image "$code"
}
poll() {   # FN WAIT REQUIRE -> prints state=..., exits 1 if REQUIRE unmet, 2 if unfixable
  local fn=$1 req=$3 st deadline=$(( $(date +%s) + $2 ))
  while :; do
    st=$($fn) || st=error
    { [ -z "$req" ] || [ "$st" = "$req" ] || [ "$(date +%s)" -ge "$deadline" ]; } && break
    sleep 10
  done
  out "state=$st"
  case "$st" in
    mismatch) echo "::error::published release $TAG lacks a PyPI file. Immutable: CI cannot fix it; ship the next patch version." >&2; exit 2 ;;
    inactive) echo "::error::registry entry $SERVER@$VER exists but is not active. CI cannot fix it; ship the next patch version." >&2; exit 2 ;;
  esac
  [ -z "$req" ] || [ "$st" = "$req" ] || { echo "::error::$fn is '$st', expected '$req'" >&2; exit 1; }
}

# ---- write paths ----
cmd_pypi_fetch() {   # DIR
  local dir=$1 f code name url sha pub
  # Wait for PyPI to serve the version: github-release runs right after the pypi job, when the
  # just-uploaded files can still 404 on the CDN (observed: mcp-gitlab run 38502039947).
  mkdir -p "$dir"; f=$(mktemp); code=$(pypi_wait "$f") || true
  [ "$code" = 200 ] || { echo "::error::$PKG $VER is not on PyPI (HTTP $code) after ${PYPI_WAIT:-300}s"; return 1; }
  while IFS=$'\t' read -r name url sha; do
    "${CURL[@]}" -o "$dir/$name" "$url"
    echo "$sha  $dir/$name" | sha256sum -c -
    pub=$("${CURL[@]}" "https://pypi.org/integrity/$PKG/$VER/$name/provenance" | jq -r '.attestation_bundles[0].publisher | "\(.repository) \(.workflow)"')
    [ "$pub" = "$GITHUB_REPOSITORY publish.yml" ] || { echo "::error::$name provenance is '$pub', expected '$GITHUB_REPOSITORY publish.yml' (uploaded outside this pipeline?)"; return 1; }
  done < <(jq -r '.urls[]|[.filename,.url,.digests.sha256]|@tsv' "$f")
  rm -f "$f"; ls -l "$dir"
}
cmd_release_create() {
  local id highest latest f up raw flat ids
  # Idempotency: remove any leftover drafts for TAG from earlier attempts (handles 0, 1 or >1).
  # The releases list is eventually consistent, so fetch it under retry; fail loudly if the
  # fetch or its JSON is bad rather than silently skipping cleanup inside a for-word-list.
  raw=$("$RETRY" gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/releases?per_page=100") \
    || { echo "::error::could not list releases for draft cleanup"; return 1; }
  flat=$(jq 'add // []' <<<"$raw") || { echo "::error::releases list is not valid JSON"; return 1; }
  ids=$(draft_ids "$flat" "$TAG")
  for id in $ids; do
    echo "deleting leftover draft release $id"; "$RETRY" gh api -X DELETE "repos/$GITHUB_REPOSITORY/releases/$id"
  done
  rm -rf assets; cmd_pypi_fetch assets
  highest=$(gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/tags?per_page=100" | jq -r 'add // [] | .[].name' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
  latest=false; [ "$TAG" = "$highest" ] && latest=true
  # Refuse if the tag does not exist on the remote (the old --verify-tag guard); a bare POST would
  # otherwise auto-create a tag at the default branch.
  "$RETRY" gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$TAG" --jq .object.sha >/dev/null \
    || { echo "::error::tag $TAG does not exist on $GITHUB_REPOSITORY"; return 1; }
  # Create the draft via the API so we get its id directly: no post-create list lookup, no
  # eventual-consistency race (a drafts list may not yet include the release we just made).
  # ponytail: POST/upload are not idempotent, so a retry after a half-done attempt can leave an
  # orphan draft; it is harmless (the next run's cleanup deletes it) and 422 already_exists stays
  # permanent in retry.sh, so a retry never double-creates.
  id=$("$RETRY" gh api -X POST "repos/$GITHUB_REPOSITORY/releases" \
        -f tag_name="$TAG" -f name="$TAG" -F draft=true -F generate_release_notes=true --jq .id) \
    || { echo "::warning::draft creation failed; the next run deletes the draft and retries"; return 0; }
  [[ $id =~ ^[0-9]+$ ]] || { echo "::error::draft creation returned a non-numeric id '$id' for $TAG"; return 1; }
  # Upload the PyPI files to that release id (drafts are addressable by id, not by tag).
  up="https://uploads.github.com/repos/$GITHUB_REPOSITORY/releases/$id/assets"
  for f in assets/*; do
    "$RETRY" gh api --method POST "$up?name=$(basename "$f")" -H "Content-Type: application/octet-stream" --input "$f" >/dev/null \
      || { echo "::error::uploading $(basename "$f") to release $id failed"; return 1; }
  done
  "$RETRY" gh api -X PATCH "repos/$GITHUB_REPOSITORY/releases/$id" -F draft=false -f make_latest="$latest" >/dev/null \
    || echo "::warning::publishing draft $id failed; the confirm step decides"
}
cmd_registry_publish() {
  # The oci tag lives in the identifier (registry/namespace/repo:tag), so rewrite that suffix
  # as well as the package version. The release commit is the real fix; this is a backstop.
  jq --arg v "$VER" '
    .version=$v
    | (.packages[]?.version)=$v
    | (.packages[]? | select(.registryType=="oci") | .identifier) |= sub(":[^:/]*$"; ":" + $v)
  ' server.json > server.json.tmp && mv server.json.tmp server.json
  mcp-publisher validate
  "$RETRY" bash -c 'mcp-publisher login github-oidc && mcp-publisher publish' \
    || echo "::warning::mcp-publisher publish failed; the confirm step decides"
}
cmd_gate() {   # JOB STATE
  summary "- $1: $2"
  if [ "${FAIL_AT:-none}" = "$1" ] && [ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ] && [ "${GITHUB_RUN_ATTEMPT:-1}" = 1 ] && [ "$2" != "done" ]; then
    echo "::error::test hook fail_at=$1 (attempt 1, state=$2): failing before any write"; exit 1
  fi
}
cmd_all() {
  local p r g i
  p=$(state_pypi) || p=error; r=$(state_release) || r=error; g=$(state_registry) || g=error; i=$(state_image) || i=error
  out "pypi=$p"; out "release=$r"; out "registry=$g"; out "image=$i"
  summary "| $TAG | pypi=$p release=$r registry=$g image=$i | |"
  case "$p/$r/$g/$i" in
    done/done/done/done|done/done/done/na) exit 0 ;;
    *mismatch*|*inactive*) exit 2 ;;
    *) exit 1 ;;
  esac
}

self_test() {
  local bad=0 rel drafts stub body n got rc gstub wd
  t() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$3' want '$2'"; bad=1; fi; }
  t pypi-done     "done"   "$(classify_pypi '{"urls":[{"packagetype":"bdist_wheel"},{"packagetype":"sdist"}]}')"
  t pypi-partial  partial  "$(classify_pypi '{"urls":[{"packagetype":"sdist"}]}')"
  t pypi-empty    missing  "$(classify_pypi '{"urls":[]}')"
  rel='[{"tag_name":"v1.0.0","draft":false,"assets":[{"name":"a.whl"},{"name":"a.tar.gz"},{"name":"default.gitignore"}]},
        {"tag_name":"v1.0.1","draft":true,"id":7,"assets":[]},
        {"tag_name":"v1.0.2","draft":false,"assets":[{"name":"b.whl"}]}]'
  t rel-done      "done"   "$(classify_release "$rel" v1.0.0 $'a.whl\na.tar.gz')"
  t rel-draft     draft    "$(classify_release "$rel" v1.0.1 $'x.whl\nx.tar.gz')"
  t rel-mismatch  mismatch "$(classify_release "$rel" v1.0.2 $'b.whl\nb.tar.gz')"
  t rel-missing   missing  "$(classify_release "$rel" v9.9.9 $'z.whl\nz.tar.gz')"
  t reg-done      "done"   "$(classify_registry 200 '{"_meta":{"io.modelcontextprotocol.registry/official":{"status":"active"}}}')"
  t reg-inactive  inactive "$(classify_registry 200 '{"_meta":{"io.modelcontextprotocol.registry/official":{"status":"deleted"}}}')"
  t reg-missing   missing  "$(classify_registry 404 '{"status":404,"detail":"Server not found"}')"
  t img-public    "done"    "$(classify_image 200)"
  t img-private   "unknown" "$(classify_image 403)"
  t img-missing   "unknown" "$(classify_image 404)"
  t imgauth-200    "done"    "$(classify_image_auth 200)"
  t imgauth-404    "missing" "$(classify_image_auth 404)"
  t imgauth-denied "missing" "$(classify_image_auth 000)"
  t imgauth-401    "missing" "$(classify_image_auth 401)"
  t imgauth-403    "missing" "$(classify_image_auth 403)"
  got=$(classify_image_auth 500 2>/dev/null) && rc=0 || rc=$?
  t imgauth-error "1" "$rc"
  # draft lookup for release-create idempotency: 0 (create→immediate lookup miss), 1 (reuse), >1 (cleanup)
  drafts='[{"tag_name":"v2.0.0","draft":true,"id":11},{"tag_name":"v2.0.0","draft":true,"id":9},
           {"tag_name":"v2.0.0","draft":false,"id":5},{"tag_name":"v2.0.1","draft":true,"id":8}]'
  t draft-miss    ""       "$(draft_ids "$drafts" v9.9.9)"
  t draft-one     "8"      "$(draft_ids "$drafts" v2.0.1)"
  t draft-many    $'11\n9' "$(draft_ids "$drafts" v2.0.0)"
  # pypi_wait: PATH-stub curl + sleep so the propagation poll runs with no network and no real sleeps.
  stub=$(mktemp -d); body=$(mktemp); n=$(mktemp)
  cat > "$stub/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  cat > "$stub/curl" <<'STUB'
#!/usr/bin/env bash
# fake curl: writes the -o target, prints an HTTP code; 404 until call CURL_OK_AT, then 200.
out=; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
c=$(( $(cat "$CURL_N" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$CURL_N"
: > "${out:-/dev/null}"
if [ "$c" -ge "${CURL_OK_AT:-1}" ]; then echo 200; else echo 404; fi
STUB
  chmod +x "$stub/sleep" "$stub/curl"
  echo 0 > "$n"
  got=$( export PATH="$stub:$PATH" CURL_N="$n" CURL_OK_AT=3 PKG=x VER=1; pypi_wait "$body" ) && rc=0 || rc=$?
  t pypi_wait-propagates "200 0" "$got $rc"
  echo 0 > "$n"
  got=$( export PATH="$stub:$PATH" CURL_N="$n" CURL_OK_AT=99 PYPI_WAIT=0 PKG=x VER=1; pypi_wait "$body" ) && rc=0 || rc=$?
  t pypi_wait-timeout "404 1" "$got $rc"
  # poll: a stubbed state fn returns error then done; the no-op sleep keeps this fast.
  polln=$(mktemp); echo 0 > "$polln"
  stub_poll() { local c; c=$(( $(cat "$polln") + 1 )); echo "$c" > "$polln"; [ "$c" -ge 2 ] && echo "done" || echo error; }
  got=$( export PATH="$stub:$PATH"; poll stub_poll 30 "done" ) && rc=0 || rc=$?
  t poll-eventual "state=done 0" "$got $rc"
  stub_error() { echo error; }
  got=$( export PATH="$stub:$PATH"; poll stub_error 0 "done" ) && rc=0 || rc=$?
  t poll-timeout "state=error 1" "$got $rc"
  # state_image_auth: a Dockerfile decides na; WITH a Dockerfile it probes GHCR even when server.json
  # has no oci entry (image-only first release). Stub curl: token req -> a token, manifest HEAD -> GHCR_CODE.
  gstub=$(mktemp -d); wd=$(mktemp -d)
  cat > "$gstub/curl" <<'STUB'
#!/usr/bin/env bash
url=; dd=; prev=
for a in "$@"; do url=$a; [ "$prev" = -D ] && dd=$a; prev=$a; done
case "$url" in
  *ghcr.io/token*) echo '{"token":"stub"}' ;;
  *ghcr.io/v2/*manifests*) [ -n "$dd" ] && printf 'Docker-Content-Digest: sha256:deadbeef\r\n' > "$dd"; echo "${GHCR_CODE:-200}" ;;
esac
STUB
  chmod +x "$gstub/curl"
  echo '{"name":"x","packages":[{"registryType":"pypi","identifier":"s"}]}' > "$wd/server.json"
  got=$( cd "$wd"; export PATH="$gstub:$PATH" VER=1 GITHUB_REPOSITORY=o/n GITHUB_ACTOR=a GH_TOKEN=t; state_image_auth )
  t imgauth-na-no-dockerfile na "$got"
  : > "$wd/Dockerfile"
  got=$( cd "$wd"; export PATH="$gstub:$PATH" GHCR_CODE=404 VER=1 GITHUB_REPOSITORY=o/n GITHUB_ACTOR=a GH_TOKEN=t; state_image_auth )
  t imgauth-missing-no-oci "missing" "$got"
  got=$( cd "$wd"; export PATH="$gstub:$PATH" GHCR_CODE=200 VER=1 GITHUB_REPOSITORY=o/n GITHUB_ACTOR=a GH_TOKEN=t; state_image_auth )
  t imgauth-done-no-oci "done" "$got"
  got=$( cd "$wd"; export PATH="$gstub:$PATH" VER=1 GITHUB_REPOSITORY=o/n GITHUB_ACTOR=a GH_TOKEN=t; cmd_image_digest )
  t image-digest "sha256:deadbeef" "$got"
  rm -rf "$gstub" "$wd"
  rm -rf "$stub"; rm -f "$body" "$n" "$polln"
  exit $bad
}

case "${1:-}" in
  --self-test) self_test ;;
  gate) cmd_gate "${2:?job}" "${3:?state}"; exit 0 ;;
esac
CMD=${1:?command}; TAG=${2:?tag}; shift 2
VER=${TAG#v}
# Outside CI GITHUB_REPOSITORY is unset; derive it so local runs of release/all do not trip `set -u`.
: "${GITHUB_REPOSITORY:=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
PKG=$("${PY[@]}" -c 'import tomllib;print(tomllib.load(open("pyproject.toml","rb"))["project"]["name"])')
SERVER=$(jq -r .name server.json)
WAIT=0; REQ=; ARG=
while [ $# -gt 0 ]; do
  case $1 in --wait) WAIT=$2; shift ;; --require) REQ=$2; shift ;; *) ARG=$1 ;; esac; shift
done
case $CMD in
  pypi)             poll state_pypi "$WAIT" "$REQ" ;;
  release)          poll state_release "$WAIT" "$REQ" ;;
  registry)         poll state_registry "$WAIT" "$REQ" ;;
  image-auth)       state_image_auth ;;
  image-digest)     cmd_image_digest ;;
  image)            state_image ;;
  all)              cmd_all ;;
  pypi-fetch)       cmd_pypi_fetch "${ARG:?dir}" ;;
  release-create)   cmd_release_create ;;
  registry-publish) cmd_registry_publish ;;
  *) echo "unknown command: $CMD" >&2; exit 64 ;;
esac
