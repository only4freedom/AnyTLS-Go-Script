#!/bin/bash

# =========================================================
# AnyTLS-Go 一键安装脚本 (最终修复版)
# 适配: v0.0.12 官方版
# 修复: 移除无效参数、自动清理端口占用、Zip解压
# =========================================================

# --- 全局配置 ---
VERSION="0.0.12"
DOWNLOAD_BASE="https://github.com/anytls/anytls-go/releases/download"
BIN_PATH="/usr/local/bin/anytls-server"
SERVICE_FILE="/etc/systemd/system/anytls.service"

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# --- 1. 检查环境 ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 请使用 sudo 或 root 运行此脚本！${PLAIN}"
    exit 1
fi

echo -e "${YELLOW}正在检查并安装依赖 (unzip, wget, net-tools)...${PLAIN}"
# 安装基础工具，net-tools 用于 netstat，psmisc 用于 fuser/killall
if [ -x "$(command -v apt)" ]; then
    apt update -qq && apt install -y -qq wget curl unzip qrencode net-tools psmisc
elif [ -x "$(command -v yum)" ]; then
    yum install -y -q wget curl unzip qrencode net-tools psmisc
fi

# --- 2. 清理旧环境 (关键步骤) ---
echo -e "${YELLOW}正在清理旧版本残留...${PLAIN}"
systemctl stop anytls 2>/dev/null
systemctl stop anytls-server 2>/dev/null
systemctl disable anytls 2>/dev/null
systemctl disable anytls-server 2>/dev/null
rm -f /etc/systemd/system/anytls-server.service # 删除旧名服务
systemctl daemon-reload

# --- 3. 配置参数 ---
echo -e "------------------------------------------------"
read -p "请输入端口 [默认 8443]: " PORT
[[ -z "${PORT}" ]] && PORT="8443"

read -p "请输入密码 [回车随机生成]: " PASSWORD
[[ -z "${PASSWORD}" ]] && PASSWORD=$(openssl rand -base64 16)
echo -e "------------------------------------------------"

# --- 4. 暴力清理端口占用 (防止 bind error) ---
echo -e "${YELLOW}正在检测端口 ${PORT} 占用情况...${PLAIN}"
PID=$(lsof -t -i:${PORT} 2>/dev/null)
if [[ ! -z "$PID" ]]; then
    echo -e "${RED}发现端口 ${PORT} 被进程 (PID: $PID) 占用，正在强制释放...${PLAIN}"
    kill -9 $PID
    sleep 1
fi
# 双重保险
fuser -k ${PORT}/tcp 2>/dev/null

# --- 5. 下载并安装核心 ---
ARCH=$(uname -m)
case $ARCH in
    x86_64|amd64) FILE_ARCH="amd64" ;;
    aarch64|arm64) FILE_ARCH="arm64" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
esac

# 官方文件名格式: anytls_0.0.12_linux_amd64.zip
FILENAME="anytls_${VERSION}_linux_${FILE_ARCH}.zip"
URL="${DOWNLOAD_BASE}/v${VERSION}/${FILENAME}"

echo -e "${GREEN}正在下载 v${VERSION}...${PLAIN}"
mkdir -p /tmp/anytls_install
rm -f /tmp/anytls_install/*

wget -O "/tmp/anytls_install/${FILENAME}" "${URL}"

if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败，请检查网络连接。${PLAIN}"
    exit 1
fi

echo -e "${GREEN}正在解压...${PLAIN}"
unzip -o "/tmp/anytls_install/${FILENAME}" -d "/tmp/anytls_install/" >/dev/null

# 查找二进制文件 (防止解压目录变动)
EXTRACTED_BIN=$(find /tmp/anytls_install -type f -name "anytls-server" | head -n 1)
if [[ -z "${EXTRACTED_BIN}" ]]; then
    echo -e "${RED}错误: 解压后找不到 anytls-server 文件！${PLAIN}"
    exit 1
fi

# 移动到系统目录
mv "${EXTRACTED_BIN}" "${BIN_PATH}"
chmod +x "${BIN_PATH}"
rm -rf /tmp/anytls_install

# --- 6. 创建服务 (移除导致报错的 -c/-k 参数) ---
cat > ${SERVICE_FILE} <<EOF
[Unit]
Description=AnyTLS Server
After=network.target

[Service]
Type=simple
User=root
# 修复: 仅使用 -l 和 -p
ExecStart=${BIN_PATH} -l :${PORT} -p "${PASSWORD}"
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# --- 7. 启动 ---
systemctl daemon-reload
systemctl enable anytls
systemctl restart anytls

# --- 8. 检查状态并输出 ---
sleep 2
if systemctl is-active --quiet anytls; then
    IPV4=$(curl -s4m5 https://api.ipify.org)
    LINK="anytls://${PASSWORD}@${IPV4}:${PORT}"
    REMARKS="${LINK}#AnyTLS_${PORT}"
    
    echo -e ""
    echo -e "=========================================="
    echo -e "${GREEN} AnyTLS v${VERSION} 安装并启动成功！ ${PLAIN}"
    echo -e "=========================================="
    echo -e " IP地址 : ${IPV4}"
    echo -e " 端口   : ${PORT}"
    echo -e " 密码   : ${PASSWORD}"
    echo -e "=========================================="
    echo -e " 客户端链接 (NekoBox / Shadowrocket):"
    echo -e " ${YELLOW}${LINK}${PLAIN}"
    echo -e "=========================================="
    echo -e " 二维码:"
    qrencode -t ANSIUTF8 "${REMARKS}"
    echo -e ""
    echo -e "${YELLOW}提示: 客户端请务必勾选 [允许不安全连接 / Allow Insecure]${PLAIN}"
else
    echo -e "${RED}服务启动失败！${PLAIN}"
    echo -e "最后几行日志:"
    journalctl -u anytls -n 10 --no-pager
fi
