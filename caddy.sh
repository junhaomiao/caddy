#!/bin/bash

# 变量与颜色
GREEN='\033[0;32m'
BLUE='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

SITES_DIR="/etc/caddy/sites"
MAIN_CONFIG="/etc/caddy/Caddyfile"
SCRIPT_PATH="/usr/bin/cm"

# 1. 权限与依赖预检
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请以 root 运行。${PLAIN}" && exit 1

# 自动安装基础依赖
install_deps() {
    if ! command -v curl &> /dev/null || ! command -v lsof &> /dev/null; then
        apt update -y && apt install -y curl lsof psmisc ufw wget > /dev/null 2>&1
    fi
}

# 快捷方式安装
install_self() {
    if [[ ! -f "$SCRIPT_PATH" ]]; then
        # 从你的仓库下载自身
        curl -sL https://raw.githubusercontent.com/junhaomiao/caddy/main/caddy.sh -o $SCRIPT_PATH
        chmod +x $SCRIPT_PATH
    fi
}

# 端口清理逻辑 (防错：只杀非 Caddy 进程)
check_port_usage() {
    local port=$1
    local pid=$(lsof -t -i:$port 2>/dev/null)
    if [ -n "$pid" ]; then
        # 如果占用端口的不是 caddy 本身，则清理
        local pname=$(ps -p $pid -o comm=)
        if [[ "$pname" != "caddy" ]]; then
            echo -e "${YELLOW}[!] 发现端口 $port 被 $pname 占用，正在清理...${PLAIN}"
            fuser -k $port/tcp > /dev/null 2>&1
            sleep 1
        fi
    fi
}

init_env() {
    install_deps
    echo -e "${BLUE}=== 初始化环境 (BBR/Caddy/H3) ===${PLAIN}"
    
    # BBR 优化
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi

    # 安装 Caddy 官方源
    apt install -y debian-keyring debian-archive-keyring apt-transport-https > /dev/null 2>&1
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg > /dev/null 2>&1
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list > /dev/null 2>&1
    apt update -y && apt install -y caddy > /dev/null 2>&1

    mkdir -p $SITES_DIR
    echo -e "{\n    servers {\n        protocol {\n            experimental_http3\n        }\n    }\n}\nimport $SITES_DIR/*.conf" > $MAIN_CONFIG
    
    systemctl enable caddy && systemctl restart caddy
    echo -e "${GREEN}环境初始化成功！${PLAIN}"
    sleep 1
}

add_site() {
    read -p "请输入域名 (如 emby.junhaomiao.com): " domain
    if [[ -z "$domain" ]]; then return; fi
    
    read -p "后端IP (默认 127.0.0.1): " upstream_ip
    upstream_ip=${upstream_ip:-127.0.0.1}
    read -p "后端端口 (如 8880): " upstream_port
    read -p "外部访问端口 (默认 443): " listen_port
    listen_port=${listen_port:-443}

    check_port_usage $listen_port

    # 临时备份旧配置以防失败
    [[ -f "$SITES_DIR/$domain.conf" ]] && cp "$SITES_DIR/$domain.conf" "$SITES_DIR/$domain.conf.bak"

    cat > $SITES_DIR/$domain.conf <<EOF
# BACKEND:$upstream_ip:$upstream_port
$domain:$listen_port {
    encode zstd gzip
    reverse_proxy $upstream_ip:$upstream_port {
        flush_interval -1
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
    tls {
        protocols tls1.2 tls1.3
    }
}
EOF

    # 验证配置
    if caddy validate --config $MAIN_CONFIG > /dev/null 2>&1; then
        ufw allow $listen_port/tcp > /dev/null 2>&1
        [[ "$upstream_ip" == "127.0.0.1" ]] && ufw deny $upstream_port/tcp > /dev/null 2>&1
        systemctl reload caddy
        clear
        echo -e "${GREEN}=======================================${PLAIN}"
        echo -e "${BLUE}节点部署成功！${PLAIN}"
        echo -e "🔗 访问链接: ${GREEN}https://$domain:$listen_port${PLAIN}"
        echo -e "${GREEN}=======================================${PLAIN}"
        echo ""
        read -p "按回车返回菜单..."
    else
        echo -e "${RED}验证失败！可能是域名解析未生效或格式错误。${PLAIN}"
        # 回滚
        if [[ -f "$SITES_DIR/$domain.conf.bak" ]]; then
            mv "$SITES_DIR/$domain.conf.bak" "$SITES_DIR/$domain.conf"
        else
            rm -f $SITES_DIR/$domain.conf
        fi
        sleep 2
    fi
}

manage_sites() {
    clear
    echo -e "${BLUE}=== 站点管理 (junhaomiao) ===${PLAIN}"
    local files=($(ls $SITES_DIR/*.conf 2>/dev/null))
    if [ ${#files[@]} -eq 0 ]; then
        echo "暂无站点。"
        read -p "返回..."
        return
    fi

    echo -e "ID\t域名\t\t\t后端"
    echo "------------------------------------------------"
    local i=1
    for file in "${files[@]}"; do
        domain=$(basename "$file" .conf)
        info=$(grep "# BACKEND:" "$file" | cut -d':' -f2,3)
        echo -e "$i)\t$domain\t\t$info"
        ((i++))
    done
    echo "------------------------------------------------"
    read -p "输入 ID 删除，或 0 返回: " choice

    if [[ "$choice" -gt 0 && "$choice" -le ${#files[@]} ]]; then
        rm -f "${files[$((choice-1))]}"
        systemctl reload caddy
        echo -e "${GREEN}已删除。${PLAIN}"
        sleep 1
    fi
}

menu() {
    clear
    echo -e "${BLUE}Caddy 管理器 v8.1 (快捷键: cm)${PLAIN}"
    echo "1. 初始化环境"
    echo "2. 添加 Emby 反代"
    echo "3. 管理/删除 站点"
    echo "4. 查看实时日志"
    echo "0. 退出"
    read -p "请选择: " num
    case "$num" in
        1) init_env ;;
        2) add_site ;;
        3) manage_sites ;;
        4) journalctl -u caddy -f ;;
        0) exit 0 ;;
        *) menu ;;
    esac
}

# 执行入口
install_deps
install_self
while true; do menu; done
