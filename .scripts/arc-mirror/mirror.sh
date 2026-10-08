#!/usr/bin/env bash
# Mirror the ARC (actions-runner-controller) Helm charts and images into Harbor.
# Card #338. Runbook: docs/arc-mirror.md. Pins: artifacts.lock (same directory).
#
# Modes:
#   check                 READ-ONLY. Resolve every upstream tag, compare with the
#                         pinned digest, check that each image index has
#                         linux/arm64 (required) and linux/amd64, print sizes and
#                         the Harbor refs. Touches nothing. Default mode.
#   copy                  Upstream -> Harbor directly (lab path, needs internet).
#   export <dir>          Upstream -> one OCI image layout per artifact under
#                         <dir>/oci/<name>, plus a copy of the lock. Carry <dir>
#                         (or a tar of it) into the airgap.
#   import <dir>          <dir> (from export) -> Harbor. Checks every layout
#                         digest against the lock before pushing.
#   verify                READ-ONLY against Harbor: the pinned tag exists in
#                         Harbor and resolves to the pinned digest.
#
# Options:
#   --include-optional    also handle `optional` lock entries (the docker:dind
#                         image, only needed for ARC containerMode dind)
#   --lock <file>         alternative lock file
#
# Environment (no secrets in this file, ever):
#   HARBOR_REGISTRY       default harbor.lab.local
#   HARBOR_PROJECT        default actions
#   HARBOR_RESOLVE_IP     default 192.168.50.200 (gateway VIP). Passed to oras as
#                         --resolve, because Go tools may not resolve *.local
#                         names via DNS (AGENTS.md pitfall). Empty = use DNS.
#   HARBOR_CA_FILE        lab CA bundle. Default: lab-root-ca.crt at the repo root.
#   HARBOR_USERNAME / HARBOR_PASSWORD
#                         push credentials (a robot with push on the project).
#                         Written only to a 0600 temp auth file, never to argv.
#   HARBOR_REGISTRY_CONFIG
#                         alternative: an existing docker/oras auth file
#                         (e.g. ~/.docker/config.json after `oras login`).
#   ORAS                  oras binary to use. If unset and `oras` is not on PATH,
#                         the pinned oras container image is run with docker.
#
# Requirements: bash, jq, and either oras >= 1.2 or docker.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Pinned oras container (used only when no local oras binary exists).
ORAS_IMAGE="ghcr.io/oras-project/oras:v1.3.4@sha256:f7bc056d54d97baa399414ed5048ecc67c3371b750d4bbce1d871827a5758179"

LOCK="$SCRIPT_DIR/artifacts.lock"
INCLUDE_OPTIONAL=0
MODE="check"
DIR=""

HARBOR_REGISTRY="${HARBOR_REGISTRY:-harbor.lab.local}"
HARBOR_PROJECT="${HARBOR_PROJECT:-actions}"
HARBOR_RESOLVE_IP="${HARBOR_RESOLVE_IP-192.168.50.200}"
HARBOR_CA_FILE="${HARBOR_CA_FILE:-$REPO_ROOT/lab-root-ca.crt}"

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    check|copy|verify) MODE="$1" ;;
    export|import) MODE="$1"; DIR="${2:-}"; [ -n "$DIR" ] || die "$1 needs a directory"; shift ;;
    --include-optional) INCLUDE_OPTIONAL=1 ;;
    --lock) LOCK="${2:-}"; shift ;;
    -h|--help) usage 0 ;;
    *) log "unknown argument: $1"; usage 1 ;;
  esac
  shift
done

command -v jq >/dev/null || die "jq is required"
[ -f "$LOCK" ] || die "lock file not found: $LOCK"

# ---------------------------------------------------------------- oras runner
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

if [ -n "${ORAS:-}" ]; then
  ORAS_MODE=bin
elif command -v oras >/dev/null; then
  ORAS=oras; ORAS_MODE=bin
elif command -v docker >/dev/null; then
  ORAS_MODE=docker
else
  die "need oras (https://oras.land) or docker on PATH"
fi

# Paths the docker-run oras must see are bind-mounted at the same path.
MOUNTS=("$TMP")
oras() {
  if [ "$ORAS_MODE" = bin ]; then
    "$ORAS" "$@"
  else
    local m args=()
    for m in "${MOUNTS[@]}"; do args+=(-v "$m:$m"); done
    docker run --rm --network host --user "$(id -u):$(id -g)" -e HOME="$TMP" \
      -w "$TMP" "${args[@]}" "$ORAS_IMAGE" "$@"
  fi
}

# Destination (Harbor) flags. $1 = flag prefix: "" for single-registry
# commands, "to-" for copy destinations.
harbor_flags() {
  local p="$1" out=()
  if [ -n "$HARBOR_RESOLVE_IP" ]; then
    out+=("--${p}resolve" "${HARBOR_REGISTRY}:443:${HARBOR_RESOLVE_IP}")
  fi
  if [ -f "$HARBOR_CA_FILE" ]; then
    out+=("--${p}ca-file" "$HARBOR_CA_FILE")
  fi
  if [ -n "${AUTH_FILE:-}" ]; then
    out+=("--${p}registry-config" "$AUTH_FILE")
  fi
  printf '%s\n' "${out[@]}"
}

setup_harbor_access() {   # $1 = need push credentials (1/0)
  if [ -f "$HARBOR_CA_FILE" ]; then
    HARBOR_CA_FILE="$(cd "$(dirname "$HARBOR_CA_FILE")" && pwd)/$(basename "$HARBOR_CA_FILE")"
    MOUNTS+=("$(dirname "$HARBOR_CA_FILE")")
  else
    log "WARN: CA file $HARBOR_CA_FILE not found; relying on the system trust store"
  fi
  AUTH_FILE=""
  if [ -n "${HARBOR_REGISTRY_CONFIG:-}" ]; then
    [ -f "$HARBOR_REGISTRY_CONFIG" ] || die "HARBOR_REGISTRY_CONFIG not found"
    AUTH_FILE="$HARBOR_REGISTRY_CONFIG"
    MOUNTS+=("$(cd "$(dirname "$AUTH_FILE")" && pwd)")
    AUTH_FILE="$(cd "$(dirname "$AUTH_FILE")" && pwd)/$(basename "$AUTH_FILE")"
  elif [ -n "${HARBOR_USERNAME:-}" ]; then
    [ -n "${HARBOR_PASSWORD:-}" ] || die "HARBOR_USERNAME set but HARBOR_PASSWORD empty"
    AUTH_FILE="$TMP/auth.json"
    ( umask 077
      jq -n --arg r "$HARBOR_REGISTRY" \
            --arg a "$(printf '%s:%s' "$HARBOR_USERNAME" "$HARBOR_PASSWORD" | base64 | tr -d '\n')" \
            '{auths: {($r): {auth: $a}}}' > "$AUTH_FILE" )
  elif [ "$1" = 1 ]; then
    die "push needs HARBOR_USERNAME/HARBOR_PASSWORD or HARBOR_REGISTRY_CONFIG"
  fi
}

# ------------------------------------------------------------------ lock file
# Parsed and validated once, in the main shell, so a bad lock aborts the run.
# ENTRIES lines: kind name source tag digest target need
ENTRIES=()
load_entries() {
  local n=0 kind name source tag digest target need extra
  while read -r kind name source tag digest target need extra; do
    n=$((n + 1))
    case "$kind" in ''|'#'*) continue ;; esac
    [ -n "$need" ] && [ -z "$extra" ] || die "$LOCK line $n: expected 7 columns"
    case "$kind" in chart|image) ;; *) die "$LOCK line $n: bad kind '$kind'" ;; esac
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "$LOCK line $n: bad digest for $name"
    case "$need" in
      required) ;;
      optional) [ "$INCLUDE_OPTIONAL" = 1 ] || continue ;;
      *) die "$LOCK line $n: bad need '$need'" ;;
    esac
    ENTRIES+=("$kind $name $source $tag $digest $target $need")
  done < "$LOCK"
  [ "${#ENTRIES[@]}" -gt 0 ] || die "no entries in $LOCK"
}
entries() { printf '%s\n' "${ENTRIES[@]}"; }

dest_repo() { printf '%s/%s/%s' "$HARBOR_REGISTRY" "$HARBOR_PROJECT" "$1"; }

human() { awk -v b="$1" 'BEGIN { split("B KiB MiB GiB", u, " "); i=1; while (b>=1024 && i<4) { b/=1024; i++ } printf "%.1f %s", b, u[i] }'; }

# ---------------------------------------------------------------------- check
# Prints a report; returns non-zero on any hard failure (arm64 missing,
# digest unreachable, wrong artifact type). A moved upstream tag is a WARN.
check_entry() {
  local kind="$1" name="$2" source="$3" tag="$4" digest="$5" target="$6" need="$7"
  local rc=0 tagdig body mt size=0 plats

  printf '%-17s %s:%s\n' "$name" "$source" "$tag"
  printf '  pinned  %s\n' "$digest"
  tagdig="$(oras manifest fetch --descriptor "$source:$tag" | jq -r .digest)" || { log "  FAIL $name: cannot resolve $source:$tag"; return 1; }
  if [ "$tagdig" = "$digest" ]; then
    printf '  tag     %s (matches)\n' "$tagdig"
  else
    printf '  tag     %s  WARN: differs from the pin (upstream tag moved, or a new pin to paste in)\n' "$tagdig"
  fi
  body="$(oras manifest fetch "$source@$digest")" || { log "  FAIL $name: pinned digest $digest not found upstream"; return 1; }
  mt="$(jq -r '.mediaType // "application/vnd.oci.image.manifest.v1+json"' <<<"$body")"

  if [ "$kind" = chart ]; then
    if [ "$(jq -r .config.mediaType <<<"$body")" != "application/vnd.cncf.helm.config.v1+json" ]; then
      log "  FAIL $name: not a Helm chart artifact"; rc=1
    fi
    size="$(jq '[.layers[].size, .config.size] | add' <<<"$body")"
    printf '  type    helm chart (%s)\n' "$(human "$size")"
    printf '  harbor  oci://%s/%s/%s --version %s\n' "$HARBOR_REGISTRY" "$HARBOR_PROJECT" "${target%/*}" "$tag"
    printf '          (chart repo %s, chart %s)\n' "$(dest_repo "${target%/*}")" "${target##*/}"
  else
    case "$mt" in
      *manifest.list*|*image.index*) ;;
      *) log "  FAIL $name: $mt is a single-arch manifest; expected a multi-arch index"; return 1 ;;
    esac
    plats="$(jq -r '[.manifests[] | select(.platform.os != "unknown") | .platform.os + "/" + .platform.architecture + (if .platform.variant then "/" + .platform.variant else "" end)] | join(" ")' <<<"$body")"
    printf '  type    multi-arch index; platforms: %s\n' "$plats"
    if jq -e '[.manifests[] | select(.platform.os=="linux" and .platform.architecture=="arm64")] | length > 0' <<<"$body" >/dev/null; then
      printf '  arm64   OK (%s)\n' "$(jq -r '[.manifests[] | select(.platform.os=="linux" and .platform.architecture=="arm64") | .digest][0]' <<<"$body")"
    else
      log "  FAIL $name: no linux/arm64 image in the index (the cluster is arm64)"; rc=1
    fi
    jq -e '[.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64")] | length > 0' <<<"$body" >/dev/null \
      || printf '  amd64   WARN: no linux/amd64\n'
    # Size of everything the full-index copy transfers (all platforms + attestations).
    local d s
    for d in $(jq -r '.manifests[].digest' <<<"$body"); do
      s="$(oras manifest fetch "${source}@${d}" | jq '[.layers[]?.size, .config.size // 0] | add // 0')"
      size=$((size + s))
    done
    printf '  copy    %s compressed (all platforms)\n' "$(human "$size")"
    printf '  harbor  %s:%s@%s\n' "$(dest_repo "$target")" "$tag" "$digest"
  fi
  printf '  need    %s\n' "$need"
  return "$rc"
}

do_check() {
  local fails=0 line
  log "== check (read-only): lock $LOCK; target $HARBOR_REGISTRY/$HARBOR_PROJECT; oras via $ORAS_MODE"
  while read -r line; do
    # shellcheck disable=SC2086
    check_entry $line || fails=$((fails + 1))
  done < <(entries)
  if [ "$INCLUDE_OPTIONAL" = 0 ]; then
    log "(optional entries skipped; add --include-optional to include the dind image)"
  fi
  [ "$fails" = 0 ] || die "$fails artifact(s) failed the check"
  log "== check OK"
}

# ------------------------------------------------------------- copy / verify
harbor_digest() {   # $1 = ref ; prints digest or empty
  local f
  mapfile -t f < <(harbor_flags "")
  oras manifest fetch --descriptor "${f[@]}" "$1" 2>/dev/null | jq -r .digest || true
}

verify_entry() {
  local name="$2" tag="$4" digest="$5" target="$6" ref got
  ref="$(dest_repo "$target"):$tag"
  got="$(harbor_digest "$ref")"
  if [ "$got" = "$digest" ]; then
    printf 'OK    %-17s %s @ %s\n' "$name" "$ref" "$digest"
  else
    printf 'FAIL  %-17s %s: harbor=%s pinned=%s\n' "$name" "$ref" "${got:-<missing>}" "$digest"
    return 1
  fi
}

do_verify() {
  setup_harbor_access 0
  local fails=0 line
  while read -r line; do
    # shellcheck disable=SC2086
    verify_entry $line || fails=$((fails + 1))
  done < <(entries)
  [ "$fails" = 0 ] || die "$fails artifact(s) missing or wrong in Harbor"
  log "== verify OK: Harbor matches the lock"
}

do_copy() {
  setup_harbor_access 1
  local kind name source tag digest target need f
  mapfile -t f < <(harbor_flags "to-")
  while read -r kind name source tag digest target need; do
    log "== copy $name: $source@$digest -> $(dest_repo "$target"):$tag"
    # No --platform: the whole index (every platform + attestations) is copied,
    # so the digest in Harbor equals the upstream digest.
    oras copy --concurrency 4 "${f[@]}" "$source@$digest" "$(dest_repo "$target"):$tag"
    verify_entry "$kind" "$name" "$source" "$tag" "$digest" "$target" "$need"
  done < <(entries)
  log "== copy done"
}

# ------------------------------------------------------------ export / import
do_export() {
  mkdir -p "$DIR/oci"
  DIR="$(cd "$DIR" && pwd)"
  MOUNTS+=("$DIR")
  local kind name source tag digest target need got
  while read -r kind name source tag digest target need; do
    log "== export $name: $source@$digest -> $DIR/oci/$name:$tag"
    oras copy --concurrency 4 --to-oci-layout "$source@$digest" "$DIR/oci/$name:$tag"
    got="$(oras manifest fetch --descriptor --oci-layout "$DIR/oci/$name:$tag" | jq -r .digest)"
    [ "$got" = "$digest" ] || die "$name: exported digest $got != pinned $digest"
    log "   OK $got"
  done < <(entries)
  cp "$LOCK" "$DIR/artifacts.lock"
  cp "${BASH_SOURCE[0]}" "$DIR/mirror.sh"
  log "== export done: $DIR ($(du -sh "$DIR" | cut -f1)). Carry it in, e.g. tar -C $(dirname "$DIR") -cf arc-mirror.tar $(basename "$DIR")"
}

do_import() {
  [ -d "$DIR/oci" ] || die "$DIR/oci not found (not an export directory?)"
  DIR="$(cd "$DIR" && pwd)"
  MOUNTS+=("$DIR")
  setup_harbor_access 1
  local kind name source tag digest target need got f
  mapfile -t f < <(harbor_flags "to-")
  while read -r kind name source tag digest target need; do
    got="$(oras manifest fetch --descriptor --oci-layout "$DIR/oci/$name:$tag" | jq -r .digest)" \
      || die "$name: $DIR/oci/$name:$tag missing from the export"
    [ "$got" = "$digest" ] || die "$name: layout digest $got != pinned $digest (wrong export for this lock?)"
    log "== import $name: $DIR/oci/$name:$tag -> $(dest_repo "$target"):$tag"
    oras copy --concurrency 4 --from-oci-layout "${f[@]}" "$DIR/oci/$name:$tag" "$(dest_repo "$target"):$tag"
    verify_entry "$kind" "$name" "$source" "$tag" "$digest" "$target" "$need"
  done < <(entries)
  log "== import done"
}

load_entries
case "$MODE" in
  check)  do_check ;;
  verify) do_verify ;;
  copy)   do_copy ;;
  export) do_export ;;
  import) do_import ;;
esac
