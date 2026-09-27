#!/usr/bin/env bash
# bootstrap.sh — installs git if missing, clones pve-micro-nodes into /opt and installs pmn.
# Self-contained: it does not load lib/common.sh, because it runs before the clone exists.
#
#   bash bootstrap.sh [--repo <url>] [--ref <tag|branch>]
#
# Repository: --repo, otherwise PMN_REPO_URL, otherwise the public repository.
set -euo pipefail

PMN_PUBLIC_REPO="https://github.com/iride-ch-SA/pve-micro-nodes.git"
PMN_DIR="/opt/pve-micro-nodes"
PMN_LINK="/usr/local/sbin/pmn"

repo="${PMN_REPO_URL:-}"
ref=""

log() { printf '%s\n' "$*"; logger -t pmn -- "bootstrap: $*" 2>/dev/null || true; }
die() { printf 'ERROR: %s\n' "$2" >&2; logger -t pmn -- "bootstrap: ERROR: $2" 2>/dev/null || true; exit "$1"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) repo=${2:-}; shift 2 ;;
        --repo=*) repo=${1#--repo=}; shift ;;
        --ref) ref=${2:-}; shift 2 ;;
        --ref=*) ref=${1#--ref=}; shift ;;
        -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die 2 "unknown option: $1" ;;
    esac
done
explicit_repo=${repo:+1}
: "${repo:=$PMN_PUBLIC_REPO}"

[ "$(id -u)" -eq 0 ] || die 2 "root required"
command -v pveversion >/dev/null 2>&1 || die 2 "pveversion not found: not a Proxmox VE node"

# git: only if missing. apt-get update may fail because of the pve-enterprise repository without
# a subscription (401) even when the Debian repositories answer: the error is tolerated, what counts
# is the result of apt-get install. The repository configuration is left untouched.
if ! command -v git >/dev/null 2>&1; then
    log "git not found: installing"
    apt-get update || log "apt-get update ended with an error (expected without a subscription): continuing"
    DEBIAN_FRONTEND=noninteractive apt-get install -y git || die 1 "git installation failed"
fi

same_repo() {
    local origin
    origin=$(git -C "$PMN_DIR" remote get-url origin 2>/dev/null) || return 1
    if [ -n "$explicit_repo" ]; then
        [ "${origin%.git}" = "${repo%.git}" ]
    else
        case "${origin%.git}" in */pve-micro-nodes) return 0 ;; *) return 1 ;; esac
    fi
}

link_pmn() {
    if [ "$(readlink "$PMN_LINK" 2>/dev/null)" != "$PMN_DIR/pmn" ]; then
        ln -sfn "$PMN_DIR/pmn" "$PMN_LINK"
        log "symlink $PMN_LINK -> $PMN_DIR/pmn"
    fi
}

if [ -e "$PMN_DIR" ]; then
    if [ -d "$PMN_DIR/.git" ] && same_repo; then
        link_pmn
        log "$PMN_DIR is already a clone of $(git -C "$PMN_DIR" remote get-url origin): no new clone"
        log "to update it: pmn update"
        exit 0
    fi
    die 2 "$PMN_DIR exists and is not a clone of $repo: remove it or pass --repo"
fi

log "cloning $repo into $PMN_DIR"
git clone --quiet "$repo" "$PMN_DIR" || die 1 "clone of $repo failed"

if [ -z "$ref" ]; then
    ref=$(git -C "$PMN_DIR" tag -l 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n1)
fi
if [ -n "$ref" ]; then
    if git -C "$PMN_DIR" rev-parse -q --verify "refs/remotes/origin/$ref^{commit}" >/dev/null; then
        git -C "$PMN_DIR" checkout --quiet --detach "origin/$ref"
    else
        git -C "$PMN_DIR" checkout --quiet --detach "refs/tags/$ref" || die 1 "unknown ref: $ref"
    fi
    log "clone checked out at $ref"
else
    log "no vX.Y.Z tag: the clone stays on the default branch"
fi

link_pmn
log "ready: pmn list"
