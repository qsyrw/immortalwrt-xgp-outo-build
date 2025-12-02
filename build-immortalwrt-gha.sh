#!/bin/bash
set -e
set -o pipefail

# GitHub Actions workspace 或本地HOME
ROOT_DIR="${GITHUB_WORKSPACE:-$HOME}"
IW_DIR="$ROOT_DIR/immortalwrt"
BUILD_LOG="$ROOT_DIR/immortalwrt-build.log"

echo "🔥 ImmortalWrt Auto Build"
echo "📍 Workdir: $ROOT_DIR"
echo "🧾 Log: $BUILD_LOG"

####################################
# 0️⃣ 安装依赖（GitHub Actions / Ubuntu）
####################################
if command -v apt &> /dev/null; then
    echo "[+] Installing build dependencies..."
    sudo apt update
    sudo apt install -y \
      build-essential libncurses5-dev gawk git subversion libssl-dev \
      gettext zlib1g-dev file wget python3 python3-distutils unzip bc \
      libelf-dev autoconf libtool autopoint pkg-config unzip flex bison \
      rsync curl time || true
fi

####################################
# 1️⃣ 获取 / 更新源码（自动 stash）
####################################
if [ ! -d "$IW_DIR/.git" ]; then
    echo "[+] clone immortalwrt"
    git clone https://github.com/immortalwrt/immortalwrt.git "$IW_DIR"
else
    echo "[+] update immortalwrt"
    cd "$IW_DIR"
    if [ -n "$(git status --porcelain)" ]; then
        echo "[!] Local changes detected, auto stash"
        git stash save "auto-stash-before-build"
        git pull --rebase
        git stash pop || true
    else
        git pull --rebase
    fi
fi

cd "$IW_DIR"

####################################
# 2️⃣ 强制锁 odhcpd / odhcp6c 版本
####################################
fix_makefile() {
    local file=$1
    local date=$2
    local ver=$3
    local hash=$4
    grep -q "$ver" "$file" && return 0
    echo "[!] fix $file"
    sed -i "s/^PKG_SOURCE_DATE:=.*/PKG_SOURCE_DATE:=$date/" "$file"
    sed -i "s/^PKG_SOURCE_VERSION:=.*/PKG_SOURCE_VERSION:=$ver/" "$file"
    sed -i "s/^PKG_MIRROR_HASH:=.*/PKG_MIRROR_HASH:=$hash/" "$file"
}

fix_makefile \
    package/network/services/odhcpd/Makefile \
    2025-10-26 \
    fc27940fe9939f99aeb988d021c7edfa54460123 \
    acb086731fd7d072ddddc1d5f3bad9377e89a05597ce004d24bd0cdb60586f0a

fix_makefile \
    package/network/ipv6/odhcp6c/Makefile \
    2025-10-21 \
    77e1ae21e67f81840024ffe5bb7cf69a8fb0d2f0 \
    78f1c2342330da5f6bf08a4be89df1d771661966bbff13bd0cdb60586f0

####################################
# 3️⃣ feeds + QModem
####################################
grep -q "src-git qmodem" feeds.conf.default || \
echo "src-git qmodem https://github.com/FUjr/QModem.git;main" >> feeds.conf.default

echo "[+] feeds update"
./scripts/feeds update -a
./scripts/feeds install -a
./scripts/feeds update qmodem
./scripts/feeds install -a -p qmodem
./scripts/feeds install -a -f -p qmodem

####################################
# 4️⃣ 屏幕驱动检测
####################################
mkdir -p package/zz
for pkg in kmod-fb-tft-gc9307 xgp-v3-screen; do
    if [ ! -d "package/zz/$pkg/.git" ]; then
        echo "[+] clone $pkg"
        git clone https://github.com/zzzz0317/$pkg.git package/zz/$pkg
    else
        echo "[=] update package/zz/$pkg"
        cd package/zz/$pkg && git pull && cd -
    fi
done

####################################
# 5️⃣ 自定义插件检测（tailscale / easytier / lucky）
####################################
mkdir -p package/custom

TAILSCALE_MAKEFILE="feeds/packages/net/tailscale/Makefile"

for pkg_name repo url in \
    "luci-app-tailscale https://github.com/asvow/luci-app-tailscale.git" \
    "luci-app-easytier https://github.com/EasyTier/luci-app-easytier.git" \
    "lucky https://github.com/sirpdboy/luci-app-lucky.git"
do
    if [ ! -d "package/$pkg_name/.git" ]; then
        echo "[+] clone $pkg_name"
        git clone $repo package/$pkg_name
    else
        echo "[=] update $pkg_name"
        cd package/$pkg_name && git pull && cd -
    fi
done

# tailscale Makefile 替换
if [ -f "$TAILSCALE_MAKEFILE" ]; then
    sed -i '/\/etc\/init\.d\/tailscale/d;/\/etc\/config\/tailscale/d;' "$TAILSCALE_MAKEFILE"
fi

####################################
# 6️⃣ 准备 files
####################################
mkdir -p files/etc files/etc/config files/etc/uci-defaults files/etc/udev/rules.d files/usr/bin

####################################
# 7️⃣ QModem 默认配置
####################################
cp feeds/qmodem/application/qmodem/files/etc/config/qmodem files/etc/config/qmodem
cat >> files/etc/config/qmodem <<'EOF'
config global
    option keep_config '1'
EOF

####################################
# 8️⃣ 首次开机初始化
####################################
cat > files/etc/uci-defaults/99-firstboot <<'EOF'
#!/bin/sh
uci set system.@system[0].hostname='zzXGP'
uci commit system
uci set network.lan.ipaddr='10.0.11.1'
uci commit network

for radio in $(uci show wireless | grep "=wifi-device" | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.$radio.country='US'
    best_channel=$(iwlist $radio scan | awk -F: '/Channel/ {print $2}' | sort | uniq | head -n1)
    uci set wireless.$radio.channel="$best_channel"
    idx=$(echo $radio | tr -cd 0-9)
    iface="default_radio$idx"
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

####################################
# 9️⃣ QModem slot 热插 + mwan3
####################################
cat > files/etc/udev/rules.d/99-qmodem.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1199", RUN+="/usr/bin/qmodem-hotplug.sh pci %p"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0x1199", RUN+="/usr/bin/qmodem-hotplug.sh usb %p"
EOF

cat > files/usr/bin/qmodem-hotplug.sh <<'EOF'
#!/bin/sh
TYPE=$1
SLOT=$2
[ -f /etc/config/qmodem ] || exit 0
uci add qmodem modem-slot
uci set qmodem.@modem-slot[-1].type="$TYPE"
uci set qmodem.@modem-slot[-1].slot="$SLOT"
uci commit qmodem
uci add mwan3.interface
uci set mwan3.@interface[-1].enabled='1'
uci set mwan3.@interface[-1].interface='wwan'
uci commit mwan3
EOF
chmod +x files/usr/bin/qmodem-hotplug.sh

####################################
# 🔟 .config
####################################
[ -f .config ] || make defconfig

####################################
# 1️⃣1️⃣ download + build
####################################
set +e
make download -j$(nproc) V=s 2>&1 | tee "$BUILD_LOG"
make -j$(nproc) V=s 2>&1 | tee -a "$BUILD_LOG"
ret=$?
set -e

if [ $ret -ne 0 ]; then
    echo "❌ BUILD FAILED"
    grep -n "error:" "$BUILD_LOG" | head -n 1
    exit 1
fi

echo "✅ BUILD SUCCESS"
