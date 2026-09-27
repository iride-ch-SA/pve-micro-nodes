# lib/common.sh — functions shared by pmn and the tool scripts.
# Read with source: no set -e here, the loading script sets it.
# shellcheck shell=bash

PMN_LOG_TAG="pmn"
: "${PMN_DRY_RUN:=0}"
: "${PMN_YES:=0}"

# Root of system paths. Empty on the node; set only for sandbox tests.
: "${PMN_SYSROOT:=}"

log() {
    printf '%s\n' "$*"
    command -v logger >/dev/null 2>&1 && logger -t "$PMN_LOG_TAG" -- "$*" 2>/dev/null
    return 0
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
    command -v logger >/dev/null 2>&1 && logger -t "$PMN_LOG_TAG" -- "WARNING: $*" 2>/dev/null
    return 0
}

err() {
    printf 'ERROR: %s\n' "$*" >&2
    command -v logger >/dev/null 2>&1 && logger -t "$PMN_LOG_TAG" -- "ERROR: $*" 2>/dev/null
    return 0
}

require_root() {
    [ -n "$PMN_SYSROOT" ] && return 0
    [ "$(id -u)" -eq 0 ] || { err "root required"; return 2; }
}

# pve_major: Proxmox VE major version, empty if pveversion is missing.
pve_major() {
    command -v pveversion >/dev/null 2>&1 || return 0
    pveversion 2>/dev/null | sed -n 's|^pve-manager/\([0-9][0-9]*\)\..*|\1|p' | head -n1
}

# require_pve [major]: 2 if not PVE or the major version does not match.
require_pve() {
    local want=${1:-} have
    have=$(pve_major)
    [ -n "$have" ] || { err "pveversion not found: not a Proxmox VE node"; return 2; }
    if [ -n "$want" ] && [ "$have" != "$want" ]; then
        err "Proxmox VE $have, $want required"
        return 2
    fi
}

# confirm "question": 0 if confirmed. With PMN_YES=1 confirms without asking;
# without a terminal and without PMN_YES it refuses.
confirm() {
    local answer
    [ "$PMN_YES" = "1" ] && return 0
    [ -t 0 ] || { warn "no terminal to confirm: use --yes"; return 1; }
    printf '%s [y/N] ' "$1"
    read -r answer || return 1
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# run cmd args...: in dry-run prints the command, otherwise runs it.
run() {
    if [ "$PMN_DRY_RUN" = "1" ]; then
        printf '[dry-run] %s\n' "$*"
        return 0
    fi
    "$@"
}

# backup_file /path: copies under PMN_BACKUP_DIR preserving path and permissions.
backup_file() {
    local src=$1 rel dst
    [ -e "$src" ] || return 0
    [ -n "${PMN_BACKUP_DIR:-}" ] || { err "PMN_BACKUP_DIR not set"; return 1; }
    rel=${src#"$PMN_SYSROOT"}
    dst="${PMN_BACKUP_DIR%/}/${rel#/}"
    if [ "$PMN_DRY_RUN" = "1" ]; then
        printf '[dry-run] backup %s -> %s\n' "$src" "$dst"
        return 0
    fi
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    log "backup $src -> $dst"
}

# show_diff current proposed: unified diff; 0 if identical, 1 if different.
show_diff() {
    local cur=$1 new=$2
    if [ -e "$cur" ]; then
        diff -u --label "$cur" --label "$cur (proposed)" "$cur" "$new" && return 0
    else
        diff -u --label "(missing)" --label "$cur (proposed)" /dev/null "$new" && return 0
    fi
    return 1
}

# install_file source destination mode: atomic installation, root:root, only if changed.
# 0 if installed or already identical.
install_file() {
    local src=$1 dst=$2 mode=$3 tmp
    if [ -f "$dst" ] && cmp -s "$src" "$dst" && [ "$(file_mode "$dst")" = "$mode" ]; then
        return 0
    fi
    if [ "$PMN_DRY_RUN" = "1" ]; then
        printf '[dry-run] install -m %s %s -> %s\n' "$mode" "$src" "$dst"
        return 0
    fi
    mkdir -p "$(dirname "$dst")"
    tmp=$(mktemp "$(dirname "$dst")/.pmn.XXXXXX")
    cat "$src" > "$tmp"
    chmod "$mode" "$tmp"
    [ -n "$PMN_SYSROOT" ] || chown root:root "$tmp"
    mv -f "$tmp" "$dst"
    log "installed $dst ($mode)"
}

# replace_file destination new_content: atomic replacement keeping mode and owner.
replace_file() {
    local dst=$1 new=$2 tmp
    if [ "$PMN_DRY_RUN" = "1" ]; then
        printf '[dry-run] replace %s\n' "$dst"
        return 0
    fi
    tmp=$(mktemp "$(dirname "$dst")/.pmn.XXXXXX")
    cat "$new" > "$tmp"
    chmod "$(file_mode "$dst")" "$tmp"
    [ -n "$PMN_SYSROOT" ] || chown --reference="$dst" "$tmp"
    mv -f "$tmp" "$dst"
    log "updated $dst"
}

# file_mode path: four-digit octal mode (0644).
file_mode() {
    local m
    m=$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1")
    printf '%04d\n' "$m"
}

# file_owner path: user:group.
file_owner() {
    stat -c '%U:%G' "$1" 2>/dev/null || stat -f '%Su:%Sg' "$1"
}
