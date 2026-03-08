#!/bin/bash
# =================================================================
# xray.sh — Конфиг Xray VLESS+WebSocket+TLS, параметры, QR-код
# =================================================================

# =================================================================
# Получение флага страны по IP сервера
# Возвращает emoji флага, например 🇩🇪
# При ошибке возвращает 🌐
# =================================================================
_getCountryFlag() {
    local ip="$1"
    local code
    code=$(curl -s --connect-timeout 5 "http://ip-api.com/line/${ip}?fields=countryCode" 2>/dev/null | tr -d '[:space:]')
    if [[ "$code" =~ ^[A-Z]{2}$ ]]; then
        # Конвертируем код страны в emoji флаг через региональные индикаторы
        # A=0x1F1E6, поэтому каждая буква = 0x1F1E6 + (ord - ord('A'))
        python3 -c "
c='${code}'
flag=''.join(chr(0x1F1E6 + ord(ch) - ord('A')) for ch in c)
print(flag)
" 2>/dev/null || echo "🌐"
    else
        echo "🌐"
    fi
}

# Формирует красивое имя конфига: 🇩🇪 VL-WS-CDN | label 🇩🇪
# Аргументы: тип (WS|Reality), label, [ip]
_getConfigName() {
    local type="$1"
    local label="$2"
    local ip="${3:-$(getServerIP)}"
    local flag
    flag=$(_getCountryFlag "$ip")
    case "$type" in
        WS)       echo "${flag} VL-WS-CDN | ${label} ${flag}" ;;
        Reality)  echo "${flag} VL-Reality | ${label} ${flag}" ;;
        *)        echo "${flag} VL-${type} | ${label} ${flag}" ;;
    esac
}

installXray() {
    command -v xray &>/dev/null && { echo "info: xray already installed."; return; }
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

writeXrayConfig() {
    local xrayPort="$1"
    local wsPath="$2"
    local domain="$3"
    local new_uuid
    local USERS_FILE="${USERS_FILE:-/usr/local/etc/xray/users.conf}"
    # Если users.conf уже есть — берём UUID первого пользователя
    if [ -f "$USERS_FILE" ] && [ -s "$USERS_FILE" ]; then
        new_uuid=$(cut -d'|' -f1 "$USERS_FILE" | head -1)
    fi
    [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
    mkdir -p /usr/local/etc/xray /var/log/xray
    chmod 755 /var/log/xray

    cat > "$configPath" << EOF
{
    "log": {
        "access": "none",
        "error": "/var/log/xray/error.log",
        "loglevel": "error"
    },
    "inbounds": [{
        "port": $xrayPort,
        "listen": "127.0.0.1",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$new_uuid"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "ws",
            "wsSettings": {
                "path": "$wsPath",
                "host": "$domain",
                "heartbeatPeriod": 30
            },
            "sockopt": {
                "tcpKeepAliveIdle": 100,
                "tcpKeepAliveInterval": 10,
                "tcpKeepAliveRetry": 3
            }
        },
        "sniffing": {"enabled": false}
    }],
    "outbounds": [
        {
            "tag": "free",
            "protocol": "freedom",
            "settings": {"domainStrategy": "UseIPv4"}
        },
        {
            "tag": "warp",
            "protocol": "socks",
            "settings": {"servers": [{"address": "127.0.0.1", "port": 40000}]}
        },
        {
            "tag": "block",
            "protocol": "blackhole"
        }
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "ip": ["geoip:private"],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "domain": [
                    "domain:openai.com",
                    "domain:chatgpt.com",
                    "domain:oaistatic.com",
                    "domain:oaiusercontent.com",
                    "domain:auth0.openai.com"
                ],
                "outboundTag": "warp"
            },
            {
                "type": "field",
                "port": "0-65535",
                "outboundTag": "free"
            }
        ]
    }
}
EOF
}

getConfigInfo() {
    if [ ! -f "$configPath" ]; then
        echo "${red}$(msg xray_not_installed)${reset}" >&2
        return 1
    fi
    xray_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$configPath" 2>/dev/null)
    # Поддержка и ws и xhttp (обратная совместимость)
    xray_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // .inbounds[0].streamSettings.xhttpSettings.path' "$configPath" 2>/dev/null)
    xray_port=$(jq -r '.inbounds[0].port' "$configPath" 2>/dev/null)
    xray_userDomain=$(jq -r '.inbounds[0].streamSettings.wsSettings.host // .inbounds[0].streamSettings.xhttpSettings.host // ""' "$configPath" 2>/dev/null)
    if [ -z "$xray_userDomain" ] || [ "$xray_userDomain" = "null" ]; then
        xray_userDomain=$(grep -E '^\s*server_name\s+' "$nginxPath" 2>/dev/null \
            | grep -v 'proxy_ssl' \
            | grep -v 'server_name\s*_;' \
            | awk '{print $2}' | tr -d ';' | grep -v '^_$' | head -1)
    fi
    [ -z "$xray_userDomain" ] && xray_userDomain=$(getServerIP)

    if [ -z "$xray_uuid" ] || [ "$xray_uuid" = "null" ]; then
        echo "${red}$(msg xray_not_installed)${reset}" >&2
        return 1
    fi
}

getShareUrl() {
    local label="${1:-default}"
    getConfigInfo || return 1
    local encoded_path name
    encoded_path=$(python3 -c \
        "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe='/'))" \
        "$xray_path" 2>/dev/null) || encoded_path="$xray_path"
    name=$(_getConfigName "WS" "$label")
    # URL-кодируем имя для фрагмента (#)
    local encoded_name
    encoded_name=$(python3 -c \
        "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" \
        "$name" 2>/dev/null) || encoded_name="$name"
    echo "vless://${xray_uuid}@${xray_userDomain}:443?encryption=none&security=tls&sni=${xray_userDomain}&fp=chrome&type=ws&host=${xray_userDomain}&path=${encoded_path}#${encoded_name}"
}

# JSON конфиг для ручного импорта (v2rayNG Custom config, Nekoray и др.)
_getWsJsonConfig() {
    local uuid="$1" domain="$2" path="$3"
    cat << JSONEOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": 10808, "listen": "127.0.0.1", "protocol": "socks",
    "settings": {"auth": "noauth", "udp": true}
  }],
  "outbounds": [
    {
      "tag": "proxy", "protocol": "vless",
      "settings": {
        "vnext": [{"address": "${domain}", "port": 443,
          "users": [{"id": "${uuid}", "encryption": "none"}]}]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${domain}",
          "fingerprint": "chrome",
          "alpn": ["http/1.1"]
        },
        "wsSettings": {
          "path": "${path}",
          "headers": {"Host": "${domain}"}
        }
      }
    },
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block",  "protocol": "blackhole"}
  ],
  "routing": {"rules": [{"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"}]}
}
JSONEOF
}

getQrCode() {
    command -v qrencode &>/dev/null || installPackage "qrencode"
    local has_ws=false has_reality=false

    [ -f "$configPath" ] && has_ws=true
    [ -f "$realityConfigPath" ] && has_reality=true

    if ! $has_ws && ! $has_reality; then
        echo "${red}$(msg xray_not_installed)${reset}"
        return 1
    fi

    if $has_ws; then
        getConfigInfo || return 1
        local url name
        name=$(_getConfigName "WS" "default")
        url=$(getShareUrl "default")

        echo -e "${cyan}================================================================${reset}"
        echo -e "   WebSocket+TLS — форматы подключения"
        echo -e "${cyan}================================================================${reset}\n"

        echo -e "${cyan}[ 1. URI ссылка (v2rayNG / Hiddify / Nekoray) ]${reset}"
        qrencode -s 1 -m 1 -t ANSIUTF8 "$url" 2>/dev/null || true
        echo -e "\n${green}${url}${reset}\n"

        echo -e "${cyan}[ 2. Clash Meta / Mihomo ]${reset}"
        echo -e "${yellow}- name: ${name}
  type: vless
  server: ${xray_userDomain}
  port: 443
  uuid: ${xray_uuid}
  tls: true
  servername: ${xray_userDomain}
  client-fingerprint: chrome
  network: ws
  ws-opts:
    path: ${xray_path}
    headers:
      Host: ${xray_userDomain}${reset}\n"

        echo -e "${cyan}================================================================${reset}"
    fi

    if $has_reality; then
        echo -e "\n${cyan}=== Vless Reality ===${reset}"
        showRealityQR
    fi
}

# Валидация домена: только hostname без протокола и пути
_validateDomain() {
    local d="$1"
    d=$(echo "$d" | sed 's|https\?://||' | sed 's|/.*||' | tr -d ' ')
    if [[ ! "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    echo "$d"
}

# Валидация URL: должен начинаться с https://
_validateUrl() {
    local u="$1"
    u=$(echo "$u" | tr -d ' ')
    if [[ ! "$u" =~ ^https://[a-zA-Z0-9] ]]; then
        return 1
    fi
    echo "$u"
}

# Валидация порта: 1024-65535
_validatePort() {
    local p="$1"
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1024 ] || [ "$p" -gt 65535 ]; then
        return 1
    fi
    echo "$p"
}

modifyXrayUUID() {
    if [ -f "$USERS_FILE" ] && [ -s "$USERS_FILE" ]; then
        # Генерируем новый UUID для каждого пользователя
        local tmp
        tmp=$(mktemp)
        while IFS='|' read -r uuid label token; do
            [ -z "$uuid" ] && continue
            local new_uuid
            new_uuid=$(cat /proc/sys/kernel/random/uuid)
            echo "${new_uuid}|${label}|${token}"
        done < "$USERS_FILE" > "$tmp"
        mv "$tmp" "$USERS_FILE"
        # Синхронизируем оба конфига
        _applyUsersToConfigs
        echo "${green}$(msg new_uuid) — все пользователи обновлены${reset}"
        cat "$USERS_FILE" | while IFS='|' read -r uuid label token; do
            echo "  $label → $uuid"
        done
    else
        # Нет users.conf — меняем только в конфигах напрямую
        local new_uuid
        new_uuid=$(cat /proc/sys/kernel/random/uuid)
        [ -f "$configPath" ] && jq ".inbounds[0].settings.clients[0].id = \"$new_uuid\"" \
            "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
        [ -f "$realityConfigPath" ] && jq ".inbounds[0].settings.clients[0].id = \"$new_uuid\"" \
            "$realityConfigPath" > "${realityConfigPath}.tmp" && mv "${realityConfigPath}.tmp" "$realityConfigPath"
        systemctl restart xray xray-reality 2>/dev/null || true
        echo "${green}$(msg new_uuid): $new_uuid${reset}"
    fi
}

modifyXrayPort() {
    local oldPort
    oldPort=$(jq ".inbounds[0].port" "$configPath")
    read -rp "$(msg enter_new_port) [$oldPort]: " xrayPort
    [ -z "$xrayPort" ] && return
    if ! _validatePort "$xrayPort" &>/dev/null; then
        echo "${red}$(msg invalid_port)${reset}"; return 1
    fi
    jq ".inbounds[0].port = $xrayPort" \
        "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    sed -i "s|127.0.0.1:${oldPort}|127.0.0.1:${xrayPort}|g" "$nginxPath"
    systemctl restart xray nginx
    echo "${green}$(msg port_changed) $xrayPort${reset}"
}

modifyWsPath() {
    local oldPath
    oldPath=$(jq -r ".inbounds[0].streamSettings.wsSettings.path" "$configPath")
    read -rp "$(msg enter_new_path)" wsPath
    [ -z "$wsPath" ] && wsPath=$(generateRandomPath)
    wsPath=$(echo "$wsPath" | tr -cd 'A-Za-z0-9/_-')
    [[ ! "$wsPath" =~ ^/ ]] && wsPath="/$wsPath"

    local oldPathEscaped newPathEscaped
    oldPathEscaped=$(printf '%s\n' "$oldPath" | sed 's|[[\.*^$()+?{|]|\\&|g')
    newPathEscaped=$(printf '%s\n' "$wsPath" | sed 's|[[\.*^$()+?{|]|\\&|g')
    sed -i "s|location ${oldPathEscaped}|location ${newPathEscaped}|g" "$nginxPath"

    jq ".inbounds[0].streamSettings.wsSettings.path = \"$wsPath\"" \
        "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    systemctl restart xray nginx
    echo "${green}$(msg new_path): $wsPath${reset}"
}

modifyProxyPassUrl() {
    read -rp "$(msg enter_proxy_url)" newUrl
    [ -z "$newUrl" ] && return
    if ! _validateUrl "$newUrl" &>/dev/null; then
        echo "${red}$(msg invalid) URL. $(msg enter_proxy_url)${reset}"; return 1
    fi
    local oldUrl
    oldUrl=$(grep "proxy_pass" "$nginxPath" | grep -v "127.0.0.1" | awk '{print $2}' | tr -d ';' | head -1)
    local oldUrlEscaped newUrlEscaped
    oldUrlEscaped=$(printf '%s\n' "$oldUrl" | sed 's|[[\.*^$()+?{|]|\\&|g')
    newUrlEscaped=$(printf '%s\n' "$newUrl" | sed 's|[[\.*^$()+?{|]|\\&|g')
    sed -i "s|${oldUrlEscaped}|${newUrlEscaped}|g" "$nginxPath"
    systemctl reload nginx
    echo "${green}$(msg proxy_updated)${reset}"
}

modifyDomain() {
    getConfigInfo || return 1
    echo "$(msg current_domain): $xray_userDomain"
    read -rp "$(msg enter_new_domain)" new_domain
    [ -z "$new_domain" ] && return
    local validated
    if ! validated=$(_validateDomain "$new_domain"); then
        echo "${red}$(msg invalid): '$new_domain'${reset}"; return 1
    fi
    new_domain="$validated"
    sed -i "s/server_name ${xray_userDomain};/server_name ${new_domain};/" "$nginxPath"
    jq ".inbounds[0].streamSettings.wsSettings.host = \"$new_domain\"" \
        "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    userDomain="$new_domain"
    configCert
    systemctl restart nginx xray
}

CONNECT_HOST_FILE="/usr/local/etc/xray/connect_host"

getConnectHost() {
    local h
    h=$(cat "$CONNECT_HOST_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$h" ]; then
        echo "$h"
    else
        # Fallback на основной домен
        jq -r '.inbounds[0].streamSettings.wsSettings.host // ""' "$configPath" 2>/dev/null
    fi
}

modifyConnectHost() {
    local current
    current=$(cat "$CONNECT_HOST_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$current" ]; then
        echo "Текущий адрес подключения: ${green}${current}${reset}"
    else
        getConfigInfo || return 1
        echo "Текущий адрес подключения: ${green}${xray_userDomain}${reset} (основной домен)"
    fi
    echo ""
    echo "Введите CDN домен для подключения (Enter = сбросить на основной домен):"
    read -rp "> " new_host
    if [ -z "$new_host" ]; then
        rm -f "$CONNECT_HOST_FILE"
        echo "${green}Адрес подключения сброшен на основной домен${reset}"
    else
        local validated
        if ! validated=$(_validateDomain "$new_host"); then
            echo "${red}$(msg invalid): '$new_host'${reset}"; return 1
        fi
        echo "$validated" > "$CONNECT_HOST_FILE"
        echo "${green}Адрес подключения: $validated${reset}"
    fi
    # Пересоздаём подписки с новым адресом
    rebuildAllSubFiles 2>/dev/null || true
}


# Определяет активный транспорт: "ws" или "grpc"
# Логика: смотрим на listen 443 ssl http2 в nginx (признак gRPC режима)
# и дополнительно проверяем xray-grpc сервис
getActiveTransport() {
    # Первичный признак — nginx конфиг (http2 включается только при gRPC)
    if grep -q 'listen 443 ssl http2;' "$nginxPath" 2>/dev/null; then
        echo "grpc"
    elif systemctl is-active --quiet xray-grpc 2>/dev/null && \
         ! systemctl is-active --quiet xray 2>/dev/null; then
        echo "grpc"
    else
        echo "ws"
    fi
}

# Обновляет location gRPC в nginx при смене serviceName
_writeNginxGrpc() {
    [ ! -f "$grpcConfigPath" ] && return 1
    local grpcPort grpcService oldService
    grpcPort=$(jq -r '.inbounds[0].port' "$grpcConfigPath" 2>/dev/null)
    grpcService=$(jq -r '.inbounds[0].streamSettings.grpcSettings.serviceName' "$grpcConfigPath" 2>/dev/null)
    # Заменяем serviceName в nginx location и grpc_pass
    oldService=$(grep -oP '(?<=location /).*(?=/Tun)' "$nginxPath" 2>/dev/null | head -1)
    if [ -n "$oldService" ] && [ "$oldService" != "$grpcService" ]; then
        sed -i "s|location /${oldService}/Tun|location /${grpcService}/Tun|g" "$nginxPath"
    fi
    # Обновляем grpc_pass порт
    sed -i "s|grpc://127.0.0.1:[0-9]*|grpc://127.0.0.1:${grpcPort}|g" "$nginxPath"
}

writeGrpcConfig() {
    local grpcPort="$1"
    local grpcService="$2"
    local new_uuid
    local USERS_FILE="${USERS_FILE:-/usr/local/etc/xray/users.conf}"
    if [ -f "$USERS_FILE" ] && [ -s "$USERS_FILE" ]; then
        new_uuid=$(cut -d'|' -f1 "$USERS_FILE" | head -1)
    fi
    [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
    mkdir -p /usr/local/etc/xray /var/log/xray
    chmod 755 /var/log/xray

    cat > "$grpcConfigPath" << GRPCEOF
{
    "log": {
        "access": "none",
        "error": "/var/log/xray/error.log",
        "loglevel": "error"
    },
    "inbounds": [{
        "port": $grpcPort,
        "listen": "127.0.0.1",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$new_uuid"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "grpc",
            "grpcSettings": {
                "serviceName": "$grpcService",
                "multiMode": false,
                "idle_timeout": 60,
                "health_check_timeout": 20,
                "permit_without_stream": false,
                "initial_windows_size": 0
            },
            "sockopt": {
                "tcpKeepAliveIdle": 100,
                "tcpKeepAliveInterval": 10,
                "tcpKeepAliveRetry": 3,
                "tcpFastOpen": true,
                "mark": 0
            }
        },
        "sniffing": {"enabled": false}
    }],
    "outbounds": [
        {
            "tag": "free",
            "protocol": "freedom",
            "settings": {"domainStrategy": "UseIPv4"}
        },
        {
            "tag": "warp",
            "protocol": "socks",
            "settings": {"servers": [{"address": "127.0.0.1", "port": 40000}]}
        },
        {
            "tag": "block",
            "protocol": "blackhole"
        }
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "ip": ["geoip:private"],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "domain": [
                    "domain:openai.com",
                    "domain:chatgpt.com",
                    "domain:oaistatic.com",
                    "domain:oaiusercontent.com",
                    "domain:auth0.openai.com"
                ],
                "outboundTag": "warp"
            },
            {
                "type": "field",
                "port": "0-65535",
                "outboundTag": "free"
            }
        ]
    }
}
GRPCEOF
}

setupGrpcService() {
    cat > /etc/systemd/system/xray-grpc.service << 'SVC'
[Unit]
Description=Xray VLESS+gRPC Service
After=network.target

[Service]
User=nobody
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config-grpc.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload
    systemctl enable xray-grpc
}

switchTransport() {
    local current
    current=$(getActiveTransport)
    if [ "$current" = "ws" ]; then
        [ ! -f "$grpcConfigPath" ] && { echo "${red}$(msg grpc_not_setup)${reset}"; return 1; }
        systemctl stop xray 2>/dev/null || true
        sed -i 's/listen 443 ssl;/listen 443 ssl http2;/' "$nginxPath"
        systemctl start xray-grpc
        nginx -t && systemctl reload nginx
        rebuildAllSubFiles 2>/dev/null || true
        echo "${green}$(msg grpc_switched_grpc)${reset}"
    else
        [ ! -f "$configPath" ] && { echo "${red}$(msg xray_not_installed)${reset}"; return 1; }
        systemctl stop xray-grpc 2>/dev/null || true
        sed -i 's/listen 443 ssl http2;/listen 443 ssl;/' "$nginxPath"
        systemctl start xray
        nginx -t && systemctl reload nginx
        rebuildAllSubFiles 2>/dev/null || true
        echo "${green}$(msg grpc_switched_ws)${reset}"
    fi
}



modifyGrpcPort() {
    [ ! -f "$grpcConfigPath" ] && { echo "${red}$(msg grpc_not_setup)${reset}"; return 1; }
    local oldPort
    oldPort=$(jq '.inbounds[0].port' "$grpcConfigPath")
    read -rp "$(msg enter_new_port) [$oldPort]: " grpcPort
    [ -z "$grpcPort" ] && return
    if ! _validatePort "$grpcPort" &>/dev/null; then
        echo "${red}$(msg invalid_port)${reset}"; return 1
    fi
    jq ".inbounds[0].port = $grpcPort" \
        "$grpcConfigPath" > "${grpcConfigPath}.tmp" && mv "${grpcConfigPath}.tmp" "$grpcConfigPath"
    if [ "$(getActiveTransport)" = "grpc" ]; then
        sed -i "s|grpc://127.0.0.1:${oldPort}|grpc://127.0.0.1:${grpcPort}|g" "$nginxPath"
        nginx -t && systemctl reload nginx
    fi
    systemctl restart xray-grpc 2>/dev/null || true
    echo "${green}$(msg port_changed) $grpcPort${reset}"
}

modifyGrpcPath() {
    [ ! -f "$grpcConfigPath" ] && { echo "${red}$(msg grpc_not_setup)${reset}"; return 1; }
    local oldService
    oldService=$(jq -r '.inbounds[0].streamSettings.grpcSettings.serviceName' "$grpcConfigPath")
    read -rp "$(msg enter_new_path) [$oldService]: " grpcService
    [ -z "$grpcService" ] && grpcService=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 12)
    grpcService=$(echo "$grpcService" | tr -cd 'A-Za-z0-9_-')
    jq ".inbounds[0].streamSettings.grpcSettings.serviceName = \"$grpcService\"" \
        "$grpcConfigPath" > "${grpcConfigPath}.tmp" && mv "${grpcConfigPath}.tmp" "$grpcConfigPath"
    if [ "$(getActiveTransport)" = "grpc" ]; then
        _writeNginxGrpc
        nginx -t && systemctl reload nginx
    fi
    systemctl restart xray-grpc 2>/dev/null || true
    echo "${green}$(msg new_path): $grpcService${reset}"
}

getGrpcShareUrl() {
    local label="${1:-default}"
    [ ! -f "$grpcConfigPath" ] && return 1
    local uuid domain grpcPort grpcService connect_host flag name encoded_name server_ip
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$grpcConfigPath" 2>/dev/null)
    grpcPort=$(jq -r '.inbounds[0].port' "$grpcConfigPath" 2>/dev/null)
    grpcService=$(jq -r '.inbounds[0].streamSettings.grpcSettings.serviceName' "$grpcConfigPath" 2>/dev/null)
    domain=$(jq -r '.inbounds[0].streamSettings.wsSettings.host // ""' "$configPath" 2>/dev/null)
    [ -z "$domain" ] && domain=$(grep -E '^\s*server_name\s+' "$nginxPath" 2>/dev/null | awk '{print $2}' | tr -d ';' | head -1)
    connect_host=$(cat "$CONNECT_HOST_FILE" 2>/dev/null | tr -d '[:space:]')
    [ -z "$connect_host" ] && connect_host="$domain"
    server_ip=$(getServerIP)
    flag=$(_getCountryFlag "$server_ip")
    name="${flag} VL-gRPC-CDN | ${label} ${flag}"
    encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$name" 2>/dev/null || echo "$name")
    echo "vless://${uuid}@${connect_host}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&type=grpc&serviceName=${grpcService}&mode=gun&host=${domain}#${encoded_name}"
}


updateXrayCore() {
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    systemctl restart xray xray-grpc xray-reality 2>/dev/null || true
    echo "${green}$(msg xray_updated)${reset}"
}
