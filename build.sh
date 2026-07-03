#!/bin/sh
set -e

VERSION="2.0.0"
PKG="luci-app-dae_${VERSION}-1_all"
DIR="$(cd "$(dirname "$0")"; pwd)"
BUILD="/tmp/_luci-app-dae-build"
DIST="$DIR/dist"

rm -rf "$BUILD"
mkdir -p "$BUILD/data" "$BUILD/control" "$BUILD/stage" "$DIST"

cp -r "$DIR/root/." "$BUILD/data/"
cp -r "$DIR/www/."  "$BUILD/data/www/"
chmod +x "$BUILD/data/usr/libexec/rpcd/luci.dae" \
         "$BUILD/data/etc/uci-defaults/90_dae" \
         "$BUILD/data/usr/share/dae/installer.sh"

# 注意: 如果你的 uci-defaults 脚本改名了(90→99), 上面路径要对应
