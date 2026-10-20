#!/usr/bin/env bash
# `make publish`: publish the tarball in dist/ to npm -- the exact file that
# was SBOM'd -- by one of two paths.
#
# Reads: NPM_PUBLISH (empty = skip), NPM_TOKEN (empty = absent).
#   - NPM_TOKEN set (bootstrap: the first release, before the package has a
#     trusted publisher): `npm stage publish`. The token is stage-only, so
#     this uploads the tarball to a staging area; nothing is public until a
#     maintainer approves the printed stage id with 2FA.
#   - NPM_TOKEN empty: `npm publish --provenance` through OIDC trusted
#     publishing (the job's `id-token: write`), no stored credential.
# `npm_config_dry_run=true` makes either path a dry run.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/release-lib.sh
source scripts/release-lib.sh

# npm's OIDC trusted publishing breaks if this is set, even empty.
unset NODE_AUTH_TOKEN

if [[ -z ${NPM_PUBLISH:-} ]]; then
    echo "NPM_PUBLISH not set -- skipping publish."
    exit 0
fi

tarball=$(find_tarball)
version=$(tarball_field "$tarball" version)
# npm refuses a prerelease without an explicit tag, and must not move `latest`.
tag=latest
if [[ $version == *-* ]]; then
    prerelease=${version#*-}
    tag=${prerelease%%.*}
fi

if [[ -n ${NPM_TOKEN:-} ]]; then
    echo "NPM_TOKEN set -- staging $(basename "$tarball") with the bootstrap token."
    npmrc=$(mktemp)
    trap 'rm -f "$npmrc"' EXIT
    chmod 600 "$npmrc"
    printf '//registry.npmjs.org/:_authToken=%s\n' "$NPM_TOKEN" >"$npmrc"
    # --userconfig replaces the user npmrc, so the token reaches npm through a
    # file, never the command line or the environment.
    args=(--userconfig "$npmrc" --access public --tag "$tag")
    if [[ -n ${ACTIONS_ID_TOKEN_REQUEST_URL:-} ]]; then
        args+=(--provenance)
    fi
    npm stage publish "$tarball" "${args[@]}"
    echo "Staged, NOT yet public. A maintainer must approve it with 2FA:"
    echo "  npm stage list && npm stage approve <stage-id>   (or on npmjs.com)"
else
    echo "NPM_TOKEN empty -- publishing $(basename "$tarball") with OIDC trusted publishing."
    npm publish "$tarball" --provenance --access public --tag "$tag"
fi
