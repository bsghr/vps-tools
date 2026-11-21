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
FW_SERVICE="/etc/systemd/system/legend-fw.service"
SNI="aws.amazon.com"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：请先使用 root 用户运行（执行 sudo -i 后重试）。${NC}"
        exit 1
    fi
}

ensure_tool() {
    local tool=$1
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo -e "${CYAN}正在补装基础工具: ${tool}...${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1 && apt-get install -y "$tool" >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "$tool" >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "$tool" >/dev/null 2>&1
        fi
    fi
}

get_public_ip() {
    curl -s4m 5 https://api.ipify.org || curl -s4m 5 https://ifconfig.me || curl -s6m 5 https://api64.ipify.org
}

format_ip() {
    local ip=$1
    if [[ "$ip" == *":"* ]]; then
        echo "[${ip}]"
    else
        echo "${ip}"
    fi
}

save_env() {
    mkdir -p /usr/local/etc/xray
    cat << EOF > "$ENV_FILE"
SERVER_IP="${SERVER_IP}"
REALITY_ENABLED="${REALITY_ENABLED:-0}"
REALITY_PORT="${REALITY_PORT}"
UUID="${UUID}"
PRIVATE_KEY="${PRIVATE_KEY}"
PUBLIC_KEY="${PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
HY2_ENABLED="${HY2_ENABLED:-0}"
HY2_PORT="${HY2_PORT}"
HY_PASS="${HY_PASS}"
CERT_SHA256="${CERT_SHA256}"
SOCKS_ENABLED="${SOCKS_ENABLED:-0}"
SOCKS_PORT="${SOCKS_PORT}"
SOCKS_USER="${SOCKS_USER}"
SOCKS_PASS="${SOCKS_PASS}"
RELAY_IP="${RELAY_IP}"
EOF
}

load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        source "$ENV_FILE"
        if [[ -n "$PORT" && -z "$REALITY_ENABLED" && -z "$HY2_ENABLED" && -z "$SOCKS_ENABLED" ]]; then
            [[ -n "$UUID" ]] && REALITY_ENABLED="1" && REALITY_PORT="$PORT"
            [[ -n "$HY_PASS" ]] && HY2_ENABLED="1" && HY2_PORT="$PORT"
            save_env
        fi
    fi
}

is_fw_active() {
    [[ -z "$SOCKS_PORT" ]] && return 1
    if command -v nft >/dev/null 2>&1 && nft list table inet legend_fw 2>/dev/null | grep -q "dport ${SOCKS_PORT} drop"; then
        return 0
    fi
    if command -v iptables >/dev/null 2>&1 && iptables -L LEGEND_SOCKS -n 2>/dev/null | grep -q "dpt:${SOCKS_PORT}"; then
        return 0
    fi
    return 1
}

apply_socks_fw() {
    # 清理旧规则
    command -v nft >/dev/null 2>&1 && nft delete table inet legend_fw 2>/dev/null || true
    if command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -j LEGEND_SOCKS 2>/dev/null || true
        iptables -F LEGEND_SOCKS 2>/dev/null || true
        iptables -X LEGEND_SOCKS 2>/dev/null || true
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -D INPUT -j LEGEND_SOCKS 2>/dev/null || true
        ip6tables -F LEGEND_SOCKS 2>/dev/null || true
        ip6tables -X LEGEND_SOCKS 2>/dev/null || true
    fi

    if [[ "$SOCKS_ENABLED" != "1" || -z "$RELAY_IP" || -z "$SOCKS_PORT" ]]; then
        if [[ -f "$FW_SERVICE" ]]; then
            systemctl disable legend-fw >/dev/null 2>&1
            rm -f "$FW_SERVICE"
            systemctl daemon-reload >/dev/null 2>&1
        fi
        return 0
    fi

    if ! command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
        ensure_tool nftables
        ! command -v nft >/dev/null 2>&1 && ensure_tool iptables
    fi

    local fw_ok=0

    # 优先使用 nftables (同时拦截 IPv4 + IPv6，priority -10 最高优先级)
    if command -v nft >/dev/null 2>&1; then
        if nft add table inet legend_fw 2>/dev/null && \
           nft 'add chain inet legend_fw input { type filter hook input priority -10; policy accept; }' 2>/dev/null; then
            if [[ "$RELAY_IP" == *":"* ]]; then
                nft add rule inet legend_fw input ip6 saddr "$RELAY_IP" tcp dport "$SOCKS_PORT" accept 2>/dev/null
                nft add rule inet legend_fw input ip6 saddr "$RELAY_IP" udp dport "$SOCKS_PORT" accept 2>/dev/null
            else
                nft add rule inet legend_fw input ip saddr "$RELAY_IP" tcp dport "$SOCKS_PORT" accept 2>/dev/null
                nft add rule inet legend_fw input ip saddr "$RELAY_IP" udp dport "$SOCKS_PORT" accept 2>/dev/null
            fi
            if nft add rule inet legend_fw input tcp dport "$SOCKS_PORT" drop 2>/dev/null && \
               nft add rule inet legend_fw input udp dport "$SOCKS_PORT" drop 2>/dev/null; then
                fw_ok=1
            else
                nft delete table inet legend_fw 2>/dev/null || true
            fi
        fi
    fi

    # 回退使用 iptables + ip6tables
    if [[ $fw_ok -eq 0 ]] && command -v iptables >/dev/null 2>&1; then
        if iptables -N LEGEND_SOCKS 2>/dev/null && iptables -I INPUT -j LEGEND_SOCKS 2>/dev/null; then
            if [[ "$RELAY_IP" != *":"* ]]; then
                iptables -A LEGEND_SOCKS -s "$RELAY_IP" -p tcp --dport "$SOCKS_PORT" -j ACCEPT 2>/dev/null
                iptables -A LEGEND_SOCKS -s "$RELAY_IP" -p udp --dport "$SOCKS_PORT" -j ACCEPT 2>/dev/null
            fi
            if iptables -A LEGEND_SOCKS -p tcp --dport "$SOCKS_PORT" -j DROP 2>/dev/null && \
               iptables -A LEGEND_SOCKS -p udp --dport "$SOCKS_PORT" -j DROP 2>/dev/null; then
                fw_ok=1
            fi
        fi
        if command -v ip6tables >/dev/null 2>&1; then
            if ip6tables -N LEGEND_SOCKS 2>/dev/null && ip6tables -I INPUT -j LEGEND_SOCKS 2>/dev/null; then
                if [[ "$RELAY_IP" == *":"* ]]; then
                    ip6tables -A LEGEND_SOCKS -s "$RELAY_IP" -p tcp --dport "$SOCKS_PORT" -j ACCEPT 2>/dev/null
                    ip6tables -A LEGEND_SOCKS -s "$RELAY_IP" -p udp --dport "$SOCKS_PORT" -j ACCEPT 2>/dev/null
                fi
                ip6tables -A LEGEND_SOCKS -p tcp --dport "$SOCKS_PORT" -j DROP 2>/dev/null
                ip6tables -A LEGEND_SOCKS -p udp --dport "$SOCKS_PORT" -j DROP 2>/dev/null
            fi
        fi
    fi

    if [[ $fw_ok -eq 1 ]] && is_fw_active; then
        cat << EOF > "$FW_SERVICE"
[Unit]
Description=Legend SOCKS5 IP Whitelist
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/legend --apply-fw
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable legend-fw >/dev/null 2>&1
        echo -e "${GREEN}[OK] 防火墙白名单已生效：仅允许 ${RELAY_IP} 访问端口 ${SOCKS_PORT}。${NC}"
        return 0
    else
        echo -e "${RED}[ERR] 防火墙规则加载失败（当前系统可能无 iptables/nftables 权限），请检查系统环境。${NC}"
        return 1
    fi
}

if [[ "$1" == "--apply-fw" ]]; then
    load_env
    apply_socks_fw >/dev/null 2>&1
    exit 0
fi

install_xray_binary() {
    if ! command -v xray >/dev/null 2>&1; then
        ensure_tool curl
        echo -e "${CYAN}正在安装官方 Xray-core 内核...${NC}"
        bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    fi
}

install_hy2_binary() {
    ensure_tool curl
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

    echo -e "${CYAN}正在安装官方 Hysteria 2 内核...${NC}"
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

apply_xray_config() {
    if [[ "$REALITY_ENABLED" != "1" && "$SOCKS_ENABLED" != "1" ]]; then
        systemctl stop xray >/dev/null 2>&1
        systemctl disable xray >/dev/null 2>&1
        return 0
    fi

    install_xray_binary
    mkdir -p /usr/local/etc/xray
    local inbounds=()

    if [[ "$REALITY_ENABLED" == "1" ]]; then
        inbounds+=("$(cat << EOF
    {
      "listen": "0.0.0.0",
      "port": ${REALITY_PORT},
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
EOF
)")
    fi

    if [[ "$SOCKS_ENABLED" == "1" ]]; then
        local ip_line=""
        [[ -n "$SERVER_IP" ]] && ip_line=",
        \"ip\": \"${SERVER_IP}\""
        inbounds+=("$(cat << EOF
    {
      "listen": "0.0.0.0",
      "port": ${SOCKS_PORT},
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          {
            "user": "${SOCKS_USER}",
            "pass": "${SOCKS_PASS}"
          }
        ],
        "udp": true${ip_line}
      }
    }
EOF
)")
    fi

    local joined_inbounds=""
    for i in "${!inbounds[@]}"; do
        [[ $i -gt 0 ]] && joined_inbounds+=","$'\n'
        joined_inbounds+="${inbounds[$i]}"
    done

    cat << EOF > "$XRAY_CONFIG"
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
${joined_inbounds}
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

    if ! xray run -test -c "$XRAY_CONFIG" >/dev/null 2>&1; then
        echo -e "${RED}Xray 配置校验失败：${NC}"
        xray run -test -c "$XRAY_CONFIG"
        return 1
    fi

    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray
    sleep 1

    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}[OK] Xray 服务运行正常。${NC}"
        return 0
    else
        echo -e "${RED}[ERR] Xray 启动失败，请查看日志。${NC}"
        return 1
    fi
}

apply_hy2_config() {
    if [[ "$HY2_ENABLED" != "1" ]]; then
        systemctl stop hysteria >/dev/null 2>&1
        systemctl disable hysteria >/dev/null 2>&1
        return 0
    fi

    [[ ! -x /usr/local/bin/hysteria ]] && install_hy2_binary
    mkdir -p "$HY_DIR"

    cat << EOF > "$HY_CONFIG"
listen: :${HY2_PORT}

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

    systemctl daemon-reload
    systemctl enable hysteria >/dev/null 2>&1
    systemctl restart hysteria
    sleep 1

    if systemctl is-active --quiet hysteria; then
        echo -e "${GREEN}[OK] Hysteria 2 服务运行正常。${NC}"
        return 0
    else
        echo -e "${RED}[ERR] Hysteria 2 启动失败，请查看日志。${NC}"
        return 1
    fi
}

gen_reality_creds() {
    install_xray_binary
    UUID=$(xray uuid)
    local keys
    keys=$(xray x25519)
    PRIVATE_KEY=$(echo "$keys" | awk -F':' 'NR==1 {print $2}' | tr -d ' \r\n')
    PUBLIC_KEY=$(echo "$keys" | awk -F':' 'NR==2 {print $2}' | tr -d ' \r\n')
    SHORT_ID=$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')
}

gen_hy2_creds() {
    ensure_tool openssl
    mkdir -p "$HY_DIR"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${HY_DIR}/key.pem" \
        -out "${HY_DIR}/cert.pem" \
        -subj "/CN=${SNI}" -days 3650 >/dev/null 2>&1
    CERT_SHA256=$(openssl x509 -noout -fingerprint -sha256 -in "${HY_DIR}/cert.pem" | cut -d'=' -f2 | tr -d ': \r\n')
    HY_PASS=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
}

gen_socks_creds() {
    SOCKS_USER="u$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
    SOCKS_PASS=$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')
}

install_menu() {
    ensure_tool curl
    load_env
    [[ -z "$SERVER_IP" ]] && SERVER_IP=$(get_public_ip)

    echo ""
    echo "=========================================================="
    echo -e "  ${CYAN}请选择要安装 / 部署的协议${NC}"
    echo "=========================================================="
    echo "  1) VLESS-REALITY (TCP / 伪装 ${SNI})"
    echo "  2) Hysteria2     (UDP / 伪装 ${SNI})"
    echo "  3) SOCKS5        (落地专用 + 中转机 IP 白名单)"
    echo "  0) 返回主菜单"
    echo "=========================================================="
    read -rp "请选择 [0-3]: " p_choice

    case "$p_choice" in
        1)
            read -rp "请输入 VLESS-REALITY 监听端口 [默认 443]: " in_port
            REALITY_PORT=${in_port:-443}
            if ! [[ "$REALITY_PORT" =~ ^[0-9]+$ ]] || [ "$REALITY_PORT" -lt 1 ] || [ "$REALITY_PORT" -gt 65535 ]; then
                echo -e "${RED}端口号无效。${NC}"
                return
            fi
            gen_reality_creds
            REALITY_ENABLED="1"
            save_env
            apply_xray_config && show_info
            ;;
        2)
            read -rp "请输入 Hysteria2 监听端口 [默认 443]: " in_port
            HY2_PORT=${in_port:-443}
            if ! [[ "$HY2_PORT" =~ ^[0-9]+$ ]] || [ "$HY2_PORT" -lt 1 ] || [ "$HY2_PORT" -gt 65535 ]; then
                echo -e "${RED}端口号无效。${NC}"
                return
            fi
            install_hy2_binary || return
            gen_hy2_creds
            HY2_ENABLED="1"
            save_env
            apply_hy2_config && show_info
            ;;
        3)
            local default_socks=$((RANDOM % 30000 + 20000))
            read -rp "请输入 SOCKS5 监听端口 [默认随机 ${default_socks}]: " in_port
            SOCKS_PORT=${in_port:-$default_socks}
            if ! [[ "$SOCKS_PORT" =~ ^[0-9]+$ ]] || [ "$SOCKS_PORT" -lt 1 ] || [ "$SOCKS_PORT" -gt 65535 ]; then
                echo -e "${RED}端口号无效。${NC}"
                return
            fi
            read -rp "请输入允许访问的中转机 IP (留空则不限制来源): " in_relay
            RELAY_IP=$(echo "$in_relay" | tr -d ' \r\n')
            gen_socks_creds
            SOCKS_ENABLED="1"
            save_env
            apply_socks_fw
            apply_xray_config && show_info
            ;;
        0) return ;;
        *) echo -e "${RED}无效选项。${NC}" ;;
    esac
}

show_info() {
    load_env
    if [[ "$REALITY_ENABLED" != "1" && "$HY2_ENABLED" != "1" && "$SOCKS_ENABLED" != "1" ]]; then
        echo -e "${RED}当前尚未安装任何节点，请先执行选项 1 安装。${NC}"
        return
    fi

    [[ -z "$SERVER_IP" ]] && SERVER_IP=$(get_public_ip) && save_env
    local fmt_ip
    fmt_ip=$(format_ip "$SERVER_IP")

    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}当前已部署节点信息${NC}  (服务器 IP: ${SERVER_IP})"
    echo "============================================================"

    if [[ "$REALITY_ENABLED" == "1" ]]; then
        local vless_link="vless://${UUID}@${fmt_ip}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#VLESS-REALITY"
        echo -e "  ${CYAN}[VLESS-REALITY]${NC}  端口: ${REALITY_PORT} (TCP) | 伪装: ${SNI}"
        echo -e "  ${GREEN}${vless_link}${NC}"
        echo "------------------------------------------------------------"
    fi

    if [[ "$HY2_ENABLED" == "1" ]]; then
        if [[ -z "$CERT_SHA256" && -f "${HY_DIR}/cert.pem" ]]; then
            CERT_SHA256=$(openssl x509 -noout -fingerprint -sha256 -in "${HY_DIR}/cert.pem" | cut -d'=' -f2 | tr -d ': \r\n')
            save_env
        fi
        local hy2_pin_link="hysteria2://${HY_PASS}@${fmt_ip}:${HY2_PORT}/?sni=${SNI}&pinSHA256=${CERT_SHA256}#Hysteria2"
        local hy2_plain_link="hysteria2://${HY_PASS}@${fmt_ip}:${HY2_PORT}/?sni=${SNI}#Hysteria2"
        echo -e "  ${CYAN}[Hysteria2]${NC}      端口: ${HY2_PORT} (UDP) | 伪装: ${SNI}"
        echo -e "  证书 SHA-256 : ${YELLOW}${CERT_SHA256}${NC}"
        echo -e "  含指纹链接   : ${GREEN}${hy2_pin_link}${NC}"
        echo -e "  无指纹链接   : ${GREEN}${hy2_plain_link}${NC}"
        echo "------------------------------------------------------------"
    fi

    if [[ "$SOCKS_ENABLED" == "1" ]]; then
        local fw_desc="${YELLOW}未限制 (全网可连)${NC}"
        if [[ -n "$RELAY_IP" ]]; then
            if is_fw_active; then
                fw_desc="${GREEN}已生效 (仅限 ${RELAY_IP} 访问)${NC}"
            else
                fw_desc="${RED}规则未生效 (请进入选项 3 -> 4 重新应用)${NC}"
            fi
        fi
        local socks_link="socks5://${SOCKS_USER}:${SOCKS_PASS}@${fmt_ip}:${SOCKS_PORT}#SOCKS5"
        echo -e "  ${CYAN}[SOCKS5 落地]${NC}    端口: ${SOCKS_PORT} | 访问限制: ${fw_desc}"
        echo "  用户名: ${SOCKS_USER}   密码: ${SOCKS_PASS}"
        echo -e "  ${GREEN}${socks_link}${NC}"
        echo "------------------------------------------------------------"
    fi
    echo "============================================================"
}

modify_menu() {
    load_env
    if [[ "$REALITY_ENABLED" != "1" && "$HY2_ENABLED" != "1" && "$SOCKS_ENABLED" != "1" ]]; then
        echo -e "${RED}当前尚未安装任何节点。${NC}"
        return
    fi

    echo -e "\n${CYAN}=== 修改端口 / 中转IP白名单 ===${NC}"
    [[ "$REALITY_ENABLED" == "1" ]] && echo "  1) 修改 VLESS-REALITY 端口 (当前: ${REALITY_PORT})"
    [[ "$HY2_ENABLED" == "1" ]]     && echo "  2) 修改 Hysteria2 端口     (当前: ${HY2_PORT})"
    [[ "$SOCKS_ENABLED" == "1" ]]   && echo "  3) 修改 SOCKS5 端口        (当前: ${SOCKS_PORT})"
    [[ "$SOCKS_ENABLED" == "1" ]]   && echo "  4) 修改/重刷 SOCKS5 允许的中转机 IP (当前: ${RELAY_IP:-不限制})"
    echo "  0) 返回主菜单"
    read -rp "请选择: " m_choice

    case "$m_choice" in
        1)
            [[ "$REALITY_ENABLED" != "1" ]] && return
            read -rp "请输入新的 VLESS-REALITY 端口: " new_p
            if [[ "$new_p" =~ ^[0-9]+$ ]] && [ "$new_p" -ge 1 ] && [ "$new_p" -le 65535 ]; then
                REALITY_PORT="$new_p"
                save_env
                apply_xray_config && show_info
            else
                echo -e "${RED}端口号无效。${NC}"
            fi
            ;;
        2)
            [[ "$HY2_ENABLED" != "1" ]] && return
            read -rp "请输入新的 Hysteria2 端口: " new_p
            if [[ "$new_p" =~ ^[0-9]+$ ]] && [ "$new_p" -ge 1 ] && [ "$new_p" -le 65535 ]; then
                HY2_PORT="$new_p"
                save_env
                apply_hy2_config && show_info
            else
                echo -e "${RED}端口号无效。${NC}"
            fi
            ;;
        3)
            [[ "$SOCKS_ENABLED" != "1" ]] && return
            read -rp "请输入新的 SOCKS5 端口: " new_p
            if [[ "$new_p" =~ ^[0-9]+$ ]] && [ "$new_p" -ge 1 ] && [ "$new_p" -le 65535 ]; then
                SOCKS_PORT="$new_p"
                save_env
                apply_socks_fw
                apply_xray_config && show_info
            else
                echo -e "${RED}端口号无效。${NC}"
            fi
            ;;
        4)
            [[ "$SOCKS_ENABLED" != "1" ]] && return
            read -rp "请输入允许访问的中转机 IP (直接回车保留当前 [${RELAY_IP}]，输入 none 取消限制): " new_ip
            new_ip=$(echo "$new_ip" | tr -d ' \r\n')
            if [[ "$new_ip" == "none" ]]; then
                RELAY_IP=""
            elif [[ -n "$new_ip" ]]; then
                RELAY_IP="$new_ip"
            fi
            save_env
            apply_socks_fw
            show_info
            ;;
        0) return ;;
        *) echo -e "${RED}无效选项。${NC}" ;;
    esac
}

reset_keys() {
    load_env
    if [[ "$REALITY_ENABLED" != "1" && "$HY2_ENABLED" != "1" && "$SOCKS_ENABLED" != "1" ]]; then
        echo -e "${RED}当前尚未安装任何节点。${NC}"
        return
    fi
    read -rp "确认重置所有已安装节点的密钥、密码与证书？旧链接将立即失效 (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    [[ "$REALITY_ENABLED" == "1" ]] && gen_reality_creds
    [[ "$HY2_ENABLED" == "1" ]]     && gen_hy2_creds
    [[ "$SOCKS_ENABLED" == "1" ]]   && gen_socks_creds

    save_env
    [[ "$REALITY_ENABLED" == "1" || "$SOCKS_ENABLED" == "1" ]] && apply_xray_config
    [[ "$HY2_ENABLED" == "1" ]] && apply_hy2_config
    show_info
}

service_menu() {
    echo -e "\n${CYAN}=== 服务管理 ===${NC}"
    echo "  1) 重启已安装服务"
    echo "  2) 停止已安装服务"
    echo "  3) 查看运行状态与最近日志"
    read -rp "请选择 [1-3]: " s_choice
    case "$s_choice" in
        1)
            systemctl is-enabled --quiet xray 2>/dev/null && systemctl restart xray
            systemctl is-enabled --quiet hysteria 2>/dev/null && systemctl restart hysteria
            echo -e "${GREEN}已重启服务。${NC}"
            ;;
        2)
            systemctl stop xray hysteria 2>/dev/null
            echo -e "${YELLOW}已停止服务。${NC}"
            ;;
        3)
            if systemctl is-enabled --quiet xray 2>/dev/null; then
                echo "--- Xray 状态 ---"
                systemctl status xray --no-pager -l | head -n 8
            fi
            if systemctl is-enabled --quiet hysteria 2>/dev/null; then
                echo "--- Hysteria 2 状态 ---"
                systemctl status hysteria --no-pager -l | head -n 8
            fi
            echo "--- 最近日志 ---"
            journalctl -u xray -u hysteria -n 15 --no-pager
            ;;
        *) echo "无效选项。" ;;
    esac
}

update_kernels() {
    load_env
    ensure_tool curl
    echo -e "${CYAN}正在更新已安装的官方内核...${NC}"
    if [[ "$REALITY_ENABLED" == "1" || "$SOCKS_ENABLED" == "1" ]]; then
        bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
        systemctl restart xray
        echo -e "${GREEN}Xray      : $(xray version | head -n 1)${NC}"
    fi
    if [[ "$HY2_ENABLED" == "1" ]]; then
        install_hy2_binary && systemctl restart hysteria
        echo -e "${GREEN}Hysteria2 : $(/usr/local/bin/hysteria version | grep Version | xargs)${NC}"
    fi
}

uninstall_all() {
    read -rp "确认彻底卸载所有节点内核、配置、防火墙白名单及 legend 脚本？(y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    systemctl stop xray hysteria legend-fw >/dev/null 2>&1
    systemctl disable xray hysteria legend-fw >/dev/null 2>&1
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service /etc/systemd/system/hysteria.service "$FW_SERVICE"
    rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
    systemctl daemon-reload >/dev/null 2>&1

    command -v nft >/dev/null 2>&1 && nft delete table inet legend_fw 2>/dev/null || true
    if command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -j LEGEND_SOCKS 2>/dev/null || true
        iptables -F LEGEND_SOCKS 2>/dev/null || true
        iptables -X LEGEND_SOCKS 2>/dev/null || true
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -D INPUT -j LEGEND_SOCKS 2>/dev/null || true
        ip6tables -F LEGEND_SOCKS 2>/dev/null || true
        ip6tables -X LEGEND_SOCKS 2>/dev/null || true
    fi

    rm -f /usr/local/bin/xray /usr/local/bin/hysteria
    rm -rf /usr/local/etc/xray /usr/local/etc/hysteria /usr/local/share/xray /var/log/xray
    rm -f /usr/local/bin/legend

    echo -e "${GREEN}已本地彻底清理卸载，VPS 中无任何节点或防火墙残留。${NC}"
    exit 0
}

check_root
load_env

while true; do
    load_env
    if [[ "$REALITY_ENABLED" == "1" ]]; then
        systemctl is-active --quiet xray 2>/dev/null && R_STAT="${GREEN}运行中${NC}" || R_STAT="${RED}已停止${NC}"
    else
        R_STAT="${GRAY}未安装${NC}"
    fi

    if [[ "$HY2_ENABLED" == "1" ]]; then
        systemctl is-active --quiet hysteria 2>/dev/null && H_STAT="${GREEN}运行中${NC}" || H_STAT="${RED}已停止${NC}"
    else
        H_STAT="${GRAY}未安装${NC}"
    fi

    if [[ "$SOCKS_ENABLED" == "1" ]]; then
        systemctl is-active --quiet xray 2>/dev/null && S_STAT="${GREEN}运行中${NC}" || S_STAT="${RED}已停止${NC}"
    else
        S_STAT="${GRAY}未安装${NC}"
    fi

    echo ""
    echo "================================================================"
    echo -e "  Legend 极简面板  [REALITY:${R_STAT} | HY2:${H_STAT} | SOCKS5:${S_STAT}]"
    echo "================================================================"
    echo "  1. 安装 / 部署节点 (可选 REALITY / HY2 / SOCKS5)"
    echo "  2. 查看已部署节点信息与导入链接"
    echo "  3. 修改端口 / SOCKS5 中转IP白名单"
    echo "  4. 重置密钥 / 密码 / 证书"
    echo "  5. 服务管理 (重启 / 停止 / 日志)"
    echo "  6. 更新已安装的官方内核"
    echo "  7. 彻底卸载"
    echo "  0. 退出"
    echo "================================================================"
    read -rp "请选择 [0-7]: " choice

    case "$choice" in
        1) install_menu ;;
        2) show_info ;;
        3) modify_menu ;;
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
