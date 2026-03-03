#!/bin/bash

# ====================================================
#  Caddy Emby Manager Pro - V9 (junhaomiao Edition)
# ====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

CONF_FILE="/etc/caddy/Caddyfile"
SCRIPT_PATH="/usr/bin/cm"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行！" && exit 1

# [核心逻辑] 自动把自己安装到系统，实现快捷键 cm
install_self() {
    if [[ ! -f "$SCRIPT_PATH" ]]; then
        # 从你的仓库下载自身
        curl -sL https://raw.githubusercontent.com/junhaomiao/caddy/main/caddy.sh -o $SCRIPT_PATH
        chmod +x $SCRIPT_PATH
        echo -e "${GREEN}快捷方式已创建！以后输入 'cm' 即可呼出菜单。${PLAIN}"
        sleep 1
    fi
}

log() { echo -e "${GREEN}[Info]${PLAIN} $1"; }
error() { echo -e "${RED}[Error]${PLAIN} $1"; }

install_base_caddy() {
    log "正在全自动部署环境与 Caddy..."
    apt update -y && apt install -y curl wget sudo socat psmisc sed grep debian-keyring debian-archive-keyring apt-transport-https gnupg -y
    
    # 开启 BBR
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi

    # 安装 Caddy
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt update && apt install caddy -y
    systemctl enable caddy
    log "环境初始化完成！"
    sleep 1
}

configure_caddy() {
    echo -e "${SKYBLUE}--- 添加反代站点 ---${PLAIN}"
    read -p "请输入新域名 (如 emby.junhaomiao.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && return
    read -p "后端地址 (默认 127.0.0.1:8880): " EMBY_ADDRESS
    EMBY_ADDRESS=${EMBY_ADDRESS:-"127.0.0.1:8880"}
    read -p "监听端口 (默认 443): " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-443}

    # 清理端口占用
    fuser -k $LISTEN_PORT/tcp 2>/dev/null

    # 检查域名是否已存在
    if [ -f "$CONF_FILE" ] && grep -q "$DOMAIN:$LISTEN_PORT {" "$CONF_FILE"; then
        sed -i "/^$DOMAIN:$LISTEN_PORT {/,/^}/d" "$CONF_FILE"
    fi

    # 写入配置
    cat >> "$CONF_FILE" <<EOF
$DOMAIN:$LISTEN_PORT {
    encode gzip zstd
    reverse_proxy $EMBY_ADDRESS {
        flush_interval -1
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
EOF

    # 验证并重启
    if caddy validate --config "$CONF_FILE" > /dev/null 2>&1; then
        systemctl restart caddy
        # --- 极简输出模式 ---
        clear
        echo -e "${GREEN}=======================================${PLAIN}"
        echo -e "${SKYBLUE}节点部署成功！${PLAIN}"
        echo -e "🔗 访问链接: ${GREEN}https://$DOMAIN:$LISTEN_PORT${PLAIN}"
        echo -e "${GREEN}=======================================${PLAIN}"
        echo ""
        read -p "按回车返回菜单..."
    else
        error "配置验证失败，请检查解析。"
        sleep 2
    fi
}

delete_config() {
    echo -e "${SKYBLUE}--- 删除站点 ---${PLAIN}"
    [ ! -f "$CONF_FILE" ] && error "配置不存在" && return
    
    # 提取所有域名行
    local domains=($(grep " {" "$CONF_FILE" | awk '{print $1}'))
    if [ ${#domains[@]} -eq 0 ]; then
        log "暂无站点。"
        sleep 1; return
    fi

    for i in "${!domains[@]}"; do
        echo -e " ${GREEN}$((i+1)).${PLAIN} ${domains[$i]}"
    done
    read -p "输入数字删除 (0 取消): " choice
    if [[ "$choice" -gt 0 && "$choice" -le ${#domains[@]} ]]; then
        local del_target=${domains[$((choice-1))]}
        sed -i "/^$del_target {/,/^}/d" "$CONF_FILE"
        sed -i '/^\s*$/d' "$CONF_FILE"
        systemctl reload caddy
        log "站点 $del_target 已删除。"
        sleep 1
    fi
}

# 脚本入口
install_self
while true; do
    clear
    echo -e "#################################################"
    echo -e "#    Caddy Emby 管理器 v9.0 (junhaomiao)        #"
    echo -e "#    快捷命令: cm                               #"
    echo -e "#################################################"
    echo -e " ${GREEN}1.${PLAIN} 全自动安装环境 & Caddy"
    echo -e " ${GREEN}2.${PLAIN} 添加/更新 反代配置"
    echo -e " ${GREEN}3.${PLAIN} 管理/删除 站点配置"
    echo -e " ${GREEN}4.${PLAIN} 查看当前配置文件"
    echo -e " ${GREEN}5.${PLAIN} 查看实时日志"
    echo -e "-------------------------------------------------"
    echo -e " ${RED}8.${PLAIN} 暴力清理 80/443 端口"
    echo -e " ${RED}9.${PLAIN} 彻底卸载 Caddy"
    echo -e " ${GREEN}0.${PLAIN} 退出"
    echo -e "#################################################"
    read -p " 请输入数字 [0-9]: " num

    case "$num" in
        1) install_base_caddy ;;
        2) configure_caddy ;;
        3) delete_config ;;
        4) cat "$CONF_FILE" ; read -p "回车继续..." ;;
        5) journalctl -u caddy -f ;;
        8) fuser -k 80/tcp 443/tcp 2>/dev/null; log "清理完成"; sleep 1 ;;
        9) systemctl stop caddy; apt purge caddy -y; rm -rf /etc/caddy /var/lib/caddy; rm -f $SCRIPT_PATH; log "卸载完成"; exit 0 ;;
        0) exit 0 ;;
    esac
done
