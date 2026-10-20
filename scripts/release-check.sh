#!/usr/bin/env bash
# `make release-check`: install the built tarball into a scratch project and
# import every `exports` entry; when publishing is on, do the same with the
# published release from the registry.
#
# Reads: NPM_PUBLISH (empty = skip the registry check), and
# RELEASE_CHECK_ATTEMPTS / RELEASE_CHECK_DELAY (retry tuning for registry
# propagation, defaults 3 and 5 seconds, doubling).
#
# A first release is staged, so it is not installable until a maintainer
# approves it: a version that is not on the registry yet is a notice, not a
# failure.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/release-lib.sh
source scripts/release-lib.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

tarball=$(find_tarball)
name=$(tarball_field "$tarball" name)
version=$(tarball_field "$tarball" version)

# <dir> <expected version>: import `name` and every exports subpath (ESM,
# Node) from the package installed in <dir>.
check_import() {
    (cd "$1" && node --input-type=module -e '
        import { readFileSync } from "node:fs";
        const [name, want] = process.argv.slice(1);
        const pkg = JSON.parse(readFileSync(`node_modules/${name}/package.json`, "utf8"));
        if (pkg.version !== want) throw new Error(`installed ${name} ${pkg.version}, expected ${want}`);
        for (const key of Object.keys(pkg.exports)) {
            if (key.endsWith(".json")) continue;
            const spec = name + key.slice(1);
            const mod = await import(spec);
            console.log(`OK: import ${spec} (${Object.keys(mod).length} exports)`);
        }
    ' "$name" "$2")
}

install_into() { # <dir> <package spec>
    echo '{"private":true,"type":"module"}' >"$1/package.json"
    (cd "$1" && npm install --no-audit --no-fund --silent "$2")
}

echo "== local tarball: $(basename "$tarball")"
mkdir "$tmp/local"
install_into "$tmp/local" "$tarball"
check_import "$tmp/local" "$version"

if [[ -z ${NPM_PUBLISH:-} ]]; then
    echo "NPM_PUBLISH not set -- skipping the registry check."
    exit 0
fi

echo "== registry: $name@$version"
attempts=${RELEASE_CHECK_ATTEMPTS:-3}
delay=${RELEASE_CHECK_DELAY:-5}
for ((i = 1; i <= attempts; i++)); do
    if err=$(npm view "$name@$version" version 2>&1 >/dev/null); then
        mkdir "$tmp/published"
        install_into "$tmp/published" "$name@$version"
        check_import "$tmp/published" "$version"
        exit 0
    fi
    # Anything but "not found" (network, auth) is a real failure.
    if ! grep -q E404 <<<"$err"; then
        echo "$err" >&2
        exit 1
    fi
    if ((i < attempts)); then
        echo "attempt $i/$attempts: not found; retrying in ${delay}s (registry propagation)"
        sleep "$delay"
        delay=$((delay * 2))
    fi
done
echo "NOTICE: $name@$version is not yet on the registry (staged, awaiting approval?)."
echo "NOTICE: approve it with 'npm stage approve <stage-id>'; the tarball check above passed."
