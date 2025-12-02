#!/usr/bin/env bash
set -euo pipefail

# 在 GitHub Actions 上，WORKDIR 会是 GITHUB_WORKSPACE；本地直接使用当前目录
WORKDIR="${GITHUB_WORKSPACE:-$(pwd)}"
cd "$WORKDIR"

LOGFILE="$WORKDIR/immortalwrt-build.log"
echo ">>> ImmortalWrt Auto Build (workdir: $WORKDIR)"
echo ">>> Log: $LOGFILE"

# helper
run_and_log() {
  echo ">>> $*"
  "$@" 2>&1 | tee -a "$LOGFILE"
}

# -------------------------------
# 0. 环境检查（可选）
# -------------------------------
echo ">>> python3 version: $(python3 --version 2>/dev/null || true)"
echo ">>> pip3 version: $(pip3 --version 2>/dev/null || true)"
nproc || true

# -------------------------------
# 1. 获取 / 更新 immortalwrt 源码（强制同步）
# -------------------------------
if [ ! -d "immortalwrt" ]; then
  echo ">>> Cloning immortalwrt..."
  git clone --depth=1 https://github.com/immortalwrt/immortalwrt.git immortalwrt
else
  echo ">>> Updating immortalwrt (reset/pull)..."
  cd immortalwrt
  git fetch --all || true
  git reset --hard origin/HEAD || true
  git clean -fdx || true
  git pull --rebase || true
  cd ..
fi

# 进入源码目录
cd immortalwrt

# -------------------------------
# 2. 修补 odhcpd / odhcp6c 指定版本（如果需要）
# -------------------------------
fix_makefile() {
  local mk="$1" date="$2" ver="$3" hash="$4"
  [ -f "$mk" ] || return 0
  grep -q "$ver" "$mk" && return 0
  echo ">>> Patching $mk"
  sed -i "s/^PKG_SOURCE_DATE:=.*/PKG_SOURCE_DATE:=$date/" "$mk" || true
  sed -i "s/^PKG_SOURCE_VERSION:=.*/PKG_SOURCE_VERSION:=$ver/" "$mk" || true
  sed -i "s/^PKG_MIRROR_HASH:=.*/PKG_MIRROR_HASH:=$hash/" "$mk" || true
}

fix_makefile "package/network/services/odhcpd/Makefile" \
  "2025-10-26" \
  "fc27940fe9939f99aeb988d021c7edfa54460123" \
  "acb086731fd7d072ddddc1d5f3bad9377e89a05597ce004d24bd0cdb60586f0a"

fix_makefile "package/network/ipv6/odhcp6c/Makefile" \
  "2025-10-21" \
  "77e1ae21e67f81840024ffe5bb7cf69a8fb0d2f0" \
  "78f1c2342330da5f6bf08a4be89df1d771661966bbff13bd15462035de46837b"

# -------------------------------
# 3. 插件检测与拉取（含 qmodem feed）
# -------------------------------
# qmodem feed 注入
if ! grep -q "src-git qmodem" feeds.conf.default 2>/dev/null; then
  echo "src-git qmodem https://github.com/FUjr/QModem.git;main" >> feeds.conf.default
fi

# 屏幕 driver + 自定义插件列表（会 clone 到 package/ 下）
mkdir -p package/zz
declare -a CUSTOM_REPOS=(
  "https://github.com/zzzz0317/kmod-fb-tft-gc9307.git package/zz/kmod-fb-tft-gc9307"
  "https://github.com/zzzz0317/xgp-v3-screen.git package/zz/xgp-v3-screen"
  "https://github.com/asvow/luci-app-tailscale.git package/luci-app-tailscale"
  "https://github.com/EasyTier/luci-app-easytier.git package/luci-app-easytier"
  "https://github.com/sirpdboy/luci-app-lucky.git package/lucky"
)

for entry in "${CUSTOM_REPOS[@]}"; do
  url=$(echo "$entry" | awk '{print $1}')
  path=$(echo "$entry" | awk '{print $2}')
  if [ ! -d "$path/.git" ]; then
    echo ">>> Cloning $url -> $path"
    git clone --depth=1 "$url" "$path" || ( echo "clone failed: $url" && true )
  else
    echo ">>> Updating $path"
    (cd "$path" && git pull --rebase || true)
  fi
done

# 替换 tailscale Makefile 中默认 init/config 删除行（按需）
if [ -f "feeds/packages/net/tailscale/Makefile" ]; then
  sed -i '/\/etc\/init\.d\/tailscale/d;/\/etc\/config\/tailscale/d;' feeds/packages/net/tailscale/Makefile || true
fi

# 更新 feeds，install feeds（带重试）
for i in 1 2 3; do
  ./scripts/feeds update -a && ./scripts/feeds install -a && break
  echo ">>> feeds update/install failed, retry $i/3" >&2
  sleep 8
done

# 强制安装 qmodem feed package（防止包路径问题）
./scripts/feeds install -a -p qmodem || true
./scripts/feeds install -a -f -p qmodem || true

# -------------------------------
# 4. 使用根目录 xgp.config 作为 .config（如果存在）
# -------------------------------
ROOTCFG="$WORKDIR/xgp.config"
if [ -f "$ROOTCFG" ]; then
  echo ">>> Using $ROOTCFG as .config"
  cp -f "$ROOTCFG" .config
else
  echo ">>> No xgp.config at repo root; leaving .config as-is (use make defconfig if needed)"
fi

# -------------------------------
# 5. 准备 files 目录与首启脚本
# -------------------------------
mkdir -p files/etc/config files/etc/uci-defaults files/etc/udev/rules.d files/usr/bin

# QModem default config (append only if not exist)
if [ ! -f "files/etc/config/qmodem" ]; then
cat > files/etc/config/qmodem <<'EOF'
config modem-slot 'wwan'
    option type 'usb'
    option slot '8-1'
    option net_led 'blue:net'
    option alias 'wwan'

config modem-slot 'mpcie1'
    option type 'pcie'
    option slot '0001:11:00.0'
    option net_led 'blue:net'
    option alias 'mpcie1'

config modem-slot 'mpcie2'
    option type 'pcie'
    option slot '0002:21:00.0'
    option net_led 'blue:net'
    option alias 'mpcie2'
EOF
fi

# 首次开机 wifi/lan 初始化（密码 88888888，国家 US）
cat > files/etc/uci-defaults/99-firstboot <<'EOF'
#!/bin/sh
# first boot init for XGP
uci set system.@system[0].hostname='zzXGP'
uci commit system

uci set network.lan.ipaddr='10.0.11.1'
uci commit network

for radio in $(uci show wireless 2>/dev/null | grep "=wifi-device" | cut -d. -f2 | cut -d= -f1); do
  uci set wireless.$radio.country='US'
  # choose simple channel if scanning not available
  if command -v iwlist >/dev/null 2>&1; then
    best_channel=$(iwlist $radio scan 2>/dev/null | awk -F: '/Channel/ {print $2}' | sort | uniq | head -n1)
    [ -n "$best_channel" ] && uci set wireless.$radio.channel="$best_channel"
  fi
  # ensure iface exists
  iface=$(uci show wireless | grep -m1 "=wifi-iface" | cut -d. -f2 || echo "default_$radio")
  [ -z "$iface" ] && iface="default_$radio"
  uci -q get wireless.$iface >/dev/null || {
    uci add wireless wifi-iface
    last=$(uci show wireless | tail -n1 | cut -d. -f2)
    uci rename wireless.$last="$iface"
  }
  uci set wireless.$iface.device="$radio"
  uci set wireless.$iface.mode='ap'
  uci set wireless.$iface.network='lan'
  uci set wireless.$iface.ssid='zzXGP'
  uci set wireless.$iface.encryption='psk2+ccmp'
  uci set wireless.$iface.key='88888888'
done
uci commit wireless

uci set luci.main.lang='zh_cn'
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit luci
exit 0
EOF
chmod +x files/etc/uci-defaults/99-firstboot

# QModem hotplug udev rules + script
cat > files/etc/udev/rules.d/99-qmodem.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1199", RUN+="/usr/bin/qmodem-hotplug.sh pci %p"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0x1199", RUN+="/usr/bin/qmodem-hotplug.sh usb %p"
EOF

cat > files/usr/bin/qmodem-hotplug.sh <<'EOF'
#!/bin/sh
TYPE="$1"
SLOT="$2"
[ -f /etc/config/qmodem ] || exit 0
uci add qmodem modem-slot
uci set qmodem.@modem-slot[-1].type="$TYPE"
uci set qmodem.@modem-slot[-1].slot="$SLOT"
uci commit qmodem
# add basic mwan3 interface entry (best-effort)
uci add mwan3 interface || true
uci set mwan3.@interface[-1].enabled='1' || true
uci set mwan3.@interface[-1].interface='wwan' || true
uci commit mwan3 || true
EOF
chmod +x files/usr/bin/qmodem-hotplug.sh

# Ensure sysupgrade keeps qmodem config
mkdir -p files/lib/upgrade
echo "etc/config/qmodem" > files/lib/upgrade/zz-qmodem

# -------------------------------
# 6. .config fallback, defconfig if none provided
# -------------------------------
if [ ! -f ".config" ]; then
  echo ">>> No .config found; using make defconfig"
  make defconfig
fi

# -------------------------------
# 7. 下载依赖并编译（记录日志，定位第一个 error）
# -------------------------------
BUILD_LOG="$WORKDIR/build_make.log"
set +e
make download -j"$(nproc)" V=s 2>&1 | tee "$BUILD_LOG"
make -j"$(nproc)" V=s 2>&1 | tee -a "$BUILD_LOG"
RET=${PIPESTATUS[0]}
set -e

if [ "$RET" -ne 0 ]; then
  echo ">>> BUILD FAILED. First error (grep):"
  grep -n -E " error:|^make\\[|^ERROR|" "$BUILD_LOG" | head -n 1 || true
  exit 1
fi

echo ">>> BUILD SUCCESS"
cd "$WORKDIR"
