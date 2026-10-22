# Shared by scripts/release-*.sh (sourced, not run): the pinned npm and the
# package facts every release step needs.

# Staged publishing needs npm >= 11.15.0 and OIDC trusted publishing >=
# 11.5.1; the Node in .devcontainer/Dockerfile may ship an older npm, so every
# step runs this exact one (see use_npm).
# renovate: datasource=npm depName=npm
NPM_VERSION=11.19.1

# renovate: datasource=docker depName=anchore/syft
SYFT_VERSION=v1.52.0

export npm_config_update_notifier=false
# Corepack's implicit shims prompt before downloading pnpm; there is no one
# to answer in a script (https://github.com/nodejs/corepack#environment-variables).
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

# Commands to run on exit, so sourcing scripts can add their own without
# replacing each other's trap.
_exit_cmds=()
on_exit() { _exit_cmds+=("$1"); }
_run_exit_cmds() {
    local cmd
    for cmd in "${_exit_cmds[@]}"; do eval "$cmd"; done
}
trap _run_exit_cmds EXIT

# Resolves the pinned npm once per script run: the host's own npm if it is
# already that version (the devcontainer's Node bundles it), else the pinned
# one installed into a temp prefix. Call before the first `npm`.
use_npm() {
    NPM_BIN=$(type -P npm)
    if [[ $("$NPM_BIN" --version) != "$NPM_VERSION" ]]; then
        local prefix
        prefix=$(mktemp -d)
        on_exit "rm -rf '$prefix'"
        "$NPM_BIN" install --prefix "$prefix" --no-audit --no-fund --silent "npm@$NPM_VERSION"
        NPM_BIN=$prefix/node_modules/.bin/npm
    fi
}
npm() { "$NPM_BIN" "$@"; }

# The packed tarball in dist/ (exactly one).
find_tarball() {
    local tarballs
    shopt -s nullglob
    tarballs=(dist/*.tgz)
    shopt -u nullglob
    if [[ ${#tarballs[@]} -ne 1 ]]; then
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

# <name> <version> -> the dist-tag to publish under.
#  - A prerelease gets its first identifier (`1.0.0-rc.1` -> `rc`); a numeric
#    one (`1.0.0-0`) is not a valid tag, so it gets `next`. Build metadata
#    (`+build.5`) is ignored.
#  - A stable release gets `latest` only if it is not older than the current
#    `latest` (no latest yet = first release); a backport (1.4.3 after 2.0.0)
#    gets `v<major>-latest` instead, so it cannot move `latest` backwards.
dist_tag() {
    local name=$1 version=${2%%+*} pre id current err
    if [[ $version == *-* ]]; then
        pre=${version#*-}
        id=${pre%%.*}
        if [[ -z $id || $id =~ ^[0-9]+$ ]]; then echo next; else echo "$id"; fi
        return
    fi
    err=$(mktemp)
    if ! current=$(npm view "$name" dist-tags.latest 2>"$err"); then
        if ! grep -q E404 "$err"; then
            cat "$err" >&2
            rm -f "$err"
            return 1
        fi
        current=
    fi
    rm -f "$err"
    # Only the core is compared: a prerelease `latest` (1.0.0-rc.1) is older
    # than the stable 1.0.0 it precedes.
    current=${current%%-*}
    if [[ -z $current || $(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -1) == "$version" ]]; then
        echo latest
    else
        echo "v${version%%.*}-latest"
    fi
}

# <url> -> the URL as GitHub knows the repository: `git+` prefix, `.git`
# suffix and trailing slashes stripped. Case is kept: npm compares it
# case-sensitively.
normalize_repo_url() {
    local url=$1
    url=${url#git+}
    while [[ $url == */ ]]; do url=${url%/}; done
    url=${url%.git}
    while [[ $url == */ ]]; do url=${url%/}; done
    printf '%s\n' "$url"
}

# <tarball> -> fails unless the packed package.json's `repository.url`
# (object or string form) is https://github.com/$GITHUB_REPOSITORY. npm's
# provenance verification rejects the upload otherwise (E422), and an
# instance created from the template inherits the template's own value until
# it edits package.json. Called by release-publish.sh only once publishing is
# on. Skipped with a notice when GITHUB_REPOSITORY is
# unset, i.e. outside GitHub Actions.
check_repository() {
    if [[ -z ${GITHUB_REPOSITORY:-} ]]; then
        echo "NOTICE: GITHUB_REPOSITORY not set -- skipping the package.json repository.url check."
        return 0
    fi
    local url want="https://github.com/$GITHUB_REPOSITORY"
    url=$(tar -xzOf "$1" package/package.json | node -e '
        const r = JSON.parse(require("fs").readFileSync(0, "utf8")).repository;
        process.stdout.write(String((r && typeof r === "object" ? r.url : r) ?? ""));')
    if [[ $(normalize_repo_url "$url") != "$want" ]]; then
        echo "package.json repository.url is \"$url\", expected $want." >&2
        echo "npm rejects provenance when they differ (E422). Set repository, homepage and bugs in package.json to this repository:" >&2
        echo "  \"repository\": {\"type\": \"git\", \"url\": \"git+$want.git\"}" >&2
        return 1
    fi
    echo "OK: package.json repository.url matches $want."
}
