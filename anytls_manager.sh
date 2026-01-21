#!/bin/bash

# =========================================================
# AnyTLS-Go 服务端一键管理脚本 (官方源修正版)
# 适配版本: v0.0.12
# 仓库地址: https://github.com/anytls/anytls-go
# =========================================================

# --- 全局配置 ---
ANYTLS_VERSION="0.0.12"
# 修正为官方仓库地址
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
    local deps=("wget" "openssl" "curl" "qrencode")
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

    echo -e "${GREEN}>>> 开始安装 AnyTLS v${ANYTLS_VERSION} (官方源)...${PLAIN}"

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

    # 3. 下载文件
    # 注意: v0.0.12 官方Release通常直接提供二进制文件: anytls-go-linux-amd64
    # 如果下载失败，可能是官方改回了 .tar.gz 格式，这里优先尝试二进制
    DOWNLOAD_URL="${DOWNLOAD_BASE_URL}/v${ANYTLS_VERSION}/anytls-go-linux-${DOWNLOAD_ARCH}"
    
    echo -e "${YELLOW}正在下载核心文件: ${DOWNLOAD_URL}${PLAIN}"
    rm -f "${SERVER_BINARY_PATH}" # 清理旧文件
    
    wget -O "${SERVER_BINARY_PATH}" "${DOWNLOAD_URL}"

    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败！${PLAIN}"
        echo -e "${YELLOW}尝试下载 tar.gz 格式...${PLAIN}"
        # 备用方案：如果官方发布的是 tar.gz 包
        wget -O "/tmp/anytls.tar.gz" "${DOWNLOAD_BASE_URL}/v${ANYTLS_VERSION}/anytls-go_${ANYTLS_VERSION}_linux_${DOWNLOAD_ARCH}.tar.gz"
        if [ $? -eq 0 ]; then
             tar -zxvf "/tmp/anytls.tar.gz" -C "/tmp/" anytls-go
             mv "/tmp/anytls-go" "${SERVER_BINARY_PATH}"
             rm "/tmp/anytls.tar.gz"
        else
             echo -e "${RED}无法下载文件，请检查 GitHub 连接或版本号。${PLAIN}"
             exit 1
        fi
    fi
    
    chmod +x "${SERVER_BINARY_PATH}"
    echo -e "${GREEN}核心文件安装成功。${PLAIN}"

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
# v0.0.12 必须指定证书 (-c) 和私钥 (-k)
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
        echo -e "请运行以下命令查看详细错误日志："
        echo -e "${YELLOW}journalctl -u ${SERVICE_NAME} -n 20 --no-pager${PLAIN}"
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
    echo -e "${GREEN}卸载完成。(配置文件保留在 ${CONFIG_DIR})${PLAIN}"
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
    # v0.0.12 标准链接格式 anytls://密码@IP:端口
    local link="anytls://${password}@${ip}:${port}"
    local link_remarks="${link}#AnyTLS_${port}"

    echo -e ""
    echo -e "========================================"
    echo -e "       AnyTLS v${ANYTLS_VERSION} 安装成功"
    echo -e "========================================"
    echo -e " IP地址 : ${GREEN}${ip}${PLAIN}"
    echo -e " 端口   : ${GREEN}${port}${PLAIN}"
    echo -e " 密码   : ${GREEN}${password}${PLAIN}"
    echo -e " 证书   : ${CERT_FILE} (自签)"
    echo -e "========================================"
    echo -e " 客户端配置链接 (复制):"
    echo -e " ${YELLOW}${link}${PLAIN}"
    echo -e "========================================"
    echo -e " 二维码 (Shadowrocket / NekoBox):"
    qrencode -t ANSIUTF8 "${link_remarks}"
    echo -e ""
}

# --- 菜单管理 ---

show_menu() {
    echo -e "AnyTLS-Go 管理脚本 (Official Repo)"
    echo "--------------------------------"
    echo -e "1. 安装 / 更新 AnyTLS (v${ANYTLS_VERSION})"
    echo -e "2. 卸载 AnyTLS"
    echo -e "3. 启动服务"
    echo -e "4. 停止服务"
    echo -e "5. 重启服务"
    echo -e "6. 查看配置与二维码"
    echo -e "7. 查看运行日志"
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

# --- 入口 ---

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
