#!/bin/sh
# dae installer — optimized for luci-app-dae RPC backend
# Commands: install | install-prerelease | update-geoip | update-geosite
# Based on: https://github.com/daeuniverse/dae-installer

set -e

# ── Color ──────────────────────────────────────────────────
if command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    RESET=$(tput sgr0)
else
    RED='' GREEN='' RESET=''
fi

# ── Temporary file tracking ────────────────────────────────
_CLEANUP_FILES=''
_CLEANUP_DIRS=''

# ── Cleanup handler ────────────────────────────────────────
cleanup() {
    local current_dir="$1"
    [ -n "$current_dir" ] && cd "$current_dir" 2>/dev/null || true
    
    # Clean up tracked files
    if [ -n "$_CLEANUP_FILES" ]; then
        for file in $_CLEANUP_FILES; do
            rm -f "$file" 2>/dev/null || true
        done
    fi
    
    # Clean up tracked directories
    if [ -n "$_CLEANUP_DIRS" ]; then
        for dir in $_CLEANUP_DIRS; do
            rm -rf "$dir" 2>/dev/null || true
        done
    fi
}

track_cleanup_file() {
    _CLEANUP_FILES="$_CLEANUP_FILES $1"
}

track_cleanup_dir() {
    _CLEANUP_DIRS="$_CLEANUP_DIRS $1"
}

# ── SHA256 ─────────────────────────────────────────────────
SHA256SUM() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v busybox >/dev/null 2>&1; then
        busybox sha256sum "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | awk '{print $2}'
    else
        echo "${RED}error: No sha256 tool found.${RESET}" >&2
        exit 1
    fi
}

# Validate SHA256 format (64 hex characters)
validate_sha256() {
    local hash="$1"
    if echo "$hash" | grep -qE '^[a-f0-9]{64}$'; then
        return 0
    else
        return 1
    fi
}

# ── Dependency check (curl + unzip) ───────────────────────
check_dependencies() {
    local missing_tools=''
    
    for tool in curl unzip; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools="$missing_tools $tool"
        fi
    done
    
    if [ -n "$missing_tools" ]; then
        echo "${GREEN}Installing missing tools:$missing_tools${RESET}"
        
        # OpenWrt modern standard uses apk
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache curl unzip || {
                echo "${RED}error: Failed to install tools with apk. Check package availability.${RESET}" >&2
                exit 1
            }
        else
            echo "${RED}error: apk package manager not found. OpenWrt installation incomplete?${RESET}" >&2
            exit 1
        fi
    fi
}

# ── Architecture detection ────────────────────────────────
check_arch() {
    if [ -n "$MACHINE" ]; then return; fi

    local arch
    arch="$(uname -m)"
    
    case "$arch" in
        aarch64 | armv8)   MACHINE='arm64' ;;
        armv7 | armv7l)    MACHINE='armv7' ;;
        armv6l)            MACHINE='armv6' ;;
        armv5tel)          MACHINE='armv5' ;;
        x86_64 | amd64)
            # Use word boundaries (-w) to avoid false matches
            if grep -qw 'avx2' /proc/cpuinfo 2>/dev/null; then
                MACHINE='x86_64_v3_avx2'
            elif grep -qw 'sse4_2' /proc/cpuinfo 2>/dev/null; then
                MACHINE='x86_64_v2_sse'
            else
                MACHINE='x86_64'
            fi
            ;;
        i386 | i686)       MACHINE='x86_32' ;;
        mips)              MACHINE='mips32' ;;
        mipsle)            MACHINE='mips32le' ;;
        mips64)            MACHINE='mips64' ;;
        mips64le)          MACHINE='mips64le' ;;
        riscv64)           MACHINE='riscv64' ;;
        *)
            echo "${RED}error: Unsupported architecture: $arch${RESET}" >&2
            exit 1
            ;;
    esac

    echo "${GREEN}Detected architecture: $MACHINE${RESET}"
}

# ── Version helpers ─────────────────────────────────────
# POSIX version compare — no sort -V (not in busybox)
# Returns: 0=equal  1=$1>$2  2=$1<$2
ver_compare() {
    [ "$1" = "$2" ] && { echo 0; return; }

    case "$1" in
        unstable-*|dev-*|nightly-*|snapshot-*|ci-*)
            echo 2; return ;;
    esac
    case "$2" in
        unstable-*|dev-*|nightly-*|snapshot-*|ci-*)
            echo 1; return ;;
    esac

    local v1 v2
    v1="$(echo "$1" | sed 's/^v//;s/[a-zA-Z].*//' )"
    v2="$(echo "$2" | sed 's/^v//;s/[a-zA-Z].*//' )"

    local a1 b1 c1 a2 b2 c2
    a1="$(echo "$v1" | cut -d. -f1)"; a1="${a1:-0}"
    b1="$(echo "$v1" | cut -d. -f2)"; b1="${b1:-0}"
    c1="$(echo "$v1" | cut -d. -f3)"; c1="${c1:-0}"
    a2="$(echo "$v2" | cut -d. -f1)"; a2="${a2:-0}"
    b2="$(echo "$v2" | cut -d. -f2)"; b2="${b2:-0}"
    c2="$(echo "$v2" | cut -d. -f3)"; c2="${c2:-0}"

    for pair in "${a1}:${a2}" "${b1}:${b2}" "${c1}:${c2}"; do
        local n1 n2
        n1="${pair%%:*}"; n2="${pair##*:}"
        [ "$n1" -gt "$n2" ] 2>/dev/null && { echo 1; return; }
        [ "$n1" -lt "$n2" ] 2>/dev/null && { echo 2; return; }
    done
    echo 0
}

# ── Version check ─────────────────────────────────────────
get_local_version() {
    current_version='0'
    if command -v /usr/bin/dae >/dev/null 2>&1; then
        current_version=$(/usr/bin/dae --version 2>/dev/null | awk 'NR==1{print $3}')
    fi
    current_version="${current_version:-0}"
}

get_remote_version() {
    # Always fetch latest release including pre-releases
    local api_url='https://api.github.com/repos/daeuniverse/dae/releases?per_page=1'
    
    local tmp
    tmp="$(mktemp /tmp/dae.XXXXXX)"
    track_cleanup_file "$tmp"
    
    if ! curl -sf "$api_url" -o "$tmp"; then
        echo "${RED}error: Failed to fetch release info from GitHub API.${RESET}" >&2
        return 1
    fi

    latest_version="$(grep '"tag_name"' "$tmp" | head -n1 | \
        sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"

    if [ -z "$latest_version" ]; then
        echo "${RED}error: Could not parse latest version.${RESET}" >&2
        return 1
    fi
}

# ── Download URLs ─────────────────────────────────────────
get_download_urls() {
    local _gh _raw
    _gh="https://github.com/daeuniverse/dae/releases/download/$latest_version"
    _raw="https://github.com/daeuniverse/dae/raw/$latest_version"

    dae_url="${_gh}/dae-linux-${MACHINE}.zip"
    dae_hash_url="${_gh}/dae-linux-${MACHINE}.zip.dgst"
    geoip_url='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat'
    geosite_url='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat'
}

# ── GeoIP ─────────────────────────────────────────────────
download_geoip() {
    local geoip_tmp
    geoip_tmp="$(mktemp -d /tmp/dae.XXXXXX)"
    track_cleanup_dir "$geoip_tmp"
    
    echo "${GREEN}Downloading GeoIP...${RESET}"
    if ! curl -L "$geoip_url" -o "$geoip_tmp/geoip.dat"; then
        echo "${RED}error: GeoIP download failed.${RESET}" >&2
        return 1
    fi
    
    if ! curl -sL "${geoip_url}.sha256sum" -o "$geoip_tmp/geoip.dat.sha256sum"; then
        echo "${RED}error: GeoIP checksum download failed.${RESET}" >&2
        return 1
    fi
    
    local local_hash remote_hash
    local_hash="$(SHA256SUM "$geoip_tmp/geoip.dat")"
    remote_hash="$(awk '{print $1}' < "$geoip_tmp/geoip.dat.sha256sum")"
    
    if [ "$local_hash" != "$remote_hash" ]; then
        echo "${RED}error: GeoIP checksum mismatch. Expected: $remote_hash, Got: $local_hash${RESET}" >&2
        return 1
    fi
    
    mkdir -p /usr/share/dae
    cp "$geoip_tmp/geoip.dat" /usr/share/dae/ || {
        echo "${RED}error: Failed to copy GeoIP to /usr/share/dae${RESET}" >&2
        return 1
    }
    echo "${GREEN}GeoIP updated.${RESET}"
}

# ── GeoSite ───────────────────────────────────────────────
download_geosite() {
    local geosite_tmp
    geosite_tmp="$(mktemp -d /tmp/dae.XXXXXX)"
    track_cleanup_dir "$geosite_tmp"
    
    echo "${GREEN}Downloading GeoSite...${RESET}"
    if ! curl -L "$geosite_url" -o "$geosite_tmp/geosite.dat"; then
        echo "${RED}error: GeoSite download failed.${RESET}" >&2
        return 1
    fi
    
    if ! curl -sL "${geosite_url}.sha256sum" -o "$geosite_tmp/geosite.dat.sha256sum"; then
        echo "${RED}error: GeoSite checksum download failed.${RESET}" >&2
        return 1
    fi
    
    local local_hash remote_hash
    local_hash="$(SHA256SUM "$geosite_tmp/geosite.dat")"
    remote_hash="$(awk '{print $1}' < "$geosite_tmp/geosite.dat.sha256sum")"
    
    if [ "$local_hash" != "$remote_hash" ]; then
        echo "${RED}error: GeoSite checksum mismatch. Expected: $remote_hash, Got: $local_hash${RESET}" >&2
        return 1
    fi
    
    mkdir -p /usr/share/dae
    cp "$geosite_tmp/geosite.dat" /usr/share/dae/ || {
        echo "${RED}error: Failed to copy GeoSite to /usr/share/dae${RESET}" >&2
        return 1
    }
    echo "${GREEN}GeoSite updated.${RESET}"
}

# ── dae binary ────────────────────────────────────────────
download_dae() {
    echo "${GREEN}Downloading dae ${latest_version} for ${MACHINE}...${RESET}"
    
    if ! curl -L "$dae_url" -o "dae-linux-${MACHINE}.zip"; then
        echo "${RED}error: dae download failed.${RESET}" >&2
        rm -f "dae-linux-${MACHINE}.zip"
        return 1
    fi
    track_cleanup_file "dae-linux-${MACHINE}.zip"
    
    local local_hash
    local_hash="$(SHA256SUM "dae-linux-${MACHINE}.zip")"
    
    if ! curl -sL "$dae_hash_url" -o "dae-linux-${MACHINE}.zip.dgst"; then
        echo "${RED}error: checksum file download failed.${RESET}" >&2
        return 1
    fi
    track_cleanup_file "dae-linux-${MACHINE}.zip.dgst"
    
    # Extract checksum with multiple format support
    local remote_hash
    remote_hash=""
    
    # Format 1: "hash  ./filename"
    remote_hash="$(awk -v name="dae-linux-${MACHINE}.zip" '$0 ~ name {print $1}' "dae-linux-${MACHINE}.zip.dgst" 2>/dev/null | head -n1)"
    
    # Format 2: "hash  filename" (without path)
    if [ -z "$remote_hash" ]; then
        remote_hash="$(awk '$NF ~ /dae-linux.*\.zip$/ {print $1}' "dae-linux-${MACHINE}.zip.dgst" 2>/dev/null | head -n1)"
    fi
    
    # Format 3: First line (fallback)
    if [ -z "$remote_hash" ]; then
        remote_hash="$(head -n1 "dae-linux-${MACHINE}.zip.dgst" 2>/dev/null | awk '{print $1}')"
    fi
    
    # Validate hash format
    if ! validate_sha256 "$remote_hash"; then
        echo "${RED}error: Invalid or missing checksum in .dgst file. Got: $remote_hash${RESET}" >&2
        return 1
    fi
    
    if [ "$local_hash" != "$remote_hash" ]; then
        echo "${RED}error: dae checksum mismatch. Expected: $remote_hash, Got: $local_hash${RESET}" >&2
        return 1
    fi
    
    echo "${GREEN}Checksum OK.${RESET}"
}

install_dae() {
    local tmp_dir dae_bin
    tmp_dir="$(mktemp -d /tmp/dae.XXXXXX)" || {
        echo "${RED}error: Failed to create temp directory.${RESET}" >&2
        return 1
    }
    track_cleanup_dir "$tmp_dir"
    
    if ! unzip -q "dae-linux-${MACHINE}.zip" -d "$tmp_dir"; then
        echo "${RED}error: Failed to unzip dae binary.${RESET}" >&2
        return 1
    fi
    
    # Find the binary
    dae_bin="$(find "$tmp_dir" -name "dae-linux-${MACHINE}" -type f 2>/dev/null | head -n1)"
    if [ -z "$dae_bin" ]; then
        echo "${RED}error: dae binary not found in archive.${RESET}" >&2
        return 1
    fi
    
    # Backup old version if exists
    if [ -f /usr/bin/dae ]; then
        if ! cp /usr/bin/dae /usr/bin/dae.bak 2>/dev/null; then
            echo "${RED}warning: Could not backup old dae binary.${RESET}" >&2
        fi
    fi
    
    # Install new version
    if ! install -m 755 "$dae_bin" /usr/bin/dae; then
        echo "${RED}error: Failed to install dae binary.${RESET}" >&2
        [ -f /usr/bin/dae.bak ] && cp /usr/bin/dae.bak /usr/bin/dae
        return 1
    fi
    
    # Verify new version
    if ! /usr/bin/dae --version >/dev/null 2>&1; then
        echo "${RED}error: Installed dae binary is not executable or corrupt.${RESET}" >&2
        if [ -f /usr/bin/dae.bak ]; then
            cp /usr/bin/dae.bak /usr/bin/dae
            echo "${GREEN}Reverted to previous version.${RESET}"
        fi
        return 1
    fi
    
    # Clean up backup
    rm -f /usr/bin/dae.bak 2>/dev/null || true
    echo "${GREEN}dae installed -> /usr/bin/dae${RESET}"
}

# ── Version comparison and decision ────────────────────────
check_update_needed() {
    if [ "$current_version" = "$latest_version" ]; then
        echo "${GREEN}Already up-to-date ($current_version).${RESET}"
        return 1
    fi
    
    local compare_result
    compare_result="$(ver_compare "$current_version" "$latest_version")"
    
    case "$compare_result" in
        0)
            echo "${GREEN}Already up-to-date.${RESET}"
            return 1
            ;;
        1)
            echo "${GREEN}Local version ($current_version) is newer than remote ($latest_version).${RESET}"
            return 1
            ;;
        2)
            echo "${GREEN}Update available: $current_version -> $latest_version${RESET}"
            return 0
            ;;
    esac
    return 1
}

# ── Internal helpers ──────────────────────────────────────
_do_install() {
    get_download_urls || return 1
    download_dae || return 1
    install_dae || return 1
}

_do_update_geo() {
    get_download_urls || return 1
    download_geoip || return 1
    download_geosite || return 1
}

# ── Entry point ───────────────────────────────────────────
current_dir="$(pwd)"
cd /tmp || exit 1
trap 'cleanup "$current_dir"' EXIT INT TERM

# Check dependencies at start
check_dependencies

case "$1" in
    install)
        check_arch
        get_local_version
        get_remote_version || exit 1
        check_update_needed && _do_install
        ;;
    install-prerelease)
        # For official versions (not action/unstable), check if update is available
        check_arch
        get_local_version
        
        # Check if current version is an official/normal version (not action/dev)
        case "$current_version" in
            unstable-*|dev-*|nightly-*|snapshot-*|ci-*)
                # This is an action build version - should not reach here
                # (handled by luci.dae caller which uses updae_from_actions.sh)
                echo "${GREEN}Current version is special build ($current_version).${RESET}"
                echo "${GREEN}Use updae_from_actions.sh for updates.${RESET}"
                exit 0
                ;;
            *)
                # Normal official version - fetch latest pre-release and compare
                get_remote_version || exit 1
                check_update_needed && _do_install
                ;;
        esac
        ;;
    update-geoip)
        check_arch
        get_download_urls || exit 1
        download_geoip || exit 1
        ;;
    update-geosite)
        check_arch
        get_download_urls || exit 1
        download_geosite || exit 1
        ;;
    *)
        echo "Usage: $0 {install|install-prerelease|update-geoip|update-geosite}" >&2
        exit 1
        ;;
esac
