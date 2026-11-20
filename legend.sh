#!/usr/bin/env bash

if [[ $EUID -ne 0 ]]; then
    echo "错误：请先切换到 root 用户再运行（执行 sudo -i 后重试）。"
    exit 1
fi

cat << 'SCRIPT_EOF' > /usr/local/bin/legend
#!/usr/bin/env bash

XRAY_CONFIG="/usr/local/etc/xray/config.json"
HY_DIR="/usr/local/etc/hysteria"
HY_CONFIG="${HY_DIR}/config.yaml"
ENV_FILE="/usr/local/etc/xray/node.env"
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

ensure_base_tools() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v openssl >/dev/null 2>&1 || missing+=("openssl")
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${CYAN}正在补装基础工具: ${missing[*]}...${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1 && apt-get install -y "${missing[@]}" >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "${missing[@]}" >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "${missing[@]}" >/dev/null 2>&1
        fi
    fi
}

install_hy2_binary() {
    local arch hy_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) hy_arch="amd64" ;;
        aarch64|arm64) hy_arch="arm64" ;;
        *)
            echo -e "${RED}不支持的 CPU 架构: ${arch}${NC}"
            return 1
            ;;
    esac

    curl -sL "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${hy_arch}" -o /usr/local/bin/hysteria
    chmod +x /usr/local/bin/hysteria

    cat << EOF > /etc/systemd/system/hysteria.service
[Unit]
Description=Hysteria 2 Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c ${HY_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

gen_credentials() {
    UUID=$(xray uuid)
    local keys
    keys=$(xray x25519)
    PRIVATE_KEY=$(echo "$keys" | awk -F':' 'NR==1 {print $2}' | tr -d ' \r\n')
    PUBLIC_KEY=$(echo "$keys" | awk -F':' 'NR==2 {print $2}' | tr -d ' \r\n')
    SHORT_ID=$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')
    HY_PASS=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
}

gen_self_signed_cert() {
    mkdir -p "$HY_DIR"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${HY_DIR}/key.pem" \
        -out "${HY_DIR}/cert.pem" \
        -subj "/CN=${SNI}" -days 3650 >/dev/null 2>&1
    CERT_SHA256=$(openssl x509 -noout -fingerprint -sha256 -in "${HY_DIR}/cert.pem" | cut -d'=' -f2 | tr -d ': \r\n')
}

save_and_apply() {
    mkdir -p /usr/local/etc/xray "$HY_DIR"

    cat << EOF > "$ENV_FILE"
PORT="${PORT}"
UUID="${UUID}"
PRIVATE_KEY="${PRIVATE_KEY}"
PUBLIC_KEY="${PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
HY_PASS="${HY_PASS}"
CERT_SHA256="${CERT_SHA256}"
EOF

    # 写入 Xray REALITY (TCP) 配置
    cat << EOF > "$XRAY_CONFIG"
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

    # 写入 Hysteria 2 (UDP) 配置
    cat << EOF > "$HY_CONFIG"
listen: :${PORT}

tls:
  cert: ${HY_DIR}/cert.pem
  key: ${HY_DIR}/key.pem

auth:
  type: password
  password: ${HY_PASS}

masquerade:
  type: proxy
  proxy:
    url: https://${SNI}/
    rewriteHost: true
EOF

    if ! xray run -test -c "$XRAY_CONFIG" >/dev/null 2>&1; then
        echo -e "${RED}Xray 配置检测失败：${NC}"
        xray run -test -c "$XRAY_CONFIG"
        return 1
    fi

    systemctl daemon-reload
    systemctl enable xray hysteria >/dev/null 2>&1
    systemctl restart xray hysteria
    sleep 1

    local ok=1
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}[OK] Xray (VLESS-REALITY TCP) 运行正常。${NC}"
    else
        echo -e "${RED}[ERR] Xray 启动失败，请查看日志。${NC}"
        ok=0
    fi

    if systemctl is-active --quiet hysteria; then
        echo -e "${GREEN}[OK] Hysteria 2 (UDP) 运行正常。${NC}"
    else
        echo -e "${RED}[ERR] Hysteria 2 启动失败，请查看日志。${NC}"
        ok=0
    fi

    [[ $ok -eq 1 ]]
}

install_node() {
    ensure_base_tools
    echo -e "\n${CYAN}=== 安装 / 重装双协议节点 (VLESS-REALITY + Hysteria2) ===${NC}"
    read -rp "请输入监听端口 [默认 443，同时用于 TCP 和 UDP]: " input_port
    PORT=${input_port:-443}

    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo -e "${RED}端口号无效（需为 1-65535）。${NC}"
        return
    fi

    echo -e "${CYAN}正在安装 Xray-core 内核...${NC}"
    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1

    echo -e "${CYAN}正在安装 Hysteria 2 内核...${NC}"
    install_hy2_binary || return

    gen_self_signed_cert
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

    if [[ -z "$CERT_SHA256" && -f "${HY_DIR}/cert.pem" ]]; then
        CERT_SHA256=$(openssl x509 -noout -fingerprint -sha256 -in "${HY_DIR}/cert.pem" | cut -d'=' -f2 | tr -d ': \r\n')
        echo "CERT_SHA256=\"${CERT_SHA256}\"" >> "$ENV_FILE"
    fi

    local ip formatted_ip
    ip=$(curl -s4m 5 https://api.ipify.org || curl -s4m 5 https://ifconfig.me || curl -s6m 5 https://api64.ipify.org)
    if [[ "$ip" == *":"* ]]; then
        formatted_ip="[${ip}]"
    else
        formatted_ip="${ip}"
    fi

    local vless_link="vless://${UUID}@${formatted_ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#VLESS-REALITY"
    local hy2_link="hysteria2://${HY_PASS}@${formatted_ip}:${PORT}/?sni=${SNI}&pinSHA256=${CERT_SHA256}#Hysteria2"

    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}当前双协议节点信息${NC}"
    echo "============================================================"
    echo "  服务器 IP   : ${ip}"
    echo "  监听端口    : ${PORT} (TCP: VLESS-REALITY / UDP: Hysteria2)"
    echo "  伪装域名    : ${SNI}"
    echo "------------------------------------------------------------"
    echo -e "  ${CYAN}[1] VLESS-REALITY 链接：${NC}"
    echo -e "  ${GREEN}${vless_link}${NC}"
    echo ""
    echo -e "  ${CYAN}[2] Hysteria2 链接 (已启用证书指纹锁定)：${NC}"
    echo -e "  ${GREEN}${hy2_link}${NC}"
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
    read -rp "确认重置所有密钥与密码？旧链接将立即失效 (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    source "$ENV_FILE"
    gen_self_signed_cert
    gen_credentials
    if save_and_apply; then
        show_info
    fi
}

service_menu() {
    echo -e "\n${CYAN}=== 服务管理 ===${NC}"
    echo "  1) 重启全部服务 (Xray + Hysteria2)"
    echo "  2) 停止全部服务"
    echo "  3) 查看运行状态与最近日志"
    read -rp "请选择 [1-3]: " s_choice
    case "$s_choice" in
        1) systemctl restart xray hysteria && echo -e "${GREEN}已全部重启。${NC}" ;;
        2) systemctl stop xray hysteria && echo -e "${YELLOW}已全部停止。${NC}" ;;
        3)
            echo "--- Xray 状态 ---"
            systemctl status xray --no-pager -l | head -n 8
            echo "--- Hysteria 2 状态 ---"
            systemctl status hysteria --no-pager -l | head -n 8
            echo "--- 最近日志 ---"
            journalctl -u xray -u hysteria -n 15 --no-pager
            ;;
        *) echo "无效选项。" ;;
    esac
}

update_kernels() {
    ensure_base_tools
    echo -e "${CYAN}正在更新 Xray-core 与 Hysteria 2 内核...${NC}"
    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    install_hy2_binary
    systemctl restart xray hysteria
    echo -e "${GREEN}更新完成：${NC}"
    echo "  Xray      : $(xray version | head -n 1)"
    echo "  Hysteria2 : $(/usr/local/bin/hysteria version | grep Version | xargs)"
}

uninstall_all() {
    read -rp "确认彻底卸载 Xray、Hysteria 2 并删除所有配置、证书及 legend 脚本？(y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    systemctl stop xray hysteria >/dev/null 2>&1
    systemctl disable xray hysteria >/dev/null 2>&1
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service /etc/systemd/system/hysteria.service
    rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
    systemctl daemon-reload >/dev/null 2>&1

    rm -f /usr/local/bin/xray /usr/local/bin/hysteria
    rm -rf /usr/local/etc/xray /usr/local/etc/hysteria /usr/local/share/xray /var/log/xray
    rm -f /usr/local/bin/legend

    echo -e "${GREEN}已本地彻底清理卸载，VPS 中无任何节点残留文件或进程。${NC}"
    exit 0
}

check_root

while true; do
    if systemctl is-active --quiet xray 2>/dev/null; then
        X_STAT="${GREEN}运行中${NC}"
    else
        X_STAT="${RED}未运行${NC}"
    fi

    if systemctl is-active --quiet hysteria 2>/dev/null; then
        H_STAT="${GREEN}运行中${NC}"
    else
        H_STAT="${RED}未运行${NC}"
    fi

    echo ""
    echo "=========================================================="
    echo -e "  Legend 极简面板  [VLESS-REALITY: ${X_STAT} | Hysteria2: ${H_STAT}]"
    echo "=========================================================="
    echo "  1. 安装 / 重装节点 (VLESS-REALITY + Hysteria2)"
    echo "  2. 查看节点信息与两条导入链接"
    echo "  3. 修改监听端口 (同步修改 TCP & UDP)"
    echo "  4. 重置密钥与密码"
    echo "  5. 服务管理 (重启 / 停止 / 日志)"
    echo "  6. 更新 Xray 与 Hysteria 2 内核"
    echo "  7. 彻底卸载"
    echo "  0. 退出"
    echo "=========================================================="
    read -rp "请选择 [0-7]: " choice

    case "$choice" in
        1) install_node ;;
        2) show_info ;;
        3) change_port ;;
        4) reset_keys ;;
        5) service_menu ;;
        6) update_kernels ;;
        7) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}请输入 0-7 之间的数字。${NC}" ;;
    esac
done
SCRIPT_EOF

chmod +x /usr/local/bin/legend
exec /usr/local/bin/legend </dev/tty
