#!/bin/bash

# =========================================================
# AnyTLS-Go 服务端一键管理脚本 (v0.0.12 修正版)
# 修复: 下载链接格式、Zip解压逻辑
# =========================================================

# --- 全局配置 ---
ANYTLS_VERSION="0.0.12"
DOWNLOAD_BASE_URL="https://github.com/anytls/anytls-go/releases/download"

# 路径配置
BIN_DIR="/usr/local/bin"
SERVER_BINARY_NAME="anytls-server"
SERVER_BINARY_PATH="${BIN_DIR}/${SERVER_BINARY_NAME}"
CONFIG_DIR="/etc/anytls"
CERT_FILE="${CONFIG_DIR}/server.crt"
KEY_FILE="${CONFIG_DIR}/server.key"
SERVICE_NAME="anytls"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TEMP_DIR="/tmp/anytls_install"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# --- 核心工具函数 ---

check_root() {
    if [ $EUID -ne 0 ]; then
        echo -e "${RED}错误: 请使用 sudo 或 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
}

check_deps() {
    # 既然是zip包，必须安装 unzip
    local deps=("wget" "openssl" "curl" "qrencode" "unzip")
    local need_install=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            need_install+=("$dep")
        fi
    done

    if [ ${#need_install[@]} -gt 0 ]; then
        echo -e "${YELLOW}正在安装依赖: ${need_install[*]} ...${PLAIN}"
        if [ -x "$(command -v apt)" ]; then
            apt update -qq && apt install -y -qq "${need_install[@]}"
        elif [ -x "$(command -v yum)" ]; then
            yum install -y -q "${need_install[@]}"
        elif [ -x "$(command -v dnf)" ]; then
            dnf install -y -q "${need_install[@]}"
        else
            echo -e "${RED}无法自动安装依赖，请手动安装: ${need_install[*]}${PLAIN}"
            exit 1
        fi
    fi
}

get_public_ip() {
    local ip=$(curl -s4m5 https://api.ipify.org)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s4m5 https://ipinfo.io/ip)
    fi
    if [[ -z "$ip" ]]; then
        ip=$(curl -s4m5 https://ifconfig.me)
    fi
    echo "$ip"
}

# --- 功能函数 ---

do_install() {
    check_root
    check_deps

    echo -e "${GREEN}>>> 开始安装 AnyTLS v${ANYTLS_VERSION}...${PLAIN}"

    # 1. 架构检测
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) DOWNLOAD_ARCH="amd64" ;;
        aarch64|arm64) DOWNLOAD_ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    # 2. 用户配置
    read -p "请输入监听端口 [默认 443]: " PORT
    [[ -z "${PORT}" ]] && PORT="443"

    read -p "请输入连接密码 [留空随机]: " PASSWORD
    [[ -z "${PASSWORD}" ]] && PASSWORD=$(openssl rand -base64 16)

    # 3. 下载文件 (修复为 zip 格式)
    # 格式: anytls_0.0.12_linux_amd64.zip
    FILENAME="anytls_${ANYTLS_VERSION}_linux_${DOWNLOAD_ARCH}.zip"
    DOWNLOAD_URL="${DOWNLOAD_BASE_URL}/v${ANYTLS_VERSION}/${FILENAME}"
    
    echo -e "${YELLOW}正在下载: ${DOWNLOAD_URL}${PLAIN}"
    
    mkdir -p "${TEMP_DIR}"
    rm -f "${TEMP_DIR}/${FILENAME}"
    
    wget -O "${TEMP_DIR}/${FILENAME}" "${DOWNLOAD_URL}"

    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败！请检查网络。${PLAIN}"
        rm -rf "${TEMP_DIR}"
        exit 1
    fi

    echo -e "${YELLOW}正在解压...${PLAIN}"
    unzip -o "${TEMP_DIR}/${FILENAME}" -d "${TEMP_DIR}" >/dev/null

    # 查找解压后的 anytls-server 二进制文件
    # 有时候解压出来可能在子目录，这里进行查找
    EXTRACTED_BIN=$(find "${TEMP_DIR}" -type f -name "anytls-server" | head -n 1)

    if [[ -z "${EXTRACTED_BIN}" ]]; then
        echo -e "${RED}错误: 解压后未找到 'anytls-server' 文件。${PLAIN}"
        ls -R "${TEMP_DIR}" # 调试用：列出文件结构
        rm -rf "${TEMP_DIR}"
        exit 1
    fi

    # 停止旧服务并移动新文件
    systemctl stop "${SERVICE_NAME}" 2>/dev/null
    mv "${EXTRACTED_BIN}" "${SERVER_BINARY_PATH}"
    chmod +x "${SERVER_BINARY_PATH}"
    rm -rf "${TEMP_DIR}"

    echo -e "${GREEN}AnyTLS 核心安装成功。${PLAIN}"

    # 4. 生成证书 (v0.0.12 必需)
    mkdir -p "${CONFIG_DIR}"
    if [[ ! -f "${CERT_FILE}" ]]; then
        echo -e "${YELLOW}正在生成自签名证书 (CN=www.bing.com)...${PLAIN}"
        openssl req -newkey rsa:2048 -nodes -keyout "${KEY_FILE}" -x509 -days 3650 -out "${CERT_FILE}" -subj "/CN=www.bing.com" 2>/dev/null
    else
        echo -e "${GREEN}检测到已有证书，保留原配置。${PLAIN}"
    fi

    # 5. 配置 Systemd
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=AnyTLS Server (v${ANYTLS_VERSION})
After=network.target

[Service]
Type=simple
User=root
# 启动参数: 端口(-l), 密码(-p), 证书(-c), 私钥(-k)
ExecStart=${SERVER_BINARY_PATH} -l :${PORT} -p "${PASSWORD}" -c ${CERT_FILE} -k ${KEY_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    # 6. 启动服务
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}"

    sleep 2
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        show_info "${PORT}" "${PASSWORD}"
    else
        echo -e "${RED}服务启动失败！${PLAIN}"
        echo -e "请运行: journalctl -u ${SERVICE_NAME} -n 20 --no-pager 查看原因"
    fi
}

do_uninstall() {
    check_root
    echo -e "${YELLOW}正在卸载 AnyTLS...${PLAIN}"
    systemctl stop "${SERVICE_NAME}" 2>/dev/null
    systemctl disable "${SERVICE_NAME}" 2>/dev/null
    rm -f "${SERVICE_FILE}"
    rm -f "${SERVER_BINARY_PATH}"
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成 (保留了配置文件 ${CONFIG_DIR})${PLAIN}"
}

show_info() {
    local port=$1
    local password=$2
    
    if [[ -z "$port" ]]; then
        if [[ -f "$SERVICE_FILE" ]]; then
            port=$(grep -oP ' -l :\K\d+' "$SERVICE_FILE")
            password=$(grep -oP ' -p "\K[^"]+' "$SERVICE_FILE")
        else
            echo -e "${RED}未找到安装配置。${PLAIN}"
            return
        fi
    fi

    local ip=$(get_public_ip)
    # v0.0.12 标准链接
    local link="anytls://${password}@${ip}:${port}"
    local link_remarks="${link}#AnyTLS_${port}"

    echo -e ""
    echo -e "========================================"
    echo -e "       AnyTLS v${ANYTLS_VERSION} 安装成功"
    echo -e "========================================"
    echo -e " IP地址 : ${GREEN}${ip}${PLAIN}"
    echo -e " 端口   : ${GREEN}${port}${PLAIN}"
    echo -e " 密码   : ${GREEN}${password}${PLAIN}"
    echo -e " 证书   : ${CERT_FILE}"
    echo -e "========================================"
    echo -e " 客户端链接 (复制):"
    echo -e " ${YELLOW}${link}${PLAIN}"
    echo -e "========================================"
    echo -e " 二维码:"
    qrencode -t ANSIUTF8 "${link_remarks}"
    echo -e ""
}

show_menu() {
    echo -e "AnyTLS-Go 管理脚本 (v${ANYTLS_VERSION})"
    echo "--------------------------------"
    echo -e "1. 安装 / 更新"
    echo -e "2. 卸载"
    echo -e "3. 启动服务"
    echo -e "4. 停止服务"
    echo -e "5. 重启服务"
    echo -e "6. 查看配置与二维码"
    echo -e "7. 查看日志"
    echo "--------------------------------"
    echo -e "0. 退出"
    echo ""
    read -p "请输入选项 [0-7]: " num

    case "$num" in
        1) do_install ;;
        2) do_uninstall ;;
        3) systemctl start "${SERVICE_NAME}" && echo -e "${GREEN}已启动${PLAIN}" ;;
        4) systemctl stop "${SERVICE_NAME}" && echo -e "${GREEN}已停止${PLAIN}" ;;
        5) systemctl restart "${SERVICE_NAME}" && echo -e "${GREEN}已重启${PLAIN}" ;;
        6) show_info ;;
        7) journalctl -u "${SERVICE_NAME}" -f -n 50 ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}" ;;
    esac
}

if [[ $# > 0 ]]; then
    case $1 in
        "install") do_install ;;
        "uninstall") do_uninstall ;;
        "info"|"qr") show_info ;;
        "log") journalctl -u "${SERVICE_NAME}" -f ;;
        *) show_menu ;;
    esac
else
    show_menu
fi
