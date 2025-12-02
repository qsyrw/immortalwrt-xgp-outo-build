#!/bin/bash
set -e
WORKDIR=$(pwd)
LOGFILE="$WORKDIR/immortalwrt-build.log"
echo "🔥 ImmortalWrt Auto Build"
echo "🛠 Workdir: $WORKDIR"
echo "📄 Log: $LOGFILE"

# -------------------------------
# Step 1: 获取/更新 ImmortalWrt 源码
# -------------------------------
if [ ! -d "immortalwrt" ]; then
    git clone https://github.com/immortalwrt/immortalwrt.git immortalwrt
else
    cd immortalwrt
    git reset --hard
    git clean -fd
    git pull
    cd ..
fi

# -------------------------------
# Step 2: 检查/拉取插件
# -------------------------------
declare -A PLUGINS
PLUGINS=(
    [tailscale]="https://github.com/asvow/luci-app-tailscale.git package/luci-app-tailscale"
    [easytier]="https://github.com/EasyTier/luci-app-easytier.git package/luci-app-easytier"
    [lucky]="https://github.com/sirpdboy/luci-app-lucky.git package/lucky"
    [kmod-fb-tft-gc9307]="https://github.com/zzzz0317/kmod-fb-tft-gc9307.git package/zz/kmod-fb-tft-gc9307"
    [xgp-v3-screen]="https://github.com/zzzz0317/xgp-v3-screen.git package/zz/xgp-v3-screen"
)

for key in "${!PLUGINS[@]}"; do
    url_path=(${PLUGINS[$key]})
    URL=${url_path[0]}
    PATH_DIR=${url_path[1]}
    if [ ! -d "$PATH_DIR" ]; then
        echo "[+] Clone $key"
        git clone --depth=1 "$URL" "$PATH_DIR"
    else
        echo "[=] Update $key"
        cd "$PATH_DIR"
        git reset --hard
        git pull
        cd "$WORKDIR"
    fi
done

# -------------------------------
# Step 3: 检查 odhcpd/odhcp6c 版本
# -------------------------------
ODHCPD_MAKEFILE="immortalwrt/package/network/services/odhcpd/Makefile"
ODHCPD_HASH="acb086731fd7d072ddddc1d5f3bad9377e89a05597ce004d24bd0cdb60586f0a"
ODHCP6C_MAKEFILE="immortalwrt/package/network/ipv6/odhcp6c/Makefile"
ODHCP6C_HASH="78f1c2342330da5f6bf08a4be89df1d771661966bbff13bd15462035de46837b"

check_and_patch() {
    local file=$1
    local hash=$2
    if ! grep -q "$hash" "$file"; then
        echo "[!] $file 版本不匹配，替换为指定版本"
        sed -i "s|PKG_MIRROR_HASH.*|PKG_MIRROR_HASH:=$hash|g" "$file" || true
    fi
}

check_and_patch "$ODHCPD_MAKEFILE" "$ODHCPD_HASH"
check_and_patch "$ODHCP6C_MAKEFILE" "$ODHCP6C_HASH"

# -------------------------------
# Step 4: 更新 feeds 并安装 qmodem
# -------------------------------
cd immortalwrt
sed -i '/\/etc\/init\.d\/tailscale/d;/\/etc\/config\/tailscale/d;' feeds/packages/net/tailscale/Makefile
if ! grep -q "src-git qmodem" feeds.conf.default; then
    echo "src-git qmodem https://github.com/FUjr/QModem.git;main" >> feeds.conf.default
fi

./scripts/feeds update -a
./scripts/feeds install -a
./scripts/feeds install -a -f -p qmodem

# -------------------------------
# Step 5: 使用 xgp.config
# -------------------------------
CONFIG_FILE="$WORKDIR/xgp.config"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[!] xgp.config 不存在，创建空文件"
    touch "$CONFIG_FILE"
fi
cp "$CONFIG_FILE" .config

# -------------------------------
# Step 6: QModem 默认配置
# -------------------------------
mkdir -p files/etc/config
cat > files/etc/config/qmodem <<EOF
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

# -------------------------------
# Step 7: 第一次启动 LAN/WiFi 配置
# -------------------------------
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-wifi <<'EOF'
#!/bin/sh
uci set system.@system[0].hostname='zzXGP'
uci set network.lan.ipaddr='10.0.11.1'
uci commit system network

wifi_count=$(uci show wireless | grep -c "=wifi-device")
for i in $(seq 0 $((wifi_count-1))); do
    uci set wireless.default_radio${i}.ssid='zzXGP'
    uci set wireless.default_radio${i}.encryption='psk2+ccmp'
    uci set wireless.default_radio${i}.key='88888888'
    uci set wireless.radio${i}.country='US'
done
uci commit wireless
wifi
EOF

# -------------------------------
# Step 8: defconfig & build
# -------------------------------
make defconfig
echo "✅ Start build"
make download -j$(nproc)
make -j$(nproc) V=s
cd "$WORKDIR"
echo "🎉 Build complete"
