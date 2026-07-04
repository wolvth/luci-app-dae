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

# ── Dependency check (curl + unzip) ───────────────────────
tool_need=''
for tool in curl unzip; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        tool_need="$tool $tool_need"
    fi
done

if [ -n "$tool_need" ]; then
    echo "${GREEN}Installing missing tools: $tool_need${RESET}"
    if command -v opkg >/dev/null 2>&1; then
        opkg update && opkg install $tool_need
    elif command -v apk >/dev/null 2>&1; then
        apk add $tool_need
    elif command -v apt >/dev/null 2>&1; then
        apt update && apt install -y $tool_need
    else
        echo "${RED}error: Cannot install $tool_need — no known package manager.${RESET}" >&2
        exit 1
    fi
fi

# ── Architecture detection ────────────────────────────────
check_arch() {
    if [ -n "$MACHINE" ]; then return; fi

    arch="$(uname -m)"
    case "$arch" in
        aarch64 | armv8)   MACHINE='arm64' ;;
        armv7 | armv7l)    MACHINE='armv7' ;;
        armv6l)            MACHINE='armv6' ;;
        armv5tel)          MACHINE='armv5' ;;
        x86_64 | amd64)
            if grep -q avx2 /proc/cpuinfo 2>/dev/null; then
                MACHINE='x86_64_v3_avx2'
            elif grep -q sse /proc/cpuinfo 2>/dev/null; then
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

# ── Version helpers ───────────────────────────────────────
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

    v1="$(echo "$1" | sed 's/^v//;s/[a-zA-Z].*//' )"
    v2="$(echo "$2" | sed 's/^v//;s/[a-zA-Z].*//' )"

    a1="$(echo "$v1" | cut -d. -f1)"; a1="${a1:-0}"
    b1="$(echo "$v1" | cut -d. -f2)"; b1="${b1:-0}"
    c1="$(echo "$v1" | cut -d. -f3)"; c1="${c1:-0}"
    a2="$(echo "$v2" | cut -d. -f1)"; a2="${a2:-0}"
    b2="$(echo "$v2" | cut -d. -f2)"; b2="${b2:-0}"
    c2="$(echo "$v2" | cut -d. -f3)"; c2="${c2:-0}"

    for pair in "${a1}:${a2}" "${b1}:${b2}" "${c1}:${c2}"; do
        n1="${pair%%:*}"; n2="${pair##*:}"
        [ "$n1" -gt "$n2" ] 2>/dev/null && { echo 1; return; }
        [ "$n1" -lt "$n2" ] 2>/dev/null && { echo 2; return; }
    done
    echo 0
}

# ── Version check ─────────────────────────────────────────
get_local_version() {
    current_version=0
    if command -v /usr/bin/dae >/dev/null 2>&1; then
        current_version=$(/usr/bin/dae --version 2>/dev/null | awk 'NR==1{print $3}')
    fi
    current_version="${current_version:-0}"
}

get_remote_version() {
    if [ "$allow_prereleases" = 'yes' ]; then
        api_url='https://api.github.com/repos/daeuniverse/dae/releases?per_page=1'
    else
        api_url='https://api.github.com/repos/daeuniverse/dae/releases/latest'
    fi

    tmp="$(mktemp /tmp/dae.XXXXXX)"
    if ! curl -sf "$api_url" -o "$tmp"; then
        echo "${RED}error: Failed to fetch release info from GitHub API.${RESET}" >&2
        rm -f "$tmp"; exit 1
    fi

    latest_version="$(grep '"tag_name"' "$tmp" | head -n1 | \
        sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
    rm -f "$tmp"

    if [ -z "$latest_version" ]; then
        echo "${RED}error: Could not parse latest version.${RESET}" >&2
        exit 1
    fi
}

# ── Download URLs ─────────────────────────────────────────
get_download_urls() {
    _gh="https://github.com/daeuniverse/dae/releases/download/$latest_version"
    _raw="https://github.com/daeuniverse/dae/raw/$latest_version"

    dae_url="${_gh}/dae-linux-${MACHINE}.zip"
    dae_hash_url="${_gh}/dae-linux-${MACHINE}.zip.dgst"
    example_config_url="${_raw}/example.dae"
    geoip_url='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat'
    geosite_url='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat'
}

# ── GeoIP ─────────────────────────────────────────────────
download_geoip() {
    geoip_tmp="$(mktemp -d /tmp/dae.XXXXXX)"
    echo "${GREEN}Downloading GeoIP...${RESET}"
    curl -L "$geoip_url" -o "$geoip_tmp/geoip.dat" || \
        { echo "${RED}error: GeoIP download failed.${RESET}" >&2; rm -rf "$geoip_tmp"; exit 1; }
    curl -sL "${geoip_url}.sha256sum" -o "$geoip_tmp/geoip.dat.sha256sum" || \
        { echo "${RED}error: GeoIP checksum download failed.${RESET}" >&2; rm -rf "$geoip_tmp"; exit 1; }
    local_hash="$(SHA256SUM "$geoip_tmp/geoip.dat")"
    remote_hash="$(awk '{print $1}' < "$geoip_tmp/geoip.dat.sha256sum")"
    if [ "$local_hash" != "$remote_hash" ]; then
        echo "${RED}error: GeoIP checksum mismatch.${RESET}" >&2
        rm -rf "$geoip_tmp"; exit 1
    fi
}
update_geoip() {
    mkdir -p /usr/share/dae
    cp "$geoip_tmp/geoip.dat" /usr/share/dae/
    rm -rf "$geoip_tmp"
    echo "${GREEN}GeoIP updated.${RESET}"
}

# ── GeoSite ───────────────────────────────────────────────
download_geosite() {
    geosite_tmp="$(mktemp -d /tmp/dae.XXXXXX)"
    echo "${GREEN}Downloading GeoSite...${RESET}"
    curl -L "$geosite_url" -o "$geosite_tmp/geosite.dat" || \
        { echo "${RED}error: GeoSite download failed.${RESET}" >&2; rm -rf "$geosite_tmp"; exit 1; }
    curl -sL "${geosite_url}.sha256sum" -o "$geosite_tmp/geosite.dat.sha256sum" || \
        { echo "${RED}error: GeoSite checksum download failed.${RESET}" >&2; rm -rf "$geosite_tmp"; exit 1; }
    local_hash="$(SHA256SUM "$geosite_tmp/geosite.dat")"
    remote_hash="$(awk '{print $1}' < "$geosite_tmp/geosite.dat.sha256sum")"
    if [ "$local_hash" != "$remote_hash" ]; then
        echo "${RED}error: GeoSite checksum mismatch.${RESET}" >&2
        rm -rf "$geosite_tmp"; exit 1
    fi
}
update_geosite() {
    mkdir -p /usr/share/dae
    cp "$geosite_tmp/geosite.dat" /usr/share/dae/
    rm -rf "$geosite_tmp"
    echo "${GREEN}GeoSite updated.${RESET}"
}

# ── dae binary ────────────────────────────────────────────
download_dae() {
    echo "${GREEN}Downloading dae ${latest_version} for ${MACHINE}...${RESET}"
    curl -L "$dae_url" -o "dae-linux-${MACHINE}.zip" || \
        { echo "${RED}error: dae download failed.${RESET}" >&2; exit 1; }
    local_hash="$(SHA256SUM "dae-linux-${MACHINE}.zip")"
    curl -sL "$dae_hash_url" -o "dae-linux-${MACHINE}.zip.dgst" || \
        { echo "${RED}error: checksum file download failed.${RESET}" >&2; exit 1; }
    remote_hash="$(awk -v name="./dae-linux-${MACHINE}.zip" \
        '$0 ~ name {print $1}' "dae-linux-${MACHINE}.zip.dgst" | head -n1)"
    if [ -z "$remote_hash" ]; then
        remote_hash="$(awk 'NR==3{print $1}' "dae-linux-${MACHINE}.zip.dgst")"
    fi
    if [ "$local_hash" != "$remote_hash" ]; then
        echo "${RED}error: dae checksum mismatch.${RESET}" >&2
        rm -f "dae-linux-${MACHINE}.zip" "dae-linux-${MACHINE}.zip.dgst"
        exit 1
    fi
    rm -f "dae-linux-${MACHINE}.zip.dgst"
    echo "${GREEN}Checksum OK.${RESET}"
}

install_dae() {
    tmp_dir="$(mktemp -d /tmp/dae.XXXXXX)"
    unzip -q "dae-linux-${MACHINE}.zip" -d "$tmp_dir"
    find "$tmp_dir" -name "dae-linux-${MACHINE}" -exec cp {} /usr/bin/dae \;
    chmod +x /usr/bin/dae
    rm -f "dae-linux-${MACHINE}.zip"
    rm -rf "$tmp_dir"
    echo "${GREEN}dae installed -> /usr/bin/dae${RESET}"
}

# ── Internal helpers ──────────────────────────────────────
_get_local_version() {
    get_local_version
    echo "${GREEN}Local version: ${current_version}${RESET}"
}

_get_remote_version() {
    get_remote_version
    echo "${GREEN}Remote version: ${latest_version}${RESET}"
}

_should_install() {
    if [ "$current_version" = "$latest_version" ]; then
        echo "${GREEN}Already up-to-date.${RESET}"
        compare_status=0
    else
        compare_status="$(ver_compare "$current_version" "$latest_version")"
        case "$compare_status" in
            0) echo "${GREEN}Already up-to-date.${RESET}" ;;
            1) echo "${GREEN}Local ($current_version) newer than remote ($latest_version).${RESET}" ;;
            2) echo "${GREEN}Update: $current_version -> $latest_version${RESET}" ;;
        esac
    fi
}

_do_install() {
    get_download_urls
    download_dae
    install_dae
}

_do_update_geo() {
    get_download_urls
    download_geoip
    update_geoip
    download_geosite
    update_geosite
}

# ── Entry point ───────────────────────────────────────────
current_dir="$(pwd)"
cd /tmp || exit 1
trap 'cd "$current_dir"' EXIT INT TERM

allow_prereleases=''

case "$1" in
    install)
        check_arch
        get_local_version
        get_remote_version
        _should_install
        [ "$compare_status" -eq 2 ] && _do_install
        ;;
    install-prerelease)
        allow_prereleases='yes'
        check_arch
        get_local_version
        get_remote_version
        _should_install
        [ "$compare_status" -ne 0 ] && _do_install
        ;;
    update-geoip)
        check_arch
        get_download_urls
        download_geoip
        update_geoip
        ;;
    update-geosite)
        check_arch
        get_download_urls
        download_geosite
        update_geosite
        ;;
    *)
        echo "Usage: $0 {install|install-prerelease|update-geoip|update-geosite}" >&2
        exit 1
        ;;
esac
