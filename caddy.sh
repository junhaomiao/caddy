ht#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

SITES_DIR="/etc/caddy/sites"
MAIN_CONFIG="/etc/caddy/Caddyfile"
SCRIPT_PATH="/usr/bin/cm"

# [核心逻辑] 自动把自己安装到系统，实现快捷键 cm
install_self() {
    if [[ ! -f "$SCRIPT_PATH" ]]; then
        # 如果当前不是从 /usr/bin/cm 运行的，则下载并保存
        curl -sL https://raw.githubusercontent.com/haojunmiao/caddy/main/caddy.sh -o $SCRIPT_PATH
        chmod +x $SCRIPT_PATH
        echo -e "${GREEN}快捷方式已创建！以后直接输入 'cm' 即可呼出菜单。${PLAIN}"
    fi
}

# 端口占用清理
check_port_usage() {
    local port=$1
    if ! command -v lsof &> /dev/null; then apt update -y && apt install -y lsof psmisc > /dev/null 2>&1; fi
    local pid=$(lsof -t -i:$port 2>/dev/null)
    if [ -n "$pid" ]; then
        echo -e "${YELLOW}[!] 端口 $port 被占用，正在自动清理...${PLAIN}"
        fuser -k $port/tcp > /dev/null 2>&1
        sleep 1
    fi
}

init_env() {
    echo -e "${BLUE}=== 正在初始化 (BBR/Caddy/内核优化) ===${PLAIN}"
    
    # 内核优化
    cat > /etc/sysctl.d/99-emby.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system > /dev/null 2>&1

    # 安装 Caddy
    apt update -y && apt install -y curl sudo ufw debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
    apt update -y && apt install -y caddy

    mkdir -p $SITES_DIR
    echo -e "{\n    servers {\n        protocol {\n            experimental_http3\n        }\n    }\n}\nimport $SITES_DIR/*.conf" > $MAIN_CONFIG
    
    systemctl enable caddy && systemctl restart caddy
    echo -e "${GREEN}环境初始化成功！${PLAIN}"
    sleep 2
}

add_site() {
    read -p "请输入域名: " domain
    read -p "后端IP (默认127.0.0.1): " upstream_ip
    upstream_ip=${upstream_ip:-127.0.0.1}
    read -p "后端端口 (如8880): " upstream_port
    read -p "外部端口 (默认443): " listen_port
    listen_port=${listen_port:-443}

    check_port_usage $listen_port

    cat > $SITES_DIR/$domain.conf <<EOF
$domain:$listen_port {
    encode zstd gzip
    reverse_proxy $upstream_ip:$upstream_port {
        flush_interval -1
        header_up Host {host}
        header_up X-Real-IP {remote_host}
    }
    tls {
        protocols tls1.2 tls1.3
    }
}
EOF

    ufw allow $listen_port/tcp > /dev/null 2>&1
    [[ "$upstream_ip" == "127.0.0.1" ]] && ufw deny $upstream_port/tcp > /dev/null 2>&1

    if caddy validate --config $MAIN_CONFIG > /dev/null 2>&1; then
        systemctl reload caddy
        clear
        echo -e "${GREEN}=======================================${PLAIN}"
        echo -e "${BLUE}节点部署成功！${PLAIN}"
        echo -e "🔗 访问链接: ${GREEN}https://$domain:$listen_port${PLAIN}"
        echo -e "${GREEN}=======================================${PLAIN}"
        echo ""
        read -p "按回车返回菜单..."
    fi
}

menu() {
    clear
    echo -e "${BLUE}Caddy 管理器 (快捷键: cm)${PLAIN}"
    echo "1. 环境初始化 (初次使用请先点此项)"
    echo "2. 添加反代站点"
    echo "3. 删除反代站点"
    echo "4. 查看实时日志"
    echo "0. 退出"
    read -p "请选择: " num
    case "$num" in
        1) init_env ;;
        2) add_site ;;
        3) read -p "输入域名: " d; rm -f $SITES_DIR/$d.conf; systemctl reload caddy; echo "已删除" ;;
        4) journalctl -u caddy -f ;;
        0) exit 0 ;;
    esac
}

# --- 脚本入口 ---
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请以 root 运行。${PLAIN}" && exit 1
install_self  # 每次运行都检查并安装快捷方式
while true; do menu; done
