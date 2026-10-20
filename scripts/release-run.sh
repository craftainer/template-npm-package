#!/usr/bin/env bash
# Runs the given command on the host if it has pnpm, else in the pinned Node
# image (release.yml's bare runner has docker but no pnpm).
#
# The container sees the working tree at /src and the CI variables npm needs
# for OIDC trusted publishing and provenance. NODE_AUTH_TOKEN is deliberately
# never forwarded: its presence, even empty, breaks OIDC publishing.
set -euo pipefail

cd "$(dirname "$0")/.."

if command -v pnpm >/dev/null 2>&1; then
    exec "$@"
fi

# Same Node as the devcontainer; its Dockerfile is the single source.
node_version=$(sed -n 's/^ARG NODE_VERSION=//p' .devcontainer/Dockerfile)
env_args=()
for name in RELEASE_VERSION RELEASE_TAG RELEASE_ARCH NPM_PUBLISH NPM_TOKEN \
    $(env | grep -E '^(GITHUB_|RUNNER_|ACTIONS_)' | cut -d= -f1); do
    env_args+=(-e "$name")
done

exec docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/src" -w /src \
    -e HOME=/tmp/home -e COREPACK_HOME=/tmp/corepack "${env_args[@]}" \
    "node:${node_version}-trixie-slim" bash -c \
    'mkdir -p /tmp/bin /tmp/home && corepack enable --install-directory /tmp/bin && PATH=/tmp/bin:$PATH exec "$@"' -- "$@"
