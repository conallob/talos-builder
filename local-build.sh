#!/usr/bin/env bash
# local-build.sh
#
# Runs the full talos-builder pipeline locally using Podman as the Docker backend.
# Run local-build-setup.sh once first.
#
# Usage:
#   ./local-build.sh                          # full build, push to ghcr.io/conallob
#   ./local-build.sh checkouts patches        # only clone & patch (useful for debugging patches)
#   ./local-build.sh patches                  # re-apply patches to existing checkouts
#
# Environment overrides:
#   REGISTRY_USERNAME=myuser ./local-build.sh   # push to a different namespace
#   SKIP_PUSH=1 ./local-build.sh                # build without pushing (cache only)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PODMAN_SOCK="$HOME/.local/share/containers/podman/machine/podman.sock"

# --- Prerequisites check ---
for cmd in docker crane git make; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' not found. Run ./local-build-setup.sh first."
    exit 1
  fi
done

if [[ ! -S "$PODMAN_SOCK" ]]; then
  echo "ERROR: Podman socket not found at $PODMAN_SOCK"
  echo "       Make sure Podman Desktop is running."
  exit 1
fi

export DOCKER_HOST="unix://$PODMAN_SOCK"

# Verify connection
if ! docker info &>/dev/null; then
  echo "ERROR: Cannot connect to Podman via Docker socket."
  echo "       Run ./local-build-setup.sh to configure the BuildKit builder."
  exit 1
fi

# Ensure our builder is active
if ! docker buildx inspect talos-builder &>/dev/null; then
  echo "ERROR: BuildKit builder 'talos-builder' not found."
  echo "       Run ./local-build-setup.sh to create it."
  exit 1
fi
docker buildx use talos-builder

# --- Config ---
export REGISTRY="${REGISTRY:-ghcr.io}"
export REGISTRY_USERNAME="${REGISTRY_USERNAME:-conallob}"
PUSH_ARG="PUSH=true"
if [[ "${SKIP_PUSH:-0}" == "1" ]]; then
  PUSH_ARG="PUSH=false"
  echo "Note: SKIP_PUSH=1 — images will be built but not pushed to registry."
fi

cd "$REPO_ROOT"

# Determine which targets to run
if [[ $# -gt 0 ]]; then
  TARGETS=("$@")
else
  TARGETS=(checkouts patches kernel overlay installer)
fi

echo "==> Running targets: ${TARGETS[*]}"
echo "    Registry: $REGISTRY/$REGISTRY_USERNAME"
echo ""

for target in "${TARGETS[@]}"; do
  echo "==> make $target"
  make \
    REGISTRY="$REGISTRY" \
    REGISTRY_USERNAME="$REGISTRY_USERNAME" \
    "$PUSH_ARG" \
    "$target"
  echo ""
done

echo "==> Build complete."
