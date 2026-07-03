#!/bin/sh
# dae installer/manager script
# Usage:
#   installer.sh install           - Install/update dae (stable)
#   installer.sh install-prerelease - Install latest prerelease
#   installer.sh uninstall         - Remove dae
#   installer.sh update-geo        - Update GeoIP/GeoSite databases
#   installer.sh version           - Show current dae version

set -e

DAE_BIN="/usr/bin/dae"
DAE_DIR="/etc/dae"
GEOIP_FILE="$DAE_DIR/geoip.dat"
GEOSITE_FILE="$DAE_DIR/geosite.dat"

# ── GeoIP/GeoSite source: Loyalsoldier (NOT runetfreedom) ──────────
geoip_url='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat'
geosite_url='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat'

# ── Architecture detection ─────────────────────────────────────────
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            echo "x86_64"
            ;;
        aarch64|arm64)
            echo "aarch64"
            ;;
        armv7*|armhf)
            echo "armv7"
            ;;
        armv6*)
            echo "armv6"
            ;;
        mipsel|mips)
            echo "mipsle"
            ;;
        riscv64)
            echo "riscv64"
            ;;
        s390x)
            echo "s390x"
            ;;
        *)
            echo "$arch"
            ;;
    esac
}

# ── Version comparison ─────────────────────────────────────────────
# Handles dev/unstable versions: they are always considered "older"
# than their base version. Returns 0 if $1 >= $2, 1 otherwise.
ver_compare() {
    # Returns: 0=equal  1=$1>$2  2=$1<$2
    [ "$1" = "$2" ] && { echo 0; return; }

    # dev/unstable builds always older than any proper release
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

# ── Dependency check ───────────────────────────────────────────────
check_deps() {
    local missing=""
    for cmd in curl tar gzip; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    if [ -n "$missing" ]; then
        echo "Missing dependencies:$missing"
        echo "Install with: opkg install${missing}"
        return 1
    fi
}

# ── Get latest release info from GitHub ────────────────────────────
get_latest_release() {
    local repo="$1" prerelease="$2"
    local api_url="https://api.github.com/repos/$repo/releases"

    if [ "$prerelease" = "true" ]; then
        # Get the latest release (including prereleases)
        curl -sL "$api_url" | python3 -c "
import json, sys
releases = json.load(sys.stdin)
if releases:
    print(releases[0]['tag_name'])
" 2>/dev/null
    else
        # Get the latest stable release
        curl -sL "https://api.github.com/repos/$repo/releases/latest" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('tag_name', ''))
" 2>/dev/null
    fi
}

# ── Download and install dae binary ────────────────────────────────
install_dae() {
    local prerelease="${1:-false}"
    local repo="daeuniverse/dae"
    local arch version download_url

    arch=$(detect_arch)
    echo "Detected architecture: $arch"

    echo "Fetching latest release info..."
    version=$(get_latest_release "$repo" "$prerelease")
    if [ -z "$version" ]; then
        echo "ERROR: Could not determine latest version"
        return 1
    fi
    echo "Latest version: $version"

    # Check if already installed and up to date
    if [ -x "$DAE_BIN" ]; then
        local current_ver
        current_ver=$("$DAE_BIN" version 2>/dev/null | awk '{print $NF}')
        if [ "$current_ver" = "$version" ]; then
            echo "Already up to date: $current_ver"
            return 0
        fi
        echo "Updating: $current_ver -> $version"
    fi

    # Construct download URL
    download_url="https://github.com/$repo/releases/download/${version}/dae-linux-${arch}.zip"
    echo "Downloading: $download_url"

    local tmpdir
    tmpdir=$(mktemp -d)

    if ! curl -fSL --connect-timeout 30 --max-time 300 -o "$tmpdir/dae.zip" "$download_url"; then
        echo "ERROR: Download failed"
        rm -rf "$tmpdir"
        return 1
    fi

    echo "Extracting..."
    if command -v unzip >/dev/null 2>&1; then
        unzip -o "$tmpdir/dae.zip" -d "$tmpdir"
    else
        # Use python3 as fallback
        python3 -c "
import zipfile, sys
with zipfile.ZipFile(sys.argv[1], 'r') as z:
    z.extractall(sys.argv[2])
" "$tmpdir/dae.zip" "$tmpdir"
    fi

    # Find the dae binary
    local dae_file
    dae_file=$(find "$tmpdir" -name "dae" -type f | head -1)
    if [ -z "$dae_file" ]; then
        echo "ERROR: dae binary not found in archive"
        rm -rf "$tmpdir"
        return 1
    fi

    # Install binary
    echo "Installing dae binary to $DAE_BIN..."
    # Stop service if running
    /etc/init.d/dae stop 2>/dev/null || true

    cp "$dae_file" "$DAE_BIN"
    chmod 0755 "$DAE_BIN"

    rm -rf "$tmpdir"

    # Verify installation
    local installed_ver
    installed_ver=$("$DAE_BIN" version 2>/dev/null | awk '{print $NF}')
    echo "Installed dae version: $installed_ver"

    # Install shell completions if available
    install_completions

    echo "Installation complete!"
    echo "Configure dae: /etc/dae/config.dae"
    echo "Start with: /etc/init.d/dae start"
}

# ── Install shell completions ──────────────────────────────────────
install_completions() {
    if ! command -v "$DAE_BIN" >/dev/null 2>&1; then
        return
    fi

    # Bash completions
    if [ -d /usr/share/bash-completion/completions ]; then
        "$DAE_BIN" completion bash > /usr/share/bash-completion/completions/dae 2>/dev/null || true
    fi

    # Zsh completions
    if [ -d /usr/share/zsh/vendor-completions ]; then
        "$DAE_BIN" completion zsh > /usr/share/zsh/vendor-completions/_dae 2>/dev/null || true
    fi

    # Fish completions
    if [ -d /usr/share/fish/vendor_completions.d ]; then
        "$DAE_BIN" completion fish > /usr/share/fish/vendor_completions.d/dae.fish 2>/dev/null || true
    fi
}

# ── Update GeoIP/GeoSite ──────────────────────────────────────────
update_geo() {
    echo "Updating GeoIP database..."
    mkdir -p "$DAE_DIR"

    if curl -fSL --connect-timeout 30 --max-time 120 -o "${GEOIP_FILE}.tmp" "$geoip_url"; then
        mv "${GEOIP_FILE}.tmp" "$GEOIP_FILE"
        echo "GeoIP updated: $GEOIP_FILE"
    else
        echo "WARNING: GeoIP download failed"
        rm -f "${GEOIP_FILE}.tmp"
    fi

    echo "Updating GeoSite database..."
    if curl -fSL --connect-timeout 30 --max-time 120 -o "${GEOSITE_FILE}.tmp" "$geosite_url"; then
        mv "${GEOSITE_FILE}.tmp" "$GEOSITE_FILE"
        echo "GeoSite updated: $GEOSITE_FILE"
    else
        echo "WARNING: GeoSite download failed"
        rm -f "${GEOSITE_FILE}.tmp"
    fi

    echo "GeoIP/GeoSite update complete"
}

# ── Uninstall ──────────────────────────────────────────────────────
uninstall_dae() {
    echo "Stopping dae service..."
    /etc/init.d/dae stop 2>/dev/null || true
    /etc/init.d/dae disable 2>/dev/null || true

    echo "Removing dae binary..."
    rm -f "$DAE_BIN"

    echo "Removing shell completions..."
    rm -f /usr/share/bash-completion/completions/dae
    rm -f /usr/share/zsh/vendor-completions/_dae
    rm -f /usr/share/fish/vendor_completions.d/dae.fish

    echo ""
    echo "dae has been uninstalled."
    echo "Configuration files in $DAE_DIR were preserved."
    echo "To remove config: rm -rf $DAE_DIR"
}

# ── Main dispatch ──────────────────────────────────────────────────
case "${1:-}" in
    install)
        check_deps
        install_dae false
        ;;
    install-prerelease)
        check_deps
        install_dae true
        ;;
    uninstall)
        uninstall_dae
        ;;
    update-geo)
        check_deps
        update_geo
        ;;
    version)
        if [ -x "$DAE_BIN" ]; then
            "$DAE_BIN" version 2>/dev/null
        else
            echo "dae is not installed"
        fi
        ;;
    *)
        echo "Usage: $0 {install|install-prerelease|uninstall|update-geo|version}"
        echo ""
        echo "  install           Install or update dae (latest stable release)"
        echo "  install-prerelease Install latest prerelease version"
        echo "  uninstall         Remove dae binary and completions"
        echo "  update-geo        Update GeoIP/GeoSite databases"
        echo "  version           Show installed dae version"
        exit 1
        ;;
esac
