#!/usr/bin/env bash
# Build (and optionally push) the ARC job-container images under this directory.
# Card #340. Docs: landingzones/arc-runners/README.md ("Job image").
#
# Usage:
#   build.sh build <image> [version]   build linux/arm64 locally (docker buildx,
#                                      --load into the local docker). No push.
#   build.sh push  <image> [version]   build, then push to
#                                      $HARBOR_REGISTRY/$HARBOR_PROJECT/<image>:<version>
#                                      and print the pushed digest to pin.
#   build.sh smoke <image> [version]   build, then run a few checks in the image
#                                      (tools present, uid, the runner's node
#                                      from a mounted externals dir if
#                                      EXTERNALS_DIR is set).
#
# <image> is a subdirectory with a Dockerfile (today: ci-build). The version
# defaults to the VERSION file in that directory.
#
# Always linux/arm64 (the cluster is arm64) and --provenance=false (CLAUDE.md:
# otherwise the nodes fail with "ImagePullBackOff: no match for platform"). On an
# amd64 workstation docker buildx emulates arm64 with QEMU; that is fine for
# building this image. (Workflow image builds run natively on the arm64 nodes.)
#
# Environment (no secrets in this file, ever):
#   HARBOR_REGISTRY        default harbor.lab.local
#   HARBOR_PROJECT         default actions
#   BUILDER                buildx builder, default `default` (the docker driver,
#                          which pulls through the docker daemon and therefore
#                          trusts what the daemon trusts, e.g. the lab CA)
#   HARBOR_USERNAME / HARBOR_PASSWORD
#                          push credential. If both are unset, `push` reads the
#                          project robot's secret from the cluster like
#                          .scripts/arc-mirror/mirror.sh does:
#   HARBOR_ROBOT_SECRET    default harbor-<project>-robot (key `secret`)
#   HARBOR_ROBOT_NAMESPACE default harbor
#   HARBOR_ROBOT_USER      default robot$<project>+push
# The credential only goes into a 0600 temporary docker config that is deleted
# on exit; ~/.docker/config.json is not touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARBOR_REGISTRY="${HARBOR_REGISTRY:-harbor.lab.local}"
HARBOR_PROJECT="${HARBOR_PROJECT:-actions}"
HARBOR_ROBOT_SECRET="${HARBOR_ROBOT_SECRET:-harbor-${HARBOR_PROJECT}-robot}"
HARBOR_ROBOT_NAMESPACE="${HARBOR_ROBOT_NAMESPACE:-harbor}"
HARBOR_ROBOT_USER="${HARBOR_ROBOT_USER:-robot\$${HARBOR_PROJECT}+push}"
BUILDER="${BUILDER:-default}"
# Override only to test the Dockerfile on a box without arm64 emulation
# (e.g. PLATFORM=linux/amd64 build.sh smoke ci-build). `push` refuses non-arm64.
PLATFORM="${PLATFORM:-linux/arm64}"

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

MODE="${1:-}"; IMAGE="${2:-}"; VERSION="${3:-}"
case "$MODE" in build|push|smoke) ;; -h|--help|"") usage 0 ;; *) usage 1 ;; esac
[ -n "$IMAGE" ] || die "missing <image>"
CTX="$SCRIPT_DIR/$IMAGE"
[ -f "$CTX/Dockerfile" ] || die "no Dockerfile in $CTX"
if [ -z "$VERSION" ]; then
  [ -f "$CTX/VERSION" ] || die "no version given and no $CTX/VERSION"
  VERSION="$(tr -d '[:space:]' < "$CTX/VERSION")"
fi
[[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || die "bad version '$VERSION'"
REF="$HARBOR_REGISTRY/$HARBOR_PROJECT/$IMAGE:$VERSION"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

build() {
  # Pre-pull the base through the docker daemon: the daemon trusts the lab CA
  # (system store), BuildKit's own resolver may not ("x509: certificate signed
  # by unknown authority"); with the docker driver it then reuses the local copy.
  local base
  base="$(sed -n 's/^ARG BASE=//p' "$CTX/Dockerfile" | head -1)"
  if [ -n "$base" ]; then
    log "== pull base $base ($PLATFORM)"
    docker pull -q --platform "$PLATFORM" "$base" >/dev/null
  fi
  log "== build $REF ($PLATFORM, builder $BUILDER)"
  docker buildx build --builder "$BUILDER" \
    --platform "$PLATFORM" --provenance=false \
    --build-arg "VERSION=$VERSION" \
    --tag "$REF" --load "$CTX"
  local arch
  arch="$(docker image inspect "$REF" --format '{{.Architecture}}')"
  [ "$arch" = "${PLATFORM#linux/}" ] || die "built image is $arch, expected ${PLATFORM#linux/}"
  log "== built $REF ($arch)"
}

push() {
  local cfg="$TMP/docker"
  mkdir -p "$cfg"
  if [ -z "${HARBOR_USERNAME:-}" ] && [ -z "${HARBOR_PASSWORD:-}" ]; then
    command -v kubectl >/dev/null || die "set HARBOR_USERNAME/HARBOR_PASSWORD or provide kubectl"
    local b64
    b64="$(kubectl -n "$HARBOR_ROBOT_NAMESPACE" get secret "$HARBOR_ROBOT_SECRET" -o jsonpath='{.data.secret}')" \
      || die "cannot read secret $HARBOR_ROBOT_NAMESPACE/$HARBOR_ROBOT_SECRET"
    [ -n "$b64" ] || die "secret $HARBOR_ROBOT_NAMESPACE/$HARBOR_ROBOT_SECRET has no key 'secret'"
    HARBOR_PASSWORD="$(printf '%s' "$b64" | base64 -d)"
    HARBOR_USERNAME="$HARBOR_ROBOT_USER"
    log "credentials: $HARBOR_USERNAME from secret $HARBOR_ROBOT_NAMESPACE/$HARBOR_ROBOT_SECRET"
  fi
  [ -n "${HARBOR_PASSWORD:-}" ] || die "HARBOR_USERNAME set but HARBOR_PASSWORD empty"
  printf '%s' "$HARBOR_PASSWORD" | docker --config "$cfg" login "$HARBOR_REGISTRY" \
    --username "$HARBOR_USERNAME" --password-stdin >/dev/null
  log "== push $REF"
  docker --config "$cfg" push -q "$REF" >/dev/null
  local digest
  digest="$(docker image inspect "$REF" --format '{{range .RepoDigests}}{{println .}}{{end}}' \
            | grep "^$HARBOR_REGISTRY/$HARBOR_PROJECT/$IMAGE@" | head -1 | cut -d@ -f2)"
  [ -n "$digest" ] || die "pushed, but no repo digest found for $REF"
  log "== pushed; pin this in workflows:"
  printf '%s@%s\n' "$REF" "$digest"
}

smoke() {
  log "== smoke $REF"
  docker run --rm --platform "$PLATFORM" "$REF" sh -ec '
    echo "uid=$(id -u) gid=$(id -g)"; [ "$(id -u)" = 1001 ] && [ "$(id -g)" = 123 ]
    git --version; curl --version | head -1; jq --version
    ldd --version | head -1'
  if [ -n "${EXTERNALS_DIR:-}" ]; then
    # The runner's externals (copied out of the actions-runner image for the
    # same arch) mounted like the hook does, at /__e.
    local n
    for n in node20 node24; do
      [ -x "$EXTERNALS_DIR/$n/bin/node" ] || continue
      docker run --rm --platform "$PLATFORM" -v "$EXTERNALS_DIR:/__e:ro" "$REF" \
        /__e/$n/bin/node -e 'console.log(process.argv0, process.version, process.arch)'
    done
  fi
  log "== smoke OK"
}

if [ "$MODE" = push ] && [ "$PLATFORM" != linux/arm64 ]; then
  die "push builds linux/arm64 only (PLATFORM=$PLATFORM)"
fi
if [ "${PLATFORM#linux/}" != "$(uname -m | sed 's/aarch64/arm64/; s/x86_64/amd64/')" ] \
   && ! grep -qs . /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
  log "NOTE: building $PLATFORM on $(uname -m) needs QEMU binfmt; if RUN steps fail with"
  log "      'exec format error', register it once per boot (privileged, local only):"
  log "      docker run --privileged --rm tonistiigi/binfmt --install arm64"
fi
build
case "$MODE" in
  push)  push ;;
  smoke) smoke ;;
esac
