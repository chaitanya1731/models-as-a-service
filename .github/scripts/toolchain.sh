#!/usr/bin/env bash
# Toolchain coupling helpers for the Go modules in this repository.
#
# The Go toolchain is pinned in three coupled places:
#   - the `go` directive in each module's go.mod
#   - `ARG GOLANG_VERSION=<major.minor>` in each module's Dockerfile (the
#     ubi9/go-toolset builder tag)
#   - `GOLANGCI_LINT_VERSION` in each module's tools.mk
#
# The Konflux image builds run on Red Hat's UBI go-toolset images, which are
# published weeks after the corresponding upstream Go releases. A go.mod
# directive newer than the available UBI builder cannot be built at all.
#
# Subcommands:
#   check              Verify every module's go directive is buildable:
#                        1. all modules share one go directive (no drift)
#                        2. the Dockerfile GOLANG_VERSION matches the directive
#                        3. the UBI go-toolset image the Dockerfiles build from
#                           provides a Go version >= the go directive
#   latest             Print the newest Go version published in UBI, starting
#                      from the current directive's minor line. Prints nothing
#                      when the current directive is already the newest.
#   bump <version>     Update all go.mod directives, Dockerfile
#                      GOLANG_VERSIONs and golangci-lint pins to <version>
#                      (e.g. 1.27.0). Run `go mod tidy` per module.
#
# Usage:
#   .github/scripts/toolchain.sh check
#   .github/scripts/toolchain.sh latest
#   .github/scripts/toolchain.sh bump 1.27.0 [GOLANGCI_VERSION]
#
# The registry lookups use anonymous requests against
# registry.access.redhat.com; no credentials are required. The floating minor
# tags (e.g. go-toolset:1.26) are resolved to the exact Go version they
# currently provide via the image config labels (io.k8s.display-name).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGISTRY="registry.access.redhat.com"
TOOLSET_REPO="ubi9/go-toolset"
MANIFEST_ACCEPT='application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json'
# Modules with a Dockerfile (i.e. built as images). maas-common is a library.
IMAGE_MODULES=("maas-api" "maas-controller" "maas-discovery")
ALL_MODULES=("maas-api" "maas-common" "maas-controller" "maas-discovery")

log() { echo "[toolchain] $*"; }
fail() { echo "::error::$*" >&2; exit 1; }

# Print the go directive (X.Y.Z) of a module's go.mod.
go_directive() {
    local directive
    directive="$(sed -n 's/^go \(1\.[0-9]*\.[0-9]*\)$/\1/p' "$1/go.mod" | head -1)"
    [ -n "$directive" ] || fail "no go directive found in $1/go.mod"
    echo "$directive"
}

# Print the major.minor prefix of a X.Y.Z version.
minor_of() { echo "$1" | cut -d. -f1-2; }

# Exit 0 if the UBI registry publishes a go-toolset manifest for the tag.
ubi_tag_exists() {
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Accept: ${MANIFEST_ACCEPT}" \
        "https://${REGISTRY}/v2/${TOOLSET_REPO}/manifests/$1")"
    [ "$code" = "200" ]
}

# Print the exact Go version (X.Y.Z) a go-toolset tag currently resolves to,
# read from the image config's io.k8s.display-name label.
ubi_go_version() {
    local tag="$1" amd64_digest config_digest
    amd64_digest="$(curl -sfL -H "Accept: ${MANIFEST_ACCEPT}" \
        "https://${REGISTRY}/v2/${TOOLSET_REPO}/manifests/${tag}" \
        | jq -r 'if .manifests then (.manifests[] | select(.platform.architecture=="amd64" and .platform.os=="linux") | .digest) else .config.digest end' \
        | head -1)"
    [ -n "$amd64_digest" ] && [ "$amd64_digest" != "null" ] \
        || fail "could not resolve a manifest for ${TOOLSET_REPO}:${tag}"
    config_digest="$(curl -sfL -H "Accept: ${MANIFEST_ACCEPT}" \
        "https://${REGISTRY}/v2/${TOOLSET_REPO}/manifests/${amd64_digest}" \
        | jq -r '.config.digest // empty')"
    [ -n "$config_digest" ] || fail "could not resolve the image config for ${TOOLSET_REPO}:${tag}"
    curl -sfL "https://${REGISTRY}/v2/${TOOLSET_REPO}/blobs/${config_digest}" \
        | jq -r '.config.Labels["io.k8s.display-name"]' \
        | sed -n 's/^Go \(1\.[0-9]*\.[0-9]*\)$/\1/p' \
        || fail "could not read the Go version label of ${TOOLSET_REPO}:${tag}"
}

# Exit 0 if version $1 >= version $2 (X.Y.Z semver-ish comparison).
version_ge() {
    local a="$1" b="$2" i
    local -a av bv
    IFS='.' read -ra av <<<"$a"
    IFS='.' read -ra bv <<<"$b"
    for i in 0 1 2; do
        (( ${av[i]:-0} > ${bv[i]:-0} )) && return 0
        (( ${av[i]:-0} < ${bv[i]:-0} )) && return 1
    done
    return 0
}

cmd_check() {
    local reference="" module directive dockerfile_minor ubi_version

    for module in "${ALL_MODULES[@]}"; do
        directive="$(go_directive "${REPO_ROOT}/${module}")"
        if [ -z "$reference" ]; then
            reference="$directive"
            log "reference go directive: ${module} ${directive}"
        elif [ "$directive" != "$reference" ]; then
            fail "go directive drift: ${module} is on ${directive} but ${ALL_MODULES[0]} is on ${reference}. Run .github/scripts/toolchain.sh bump ${reference} to align all modules."
        fi
    done

    for module in "${IMAGE_MODULES[@]}"; do
        dockerfile_minor="$(sed -n 's/^ARG GOLANG_VERSION=\(1\.[0-9]*\)$/\1/p' \
            "${REPO_ROOT}/${module}/Dockerfile" | head -1)"
        [ -n "$dockerfile_minor" ] || fail "no ARG GOLANG_VERSION found in ${module}/Dockerfile"
        if [ "$dockerfile_minor" != "$(minor_of "$reference")" ]; then
            fail "${module}/Dockerfile builds with go-toolset:${dockerfile_minor} but ${module}/go.mod targets go $(minor_of "$reference"). Bump ARG GOLANG_VERSION to $(minor_of "$reference")."
        fi
    done

    ubi_tag_exists "$(minor_of "$reference")" \
        || fail "go.mod targets go ${reference} but the UBI registry has no ${TOOLSET_REPO}:$(minor_of "$reference") tag yet. Red Hat publishes go-toolset images weeks after upstream Go releases. Hold this bump until the coupled toolchain PR from the update-toolchain workflow lands."
    ubi_version="$(ubi_go_version "$(minor_of "$reference")")"
    log "UBI go-toolset:$(minor_of "$reference") currently provides Go ${ubi_version}"
    version_ge "$ubi_version" "$reference" \
        || fail "go.mod targets go ${reference} but the UBI builder go-toolset:$(minor_of "$reference") only provides Go ${ubi_version}. Red Hat publishes go-toolset images weeks after upstream Go releases. Hold this bump until the coupled toolchain PR from the update-toolchain workflow lands."

    log "OK: all modules on go ${reference}, Dockerfiles match, UBI builder provides Go ${ubi_version}."
}

# Print the newest go version published as a UBI go-toolset tag, starting the
# search from the current go directive's minor line. Prints nothing when the
# current directive is already the newest.
cmd_latest() {
    local current major minor next_minor ubi_version
    current="$(go_directive "${REPO_ROOT}/${ALL_MODULES[0]}")"
    major="${current%%.*}"
    minor="$(minor_of "$current" | cut -d. -f2)"

    if ubi_tag_exists "$((major + 1)).0"; then
        fail "a new Go major line ($((major + 1)).0) is published in UBI; this script needs updating for major-version bumps."
    fi

    # Newer minor line available?
    next_minor="$((minor + 1))"
    if ubi_tag_exists "${major}.${next_minor}"; then
        ubi_go_version "${major}.${next_minor}"
        return
    fi

    # Newer patch on the current minor line?
    ubi_version="$(ubi_go_version "${major}.${minor}")"
    version_ge "$ubi_version" "$current" && [ "$ubi_version" != "$current" ] \
        && echo "$ubi_version"
    return 0
}

cmd_bump() {
    local target="${1:-}" golangci_version="${2:-${GOLANGCI_VERSION:-}}" module

    [ -n "$target" ] || fail "usage: toolchain.sh bump <version> [golangci-version]"
    [[ "$target" =~ ^1\.[0-9]+\.[0-9]+$ ]] || fail "invalid go version: ${target}"

    if [ -z "$golangci_version" ]; then
        golangci_version="$(curl -sf "https://api.github.com/repos/golangci/golangci-lint/releases/latest" \
            | jq -r '.tag_name' | head -1)" || golangci_version=""
        [ -n "$golangci_version" ] && [ "$golangci_version" != "null" ] \
            || fail "could not resolve the latest golangci-lint release; pass it explicitly: toolchain.sh bump ${target} v2.x.y"
    fi
    log "bumping go directives to ${target}, Dockerfiles to $(minor_of "$target"), golangci-lint to ${golangci_version}"

    for module in "${ALL_MODULES[@]}"; do
        sed -i "s/^go 1\.[0-9]*\.[0-9]*$/go ${target}/" "${REPO_ROOT}/${module}/go.mod"
    done
    for module in "${IMAGE_MODULES[@]}"; do
        sed -i "s/^ARG GOLANG_VERSION=1\.[0-9]*$/ARG GOLANG_VERSION=$(minor_of "$target")/" \
            "${REPO_ROOT}/${module}/Dockerfile"
        sed -i "s/^GOLANGCI_LINT_VERSION ?= v[0-9.]*$/GOLANGCI_LINT_VERSION ?= ${golangci_version}/" \
            "${REPO_ROOT}/${module}/tools.mk"
    done

    command -v go >/dev/null || fail "go is required for 'go mod tidy'"
    for module in "${ALL_MODULES[@]}"; do
        (cd "${REPO_ROOT}/${module}" && go mod tidy)
    done

    log "done. Review the diff and open one PR with all modules."
}

case "${1:-}" in
    check) cmd_check ;;
    latest) cmd_latest ;;
    bump) shift; cmd_bump "$@" ;;
    *) fail "usage: toolchain.sh {check|latest|bump <version> [golangci-version]}" ;;
esac
