#!/bin/bash

SITES_DIR="/etc/caddy/sites"
MAIN_CONFIG="/etc/caddy/Caddyfile"

init_env() {
apt update -y
apt install -y curl sudo ufw

ufw allow 80
ufw allow 443
ufw --force enable

# BBR检测
if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
fi

# 安装Caddy
apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
apt update -y
apt install -y caddy

mkdir -p $SITES_DIR

# 主配置
cat > $MAIN_CONFIG <<EOF
{
    servers {
        protocol {
            experimental_http3
        }
    }
}

import $SITES_DIR/*.conf
EOF

systemctl enable caddy
systemctl restart caddy
}

add_site() {

read -p "域名 (如 emby1.xxx.com): " domain
read -p "源IP: " upstream_ip
read -p "源端口 (默认8096): " upstream_port
read -p "监听端口 (默认443): " listen_port

upstream_port=${upstream_port:-8096}
listen_port=${listen_port:-443}

fake_title=$(shuf -n 1 -e "Tech Notes" "Cloud Blog" "Dev Journal" "Personal Space")

cat > $SITES_DIR/$domain.conf <<EOF
http://$domain {
    redir https://$domain$request_uri
}

https://$domain:$listen_port {

    encode gzip zstd

    header {
        -Server
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin"
    }

    @root path /
    handle @root {
        respond "<html><head><title>$fake_title</title></head><body><h1>$fake_title</h1></body></html>" 200
    }

    handle {
        reverse_proxy $upstream_ip:$upstream_port {
            flush_interval -1
            transport http {
                keepalive 64
            }
        }
    }

    tls {
        protocols tls1.2 tls1.3
    }
}
EOF

ufw allow $listen_port
systemctl reload caddy

echo "站点 $domain 添加完成"
}

list_sites() {
echo "当前站点："
ls $SITES_DIR | sed 's/.conf//g'
}

delete_site() {
read -p "输入要删除的域名: " domain
rm -f $SITES_DIR/$domain.conf
systemctl reload caddy
echo "站点已删除"
}

uninstall_all() {
systemctl stop caddy
apt purge -y caddy
rm -rf /etc/caddy
rm -rf /var/lib/caddy
echo "已彻底卸载"
exit 0
}

menu() {
clear
echo "======================================="
echo "        Caddy反代脚本 v5.0"
echo "======================================="
echo "1. 初始化环境"
echo "2. 添加Emby站点"
echo "3. 列出所有站点"
echo "4. 删除某个站点"
echo "5. 重载Caddy"
echo "6. 查看实时日志"
echo "7. 卸载全部"
echo "0. 退出"
echo "======================================="
read -p "请选择: " num

case "$num" in
1) init_env ;;
2) add_site ;;
3) list_sites ;;
4) delete_site ;;
5) systemctl reload caddy ;;
6) journalctl -u caddy -f ;;
7) uninstall_all ;;
0) exit 0 ;;
*) echo "输入错误"; sleep 1 ;;
esac
}

while true
do
menu
done
