#!/usr/bin/env bash
# local-build-setup.sh
#
# One-time setup to enable local builds using Podman as the Docker backend.
# Run this once before your first local build. Safe to re-run.
#
# Requirements:
#   - Podman Desktop installed with the default machine running
#   - Homebrew

set -euo pipefail

PODMAN_SOCK="$HOME/.local/share/containers/podman/machine/podman.sock"
BUILDER_NAME="talos-builder"

echo "==> Checking Podman machine is running..."
if ! podman machine inspect podman-machine-default &>/dev/null; then
  echo "ERROR: Podman machine not found. Start Podman Desktop first."
  exit 1
fi
STATUS=$(podman machine inspect podman-machine-default | python3 -c "import sys,json; m=json.load(sys.stdin)[0]; print(m.get('State','unknown'))")
if [[ "$STATUS" != "running" ]]; then
  echo "ERROR: Podman machine is not running (state: $STATUS). Start it from Podman Desktop."
  exit 1
fi
echo "    Podman machine is running."

echo "==> Installing dependencies (docker, buildx, crane, GNU make)..."
brew install docker docker-buildx crane make 2>/dev/null || brew upgrade docker docker-buildx crane make 2>/dev/null || true
mkdir -p "$HOME/.docker/cli-plugins"
# Link docker-buildx as a docker CLI plugin
BUILDX_BIN="$(brew --prefix)/bin/docker-buildx"
if [[ -f "$BUILDX_BIN" ]]; then
  ln -sf "$BUILDX_BIN" "$HOME/.docker/cli-plugins/docker-buildx"
fi


echo "==> Configuring DOCKER_HOST to use Podman socket..."
if [[ ! -S "$PODMAN_SOCK" ]]; then
  echo "ERROR: Podman socket not found at $PODMAN_SOCK"
  echo "       Make sure the Podman machine is running."
  exit 1
fi

export DOCKER_HOST="unix://$PODMAN_SOCK"

echo "==> Testing Docker→Podman connection..."
docker version --format 'Server: {{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null || {
  echo "ERROR: Could not connect to Podman via Docker socket."
  exit 1
}

echo "==> Setting up BuildKit builder '$BUILDER_NAME'..."
# Remove stale builder if it exists
docker buildx rm "$BUILDER_NAME" 2>/dev/null || true
# Create a new docker-container driver builder backed by Podman
docker buildx create \
  --name "$BUILDER_NAME" \
  --driver docker-container \
  --driver-opt network=host \
  --buildkitd-flags '--allow-insecure-entitlement security.insecure' \
  --use
docker buildx inspect --bootstrap "$BUILDER_NAME"

echo ""
echo "==> Setup complete!"
echo ""
echo "    Add the following to your shell profile (~/.zshrc or ~/.zprofile)"
echo "    so builds work in new terminals:"
echo ""
echo "    export DOCKER_HOST=\"unix://$PODMAN_SOCK\""
echo ""
echo "    Then run a build with:"
echo ""
echo "    ./local-build.sh"
