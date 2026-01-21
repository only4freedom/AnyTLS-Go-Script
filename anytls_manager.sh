#!/bin/bash

# =========================================================
# AnyTLS-Go 服务端一键管理脚本 (适配 v0.0.12+)
# 功能: 安装/卸载/管理/二维码/自签证书自动配置
# =========================================================

# --- 全局配置 ---
# 注意: 请确保此版本号在 GitHub Releases 中存在
ANYTLS_VERSION="0.0.12" 
# 项目发布地址 (根据实际情况调整，默认使用 zimolab 或官方源)
DOWNLOAD_BASE_URL="https://github.com/zimolab/anytls-go/releases/download"

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

# 检查是否为 Root
check_root() {
    if [ $EUID -ne 0 ]; then
        echo -e "${RED}错误: 请使用 sudo 或 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
}

# 检查命令依赖
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

# 获取公网 IP (多接口容错)
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

    # 3. 下载文件 (v0.0.12 通常是单二进制文件)
    # URL 格式示例: anytls-go-linux-amd64
    DOWNLOAD_URL="${DOWNLOAD_BASE_URL}/v${ANYTLS_VERSION}/anytls-go-linux-${DOWNLOAD_ARCH}"
    
    echo -e "${YELLOW}正在下载核心文件...${PLAIN}"
    rm -f "${SERVER_BINARY_PATH}" # 清理旧文件
    wget -O "${SERVER_BINARY_PATH}" "${DOWNLOAD_URL}"

    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败！请检查网络或版本号。${PLAIN}"
        exit 1
    fi
    chmod +x "${SERVER_BINARY_PATH}"

    # 4. 生成证书 (v0.0.12 必需)
    mkdir -p "${CONFIG_DIR}"
    if [[ ! -f "${CERT_FILE}" ]]; then
        echo -e "${YELLOW}正在生成自签名证书...${PLAIN}"
        # 生成有效期 10 年的自签证书，CN 设为常见域名混淆
        openssl req -newkey rsa:2048 -nodes -keyout "${KEY_FILE}" -x509 -days 3650 -out "${CERT_FILE}" -subj "/CN=www.microsoft.com" 2>/dev/null
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
# 关键改动: 增加 -c 和 -k 参数加载证书
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
        echo -e "${RED}服务启动失败！请运行 'journalctl -u ${SERVICE_NAME} -n 20' 查看日志。${PLAIN}"
    fi
}

do_uninstall() {
    check_root
    echo -e "${YELLOW}正在卸载 AnyTLS...${PLAIN}"
    systemctl stop "${SERVICE_NAME}"
    systemctl disable "${SERVICE_NAME}"
    rm -f "${SERVICE_FILE}"
    rm -f "${SERVER_BINARY_PATH}"
    # 可选：询问是否保留配置文件
    # rm -rf "${CONFIG_DIR}" 
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

show_info() {
    local port=$1
    local password=$2
    
    # 如果没传参数，尝试从运行中的进程或配置里读 (简化处理，若未传则提示手动查看)
    if [[ -z "$port" ]]; then
        # 尝试从 systemd 文件解析
        if [[ -f "$SERVICE_FILE" ]]; then
            port=$(grep -oP ' -l :\K\d+' "$SERVICE_FILE")
            # 提取引号内的密码
            password=$(grep -oP ' -p "\K[^"]+' "$SERVICE_FILE")
        else
            echo -e "${RED}未找到安装配置。${PLAIN}"
            return
        fi
    fi

    local ip=$(get_public_ip)
    # v0.0.12 标准链接格式
    local link="anytls://${password}@${ip}:${port}"
    # 兼容 Shadowrocket/NekoBox 的备注
    local link_remarks="${link}#AnyTLS_${port}"

    echo -e ""
    echo -e "========================================"
    echo -e "       AnyTLS v${ANYTLS_VERSION} 配置信息"
    echo -e "========================================"
    echo -e " IP地址 : ${GREEN}${ip}${PLAIN}"
    echo -e " 端口   : ${GREEN}${port}${PLAIN}"
    echo -e " 密码   : ${GREEN}${password}${PLAIN}"
    echo -e " 证书   : ${CERT_FILE} (自签)"
    echo -e "========================================"
    echo -e " 快速链接 (复制到 Shadowrocket / NekoBox / v2rayN):"
    echo -e " ${YELLOW}${link}${PLAIN}"
    echo -e "========================================"
    echo -e " 二维码:"
    qrencode -t ANSIUTF8 "${link_remarks}"
    echo -e ""
}

# --- 菜单管理 ---

show_menu() {
    echo -e "AnyTLS-Go 管理脚本 ${YELLOW}[v${ANYTLS_VERSION}]${PLAIN}"
    echo "--------------------------------"
    echo -e "1. 安装 / 更新 AnyTLS"
    echo -e "2. 卸载 AnyTLS"
    echo -e "3. 启动服务"
    echo -e "4. 停止服务"
    echo -e "5. 重启服务"
    echo -e "6. 查看配置与二维码"
    echo -e "7. 查看运行日志"
    echo "--------------------------------"
    echo -e "0. 退出脚本"
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
        *) echo -e "${RED}请输入正确的数字 [0-7]${PLAIN}" ;;
    esac
}

# --- 入口处理 ---

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
