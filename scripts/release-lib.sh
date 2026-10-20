# Shared by scripts/release-*.sh (sourced, not run): the pinned npm and the
# package facts every release step needs.

# Staged publishing needs npm >= 11.15.0 and OIDC trusted publishing >=
# 11.5.1; the Node in .devcontainer/Dockerfile may ship an older npm, so every
# step runs this exact one.
# renovate: datasource=npm depName=npm
NPM_VERSION=11.19.1

# renovate: datasource=docker depName=anchore/syft
SYFT_VERSION=v1.52.0

npm() { npm_config_update_notifier=false npx --yes "npm@$NPM_VERSION" "$@"; }

# The packed tarball in dist/ (exactly one).
find_tarball() {
    local tarballs=(dist/*.tgz)
    if [[ ${#tarballs[@]} -ne 1 || ! -f ${tarballs[0]} ]]; then
        echo "expected exactly one tarball in dist/, found ${#tarballs[@]}" >&2
        return 1
    fi
    realpath "${tarballs[0]}"
}

# <tarball> <field> -> that field of the packed package.json.
tarball_field() {
    tar -xzOf "$1" package/package.json | node -e \
        'process.stdout.write(String(JSON.parse(require("fs").readFileSync(0, "utf8"))[process.argv[1]]))' "$2"
}
