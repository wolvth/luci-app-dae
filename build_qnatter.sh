#!/bin/bash
set -e

# ============================================================
# OpenWrt 25.12 编译 luci-app-qnatter 脚本
# 使用前请确认下方 TARGET_DEVICE 和 ARCH 设置正确
# ============================================================

# ---------- 可配置项 ----------
OPENWRT_VERSION="v25.12.5"                    # OpenWrt 版本标签
OPENWRT_REPO="https://git.openwrt.org/openwrt/openwrt.git"
QNATTER_FEED="src-git qnatter https://github.com/qimaoww/QNatter.git"
WORK_DIR="$HOME/openwrt-qnatter"              # 工作目录
JOBS=$(nproc)                                  # 并行编译数，改小点如果内存不够
# --------------------------------

echo "=========================================="
echo " OpenWrt ${OPENWRT_VERSION} + QNatter 编译"
echo "=========================================="

# 1. 克隆源码
if [ -d "$WORK_DIR/.git" ]; then
    echo "[*] 源码目录已存在，跳过克隆"
    cd "$WORK_DIR"
else
    echo "[1/7] 克隆 OpenWrt 源码 (${OPENWRT_VERSION})..."
    git clone --depth 1 --branch "$OPENWRT_VERSION" "$OPENWRT_REPO" "$WORK_DIR"
    cd "$WORK_DIR"
fi

# 2. 添加 QNatter feed
echo "[2/7] 添加 QNatter feed..."
grep -q "qnatter" feeds.conf.default 2>/dev/null || echo "$QNATTER_FEED" >> feeds.conf.default

# 3. 更新并安装 feeds
echo "[3/7] 更新 feeds..."
./scripts/feeds update -a
echo "[3/7] 安装 feeds..."
./scripts/feeds install -a

# 4. 生成 config（自动选目标设备，无需 menuconfig）
echo "[4/7] 写入目标设备配置 (rockchip / NanoPi R4S)..."
cat > .config << 'EOF'
CONFIG_TARGET_rockchip=y
CONFIG_TARGET_rockchip_armv8=y
CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r4s=y
EOF
make defconfig

# 5. 确认包名并追加到 config
echo "[5/7] 查找 QNatter 包名..."
echo "------------------------------------------"
./scripts/feeds list | grep -i qnatter
echo "------------------------------------------"
echo "如果上方没有输出，说明 feeds 安装有问题"

read -p "确认包名无误后按回车继续，或 Ctrl+C 中断修改脚本..."

# 追加 QNatter 相关包到 config
echo "[5/7] 选择 QNatter 包..."
# 先清掉旧的 qnatter 配置，避免重复
sed -i '/qnatter/d' .config

cat >> .config << 'EOF'
CONFIG_PACKAGE_qnatter=y
CONFIG_PACKAGE_luci-app-qnatter=y
CONFIG_PACKAGE_luci-i18n-qnatter-zh-cn=y
EOF

# 6. 下载依赖
echo "[6/7] 下载依赖..."
make download

# 7. 编译
echo "[7/7] 开始编译 (使用 ${JOBS} 个并行任务)..."
make package/luci-app-qnatter/compile V=s -j"$JOBS"

echo ""
echo "=========================================="
echo " 编译完成！"
echo " 产物目录: $(find bin/targets/ -name "*.ipk" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo '请在 bin/ 目录下查找')"
echo "=========================================="