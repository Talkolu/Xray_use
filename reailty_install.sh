#!/usr/bin/env bash
set -euo pipefail

# ---------- 0) root & deps ----------
if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行：sudo -i 后再执行" >&2
  exit 1
fi

# ---------- 1) 安装/更新 Xray ----------
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# ---------- 2) 生成 uuid / x25519（兼容不同输出：PublicKey/Password） ----------
uuid=$(xray uuid)
x25519_out="$(xray x25519)"
private_key="$(echo "$x25519_out" | awk -F': ' '/^Private(Key)? *:|^Private key *:/{print $2; exit}')"
public_key="$(echo  "$x25519_out" | awk -F': ' '/^Public(Key)? *:|^Public key *:|^Password *:/{print $2; exit}')"

# ---------- 3) 生成 shortId（偶数长度，<=16） ----------
lens=(2 4 6 8 10 12 14 16)
pick_len=${lens[$RANDOM % ${#lens[@]}]}
short_id=$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-${pick_len})

# ---------- 4) 交互输入端口、伪装站、节点名称 ----------
read -rp "监听端口 [默认 443]：" port
port=${port:-443}

read -rp "伪装站/SNI（例如 swcdn.apple.com）[默认 swcdn.apple.com]：" sni
sni=${sni:-swcdn.apple.com}

# 默认节点名：server-主机名-时间戳（例如 server-sour-poetry-20251021-153045）
host_name=$(hostname | cut -d'.' -f1)
ts=$(date +%Y%m%d-%H%M%S)
default_name="server-${host_name}-${ts}"

read -rp "节点名称（显示在链接 # 后）[默认 ${default_name}]：" node_name
node_name=${node_name:-$default_name}

# 简易 URL 编码（避免空格/#等导致链接异常）
urlencode() {
  local s="$1"
  s="${s//'%'/%25}"
  s="${s//' '/%20}"
  s="${s//'#'/%23}"
  s="${s//$'\n'/%0A}"
  echo -n "$s"
}
tag="$(urlencode "$node_name")"

# ---------- 5) 生成配置 ----------
cfg=/usr/local/etc/xray/config.json
mkdir -p /usr/local/etc/xray /var/log/xray
install -d -m 0755 /var/log/xray
[[ -f "$cfg" ]] && cp -a "$cfg" "${cfg}.bak.$(date +%s)"

cat >"$cfg" <<JSON
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "ip": ["geoip:cn"], "outboundTag": "block" },
      { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block" }
    ]
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${uuid}", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "${sni}:443",
          "serverNames": ["${sni}"],
          "privateKey": "${private_key}",
          "shortIds": ["${short_id}"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ]
}
JSON

# ---------- 6) 启动&自启 ----------
systemctl daemon-reload
systemctl enable xray >/dev/null 2>&1
systemctl restart xray

sleep 0.8
if systemctl is-active --quiet xray; then
  echo "✅ Xray 配置成功并已启动"
else
  echo "❌ Xray 未处于运行状态，请执行 'journalctl -u xray -e --no-pager' 查看错误" >&2
  exit 2
fi

# ---------- 7) 获取公网 IPv4（多源 + 校验） ----------
_get_ip() {
  for url in "https://ipv4.icanhazip.com" "https://api.ipify.org" "https://ipinfo.io/ip" "https://ifconfig.me"; do
    ip=$(curl -4s --max-time 5 "$url" 2>/dev/null | tr -d ' \t\r\n')
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
  done
  ip=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | tr -d ' \t\r\n')
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
  echo ""
  return 1
}

server_ip="$(_get_ip)"
if [[ -z "$server_ip" ]]; then
  server_ip="YOUR_SERVER_IP"
  echo "⚠️ 未能自动获取公网 IP，已用占位：$server_ip"
fi

# ---------- 8) 构造分享链接 ----------
node="vless://${uuid}@${server_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${tag}"

echo
echo "---------- 关键信息 ----------"
echo "UUID:        ${uuid}"
echo "PrivateKey:  ${private_key}"
echo "PublicKey(pbk/客户端用): ${public_key}"
echo "ShortID(sid): ${short_id}"
echo "SNI/伪装站:  ${sni}"
echo "端口:        ${port}"
echo "节点名称:    ${node_name}"
echo
echo "节点（可直接导入）："
echo "${node}"
