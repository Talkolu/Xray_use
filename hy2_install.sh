#!/usr/bin/env bash
set -euo pipefail

# =============== 彩色 ===============
C_GREEN="\033[32m"; C_YELLOW="\033[33m"; C_RED="\033[31m"; C_RESET="\033[0m"

# =============== Root 检查 ===============
if [[ $EUID -ne 0 ]]; then
  echo "[ERR] 请用 root 运行：sudo $0"; exit 1
fi

# =============== 基础函数 ===============
is_ipv4() {
  local ip=$1
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<< "$ip"
  for v in "$a" "$b" "$c" "$d"; do
    [[ $v =~ ^[0-9]+$ ]] || return 1
    (( v >= 0 && v <= 255 )) || return 1
  done
  return 0
}

is_private_ipv4() {
  local ip=$1
  [[ $ip == 10.* ]] && return 0
  [[ $ip =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  [[ $ip == 192.168.* ]] && return 0
  [[ $ip == 127.* ]] && return 0
  [[ $ip == 169.254.* ]] && return 0
  return 1
}

get_ip_from_services() {
  local services=(
    "https://ipv4.icanhazip.com"
    "https://ifconfig.co/ip"
    "https://ifconfig.me/ip"
    "https://ipinfo.io/ip"
    "https://checkip.amazonaws.com"
    "https://ident.me"
    "https://api.ip.sb/ip"
  )
  local ip=""
  for url in "${services[@]}"; do
    if command -v curl >/dev/null 2>&1; then
      ip="$(curl -fsS --max-time 3 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    else
      ip="$(wget -qO- --timeout=3 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    if [[ -n "$ip" ]]; then
      if is_ipv4 "$ip"; then
        if ! is_private_ipv4 "$ip"; then
          printf '%s\n' "$ip"; return 0
        fi
      fi
    fi
  done
  return 1
}

get_ip_from_opendns() {
  local ip=""
  if command -v dig >/dev/null 2>&1; then
    ip="$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | tr -d '[:space:]' || true)"
  elif command -v host >/dev/null 2>&1; then
    ip="$(host myip.opendns.com resolver1.opendns.com 2>/dev/null | awk '/has address/ {print $4; exit}' || true)"
  fi
  if [[ -n "$ip" ]]; then
    if is_ipv4 "$ip"; then
      if ! is_private_ipv4 "$ip"; then
        printf '%s\n' "$ip"; return 0
      fi
    fi
  fi
  return 1
}

get_ip_from_dns_resolve() {
  local domain="$1" ip=""
  [[ -z "$domain" ]] && return 1
  if command -v dig >/dev/null 2>&1; then
    ip="$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9.]+' | head -n1 | tr -d '[:space:]' || true)"
  elif command -v getent >/dev/null 2>&1; then
    ip="$(getent hosts "$domain" | awk '{print $1; exit}' || true)"
  elif command -v host >/dev/null 2>&1; then
    ip="$(host -t A "$domain" 2>/dev/null | awk '/has address/ {print $4; exit}' || true)"
  fi
  if [[ -n "$ip" ]]; then
    if is_ipv4 "$ip"; then
      if ! is_private_ipv4 "$ip"; then
        printf '%s\n' "$ip"; return 0
      fi
    fi
  fi
  return 1
}

get_ip_from_local_route() {
  local ip="" iface=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    if [[ -z "$ip" ]]; then
      iface="$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
      if [[ -n "$iface" ]]; then
        ip="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
      fi
    fi
  fi
  if [[ -n "$ip" ]]; then
    if is_ipv4 "$ip"; then
      if ! is_private_ipv4 "$ip"; then
        printf '%s\n' "$ip"; return 0
      fi
    fi
  fi
  return 1
}

get_public_ip() {
  local domain="$1" ip=""
  ip="$(get_ip_from_services || true)";            [[ -n "$ip" ]] && { echo "$ip"; return 0; }
  ip="$(get_ip_from_opendns   || true)";           [[ -n "$ip" ]] && { echo "$ip"; return 0; }
  ip="$(get_ip_from_dns_resolve "$domain" || true)";[[ -n "$ip" ]] && { echo "$ip"; return 0; }
  ip="$(get_ip_from_local_route || true)";         [[ -n "$ip" ]] && { echo "$ip"; return 0; }
  return 1
}

gen_pwd() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -d '\n' | tr -d '/+='
  else
    tr -dc 'A-Za-z0-9!@#$%^&*_-+=' </dev/urandom | head -c 24
  fi
}

# =============== 安装 hysteria ===============
echo -e "${C_GREEN}[1/8] 检查/安装 hy2 ...${C_RESET}"
if ! command -v hysteria >/dev/null 2>&1; then
  bash <(curl -fsSL https://get.hy2.sh/)
else
  echo "[INFO] 已检测到 hysteria，跳过安装。"
fi

# =============== 交互输入 ===============
read -r -p "监听端口（回车默认 443）： " LISTEN_PORT
LISTEN_PORT="${LISTEN_PORT:-443}"
if ! [[ "$LISTEN_PORT" =~ ^[0-9]{1,5}$ ]] || (( LISTEN_PORT < 1 || LISTEN_PORT > 65535 )); then
  echo -e "${C_RED}[ERR] 端口无效：$LISTEN_PORT${C_RESET}"; exit 1
fi

read -r -p "域名（例：your.domain.net）： " DOMAIN
[[ -z "$DOMAIN" ]] && { echo -e "${C_RED}[ERR] 域名不能为空${C_RESET}"; exit 1; }

read -r -p "密码（回车自动生成复杂密码）： " PASSWORD
if [[ -z "$PASSWORD" ]]; then PASSWORD="$(gen_pwd)"; echo "[INFO] 已生成密码：${PASSWORD}"; fi

read -r -p "Email（回车默认 your@email.com）： " EMAIL
EMAIL="${EMAIL:-your@email.com}"

read -r -p "伪装网站（回车默认 https://www.bing.com/）： " MASQ_URL
MASQ_URL="${MASQ_URL:-https://www.bing.com/}"

TS="$(date +%Y%m%d%H%M%S)"
read -r -p "节点名称（回车默认 server${TS}）： " NODE_NAME
NODE_NAME="${NODE_NAME:-server${TS}}"

# =============== 写配置 ===============
CFG_DIR="/etc/hysteria"; CFG_FILE="${CFG_DIR}/config.yaml"
mkdir -p "$CFG_DIR"
cat > "$CFG_FILE" <<YAML
listen: :${LISTEN_PORT}

acme:
  domains:
    - ${DOMAIN}
  email: ${EMAIL}

auth:
  type: password
  password: ${PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: ${MASQ_URL}
    rewriteHost: true

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
YAML

echo -e "${C_YELLOW}[提示] ACME 需要 80/TCP 可达；hy2 使用 UDP（可选 TCP）${LISTEN_PORT}${C_RESET}"

# =============== 启动服务 ===============
systemctl enable hysteria-server.service || true
systemctl start  hysteria-server.service || true
systemctl restart hysteria-server.service || true

echo -e "${C_GREEN}服务状态（简要）：${C_RESET}"
systemctl --no-pager status hysteria-server.service || true

# =============== 公网 IP 与链接输出 ===============
echo -e "${C_YELLOW}[提示] 正在获取公网 IP...${C_RESET}"
PUB_IP="$(get_public_ip "$DOMAIN" || true)"
if [[ -n "$PUB_IP" ]]; then
  echo -e "${C_GREEN}[OK] 公网 IP: ${PUB_IP}${C_RESET}"
else
  echo -e "${C_YELLOW}[WARN] 未能可靠检测到公网 IP，将使用域名生成链接${C_RESET}"
fi

HOST_FOR_LINK="${PUB_IP:-$DOMAIN}"
HYSTERIA_LINK="hysteria2://${PASSWORD}@${HOST_FOR_LINK}:${LISTEN_PORT}/?sni=${DOMAIN}&insecure=0#${NODE_NAME}"

echo
echo -e "${C_GREEN}========== HY2 节点信息 ==========${C_RESET}"
echo "域名:      ${DOMAIN}:${LISTEN_PORT}"
echo "IP:        ${PUB_IP:-<未检测，使用域名>}:${LISTEN_PORT}"
echo "Auth:      password"
echo "Password:  ${PASSWORD}"
echo "ACME:      ${EMAIL}"
echo "Masq:      ${MASQ_URL}"
echo "Config:    ${CFG_FILE}"
echo "节点名:    ${NODE_NAME}"
echo
echo -e "${C_GREEN}Hysteria 导入链接：${C_RESET}"
echo "${HYSTERIA_LINK}"
echo
