#!/usr/bin/env bash

if [[ $EUID -ne 0 ]]; then
    echo "错误：请先切换到 root 用户再运行（执行 sudo -i 后重试）。"
    exit 1
fi

cat << 'SCRIPT_EOF' > /usr/local/bin/xm
#!/usr/bin/env bash

CONFIG_FILE="/usr/local/etc/xray/config.json"
ENV_FILE="/usr/local/etc/xray/reality.env"
SNI="aws.amazon.com"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：请先使用 root 用户运行（执行 sudo -i 后重试）。${NC}"
        exit 1
    fi
}

ensure_curl() {
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${CYAN}正在补装基础下载工具 curl...${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1 && apt-get install -y curl >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl >/dev/null 2>&1
        fi
    fi
}

gen_credentials() {
    UUID=$(xray uuid)
    local keys
    keys=$(xray x25519)
    PRIVATE_KEY=$(echo "$keys" | awk -F':' 'NR==1 {print $2}' | tr -d ' \r\n')
    PUBLIC_KEY=$(echo "$keys" | awk -F':' 'NR==2 {print $2}' | tr -d ' \r\n')
    SHORT_ID=$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')
}

save_and_apply() {
    mkdir -p /usr/local/etc/xray
    cat << EOF > "$ENV_FILE"
PORT="${PORT}"
UUID="${UUID}"
PRIVATE_KEY="${PRIVATE_KEY}"
PUBLIC_KEY="${PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
EOF

    cat << EOF > "$CONFIG_FILE"
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

    if ! xray run -test -c "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${RED}配置检测失败：${NC}"
        xray run -test -c "$CONFIG_FILE"
        return 1
    fi

    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray
    sleep 1

    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}配置已生效，Xray 运行正常。${NC}"
        return 0
    else
        echo -e "${RED}Xray 启动失败，请通过菜单选项 5 查看日志。${NC}"
        return 1
    fi
}

install_node() {
    ensure_curl
    echo -e "\n${CYAN}=== 安装 / 重装 Xray 节点 ===${NC}"
    read -rp "请输入监听端口 [默认 443]: " input_port
    PORT=${input_port:-443}

    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo -e "${RED}端口号无效（需为 1-65535）。${NC}"
        return
    fi

    echo -e "${CYAN}正在安装最新版 Xray-core 内核...${NC}"
    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1

    gen_credentials
    if save_and_apply; then
        show_info
    fi
}

show_info() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}未检测到节点配置，请先执行选项 1 安装。${NC}"
        return
    fi
    source "$ENV_FILE"

    local ip formatted_ip
    ip=$(curl -s4m 5 https://api.ipify.org || curl -s4m 5 https://ifconfig.me || curl -s6m 5 https://api64.ipify.org)
    if [[ "$ip" == *":"* ]]; then
        formatted_ip="[${ip}]"
    else
        formatted_ip="${ip}"
    fi

    local link="vless://${UUID}@${formatted_ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#VPS-AWS"

    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}当前节点信息${NC}"
    echo "============================================================"
    echo "  服务器 IP   : ${ip}"
    echo "  监听端口    : ${PORT}"
    echo "  伪装域名    : ${SNI}"
    echo "  UUID        : ${UUID}"
    echo "  Public Key  : ${PUBLIC_KEY}"
    echo "  Short ID    : ${SHORT_ID}"
    echo "------------------------------------------------------------"
    echo "  客户端导入链接（直接复制整行）："
    echo -e "  ${GREEN}${link}${NC}"
    echo "============================================================"
}

change_port() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}未检测到节点配置，请先安装。${NC}"
        return
    fi
    source "$ENV_FILE"
    echo -e "\n当前端口：${GREEN}${PORT}${NC}"
    read -rp "请输入新端口 (1-65535): " new_port

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}端口号无效。${NC}"
        return
    fi

    PORT="$new_port"
    if save_and_apply; then
        show_info
    fi
}

reset_keys() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}未检测到节点配置，请先安装。${NC}"
        return
    fi
    read -rp "确认重置 UUID、密钥与 ShortID？旧链接将立即失效 (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    source "$ENV_FILE"
    gen_credentials
    if save_and_apply; then
        show_info
    fi
}

service_menu() {
    echo -e "\n${CYAN}=== 服务管理 ===${NC}"
    echo "  1) 重启 Xray"
    echo "  2) 停止 Xray"
    echo "  3) 查看运行状态与最近日志"
    read -rp "请选择 [1-3]: " s_choice
    case "$s_choice" in
        1) systemctl restart xray && echo -e "${GREEN}已重启。${NC}" ;;
        2) systemctl stop xray && echo -e "${YELLOW}已停止。${NC}" ;;
        3)
            systemctl status xray --no-pager -l | head -n 12
            echo "--- 最近 15 条日志 ---"
            journalctl -u xray -n 15 --no-pager
            ;;
        *) echo "无效选项。" ;;
    esac
}

update_xray() {
    ensure_curl
    echo -e "${CYAN}正在更新 Xray-core 内核...${NC}"
    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    systemctl restart xray
    echo -e "${GREEN}更新完成，当前版本：$(xray version | head -n 1)${NC}"
}

uninstall_all() {
    read -rp "确认彻底卸载 Xray 并删除所有配置、日志及 xm 脚本？(y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    systemctl stop xray >/dev/null 2>&1
    systemctl disable xray >/dev/null 2>&1
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
    rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
    systemctl daemon-reload >/dev/null 2>&1

    rm -f /usr/local/bin/xray
    rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
    rm -f /usr/local/bin/xm

    echo -e "${GREEN}已本地彻底清理卸载，VPS 中无任何节点残留文件或进程。${NC}"
    exit 0
}

check_root

while true; do
    if systemctl is-active --quiet xray 2>/dev/null; then
        STATUS="${GREEN}运行中${NC}"
    else
        STATUS="${RED}未运行${NC}"
    fi

    echo ""
    echo "=========================================="
    echo -e "  Xray 极简维护面板  [状态: ${STATUS}]"
    echo "=========================================="
    echo "  1. 安装 / 重装节点"
    echo "  2. 查看节点信息与导入链接"
    echo "  3. 修改监听端口"
    echo "  4. 重置 UUID 与密钥"
    echo "  5. 服务管理 (重启 / 日志)"
    echo "  6. 更新 Xray 内核"
    echo "  7. 彻底卸载"
    echo "  0. 退出"
    echo "=========================================="
    read -rp "请选择 [0-7]: " choice

    case "$choice" in
        1) install_node ;;
        2) show_info ;;
        3) change_port ;;
        4) reset_keys ;;
        5) service_menu ;;
        6) update_xray ;;
        7) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}请输入 0-7 之间的数字。${NC}" ;;
    esac
done
SCRIPT_EOF

chmod +x /usr/local/bin/xm
exec /usr/local/bin/xm </dev/tty
