#!/usr/bin/env bash
#
# build.sh — source-agnostic builder for the six Kubernetes core components.
#
# It does not care whether the source tree came from the upstream repo
# (vanilla rebuild) or from the Mirantis LTS fork (patched build). The caller
# checks out the right tree into --source-dir and tells us where to publish.
#
# Image components : go build -> inline Dockerfile -> docker build/push.
# Deb components   : go build -> inline nfpm config -> nfpm package.
#
# Flags:
#   --component <name>        component name == ./cmd/<name> in the source tree
#   --kind image|deb          artifact kind
#   --tag <vX.Y.Z[-lts.N]>    image tag / deb version (deb strips leading 'v')
#   --registry-path <path>    full ghcr path (image only), e.g.
#                             ghcr.io/oleksandr-minakov/lts-k8s/kube-apiserver
#   --base-image <image>      runtime base image (image only)
#   --source-dir <dir>        checked-out source tree (default: src)
#
# Env (optional):
#   GITHUB_RUN_ID     used for the immutable :candidate-<run_id> tag
#   IMAGE_SOURCE_URL  sets org.opencontainers.image.source so ghcr auto-links
#                     the package to the build repo (grants scan token read).
#
set -euo pipefail

COMPONENT="" KIND="" TAG="" REGISTRY_PATH="" BASE_IMAGE="" SOURCE_DIR="src"

while [ $# -gt 0 ]; do
  case "$1" in
    --component)     COMPONENT="$2"; shift 2 ;;
    --kind)          KIND="$2"; shift 2 ;;
    --tag)           TAG="$2"; shift 2 ;;
    --registry-path) REGISTRY_PATH="$2"; shift 2 ;;
    --base-image)    BASE_IMAGE="$2"; shift 2 ;;
    --source-dir)    SOURCE_DIR="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

[ -n "$COMPONENT" ] || { echo "missing --component" >&2; exit 1; }
[ -n "$KIND" ]      || { echo "missing --kind" >&2; exit 1; }
[ -n "$TAG" ]       || { echo "missing --tag" >&2; exit 1; }
[ -d "$SOURCE_DIR/cmd/$COMPONENT" ] || {
  echo "source tree missing cmd/$COMPONENT under $SOURCE_DIR" >&2; exit 1; }

RUN_ID="${GITHUB_RUN_ID:-local}"
SOURCE_URL="${IMAGE_SOURCE_URL:-}"
OS="linux" ARCH="amd64"

echo "==> build.sh component=$COMPONENT kind=$KIND tag=$TAG source-dir=$SOURCE_DIR"

# Build the static binary. GOFLAGS (=-mod=vendor -trimpath -buildvcs=false),
# GOPROXY=off, GOSUMDB=off, GOTOOLCHAIN=local are supplied by the workflow env.
build_binary() {
  local out="$1"
  echo "==> go build ./cmd/$COMPONENT -> $out"
  ( cd "$SOURCE_DIR" \
      && GOOS="$OS" GOARCH="$ARCH" CGO_ENABLED=0 \
         go build -o "$out" "./cmd/$COMPONENT" )
}

case "$KIND" in
  image)
    [ -n "$REGISTRY_PATH" ] || { echo "missing --registry-path" >&2; exit 1; }
    [ -n "$BASE_IMAGE" ]    || { echo "missing --base-image" >&2; exit 1; }
    ctx="$(mktemp -d)"; trap 'rm -rf "$ctx"' EXIT
    build_binary "$ctx/$COMPONENT"
    {
      echo "FROM $BASE_IMAGE"
      [ -n "$SOURCE_URL" ] && echo "LABEL org.opencontainers.image.source=$SOURCE_URL"
      echo "LABEL org.opencontainers.image.title=$COMPONENT"
      echo "LABEL org.opencontainers.image.version=$TAG"
      echo "COPY $COMPONENT /usr/local/bin/$COMPONENT"
      echo "ENTRYPOINT [\"/usr/local/bin/$COMPONENT\"]"
    } > "$ctx/Dockerfile"
    echo "==> docker build $REGISTRY_PATH:$TAG (+ :candidate-$RUN_ID)"
    docker build -t "$REGISTRY_PATH:$TAG" -t "$REGISTRY_PATH:candidate-$RUN_ID" "$ctx"
    docker push "$REGISTRY_PATH:$TAG"
    docker push "$REGISTRY_PATH:candidate-$RUN_ID"
    ;;

  deb)
    bindir="$(mktemp -d)"; trap 'rm -rf "$bindir"' EXIT
    build_binary "$bindir/$COMPONENT"
    if ! command -v nfpm >/dev/null 2>&1; then
      echo "==> installing nfpm via goreleaser apt repo"
      echo 'deb [trusted=yes] https://repo.goreleaser.com/apt/ /' \
        | sudo tee /etc/apt/sources.list.d/goreleaser.list >/dev/null
      sudo apt-get update -qq
      sudo apt-get install -y nfpm
    fi
    debver="${TAG#v}"
    cfg="$(mktemp)"
    cat > "$cfg" <<EOF
name: "$COMPONENT"
arch: "$ARCH"
platform: "linux"
version: "$debver"
section: "admin"
priority: "optional"
maintainer: "Mirantis LTS <lts@mirantis.example>"
vendor: "Mirantis"
license: "Apache-2.0"
description: "Kubernetes $COMPONENT ($TAG) — Mirantis LTS / vanilla rebuild."
contents:
  - src: "$bindir/$COMPONENT"
    dst: "/usr/bin/$COMPONENT"
EOF
    mkdir -p dist
    echo "==> nfpm package -> dist/"
    nfpm package -f "$cfg" -p deb -t dist/
    ls -l dist/
    ;;

  *) echo "unknown --kind: $KIND" >&2; exit 1 ;;
esac

echo "==> build.sh done"
