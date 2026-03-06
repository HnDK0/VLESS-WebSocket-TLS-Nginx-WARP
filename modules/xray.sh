#!/bin/bash
# =================================================================
# xray.sh — Конфиг Xray XHTTP+TLS, изменение параметров, QR-код
# =================================================================

installXray() {
    command -v xray &>/dev/null && { echo "info: xray already installed."; return; }
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

writeXrayConfig() {
    local xrayPort="$1"
    local xhttpPath="$2"
    local domain="$3"
    local new_uuid
    new_uuid=$(cat /proc/sys/kernel/random/uuid)
    mkdir -p /usr/local/etc/xray /var/log/xray

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
            "network": "xhttp",
            "xhttpSettings": {
                "path": "$xhttpPath",
                "host": "$domain",
                "mode": "stream-one"
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
    xray_path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // .inbounds[0].streamSettings.wsSettings.path' "$configPath" 2>/dev/null)
    xray_port=$(jq -r '.inbounds[0].port' "$configPath" 2>/dev/null)
    # Сначала берём domain из xhttpSettings.host (надёжнее чем grep nginx)
    xray_userDomain=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.host // ""' "$configPath" 2>/dev/null)
    if [ -z "$xray_userDomain" ] || [ "$xray_userDomain" = "null" ]; then
        xray_userDomain=$(grep -E '^\s*server_name\s+' "$nginxPath" 2>/dev/null \
            | grep -v 'proxy_ssl' \
            | grep -v 'server_name\s*_;' \
            | awk '{print $2}' | tr -d ';' | grep -v '^_$' | head -1)
    fi
    [ -z "$xray_userDomain" ] && xray_userDomain=$(_getPublicIP 2>/dev/null || getServerIP)

    if [ -z "$xray_uuid" ] || [ "$xray_uuid" = "null" ]; then
        echo "${red}$(msg xray_not_installed)${reset}" >&2
        return 1
    fi
}

getShareUrl() {
    getConfigInfo || return 1
    local encoded_path
    encoded_path=$(python3 -c \
        "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" \
        "$xray_path" 2>/dev/null) || encoded_path=$(printf '%s' "$xray_path" | sed 's|/|%2F|g')
    echo "vless://${xray_uuid}@${xray_userDomain}:443?encryption=none&security=tls&sni=${xray_userDomain}&fp=chrome&type=xhttp&host=${xray_userDomain}&path=${encoded_path}#${xray_userDomain}"
}


# ── SUBSCRIPTION ──────────────────────────────────────────────────
# Файлы лежат в /usr/local/etc/xray/sub/<username>.txt
# Nginx отдаёт их через location /sub/ (прописан в writeNginxConfig)
# URL: https://<domain>/sub/<username>.txt

SUB_DIR="/usr/local/etc/xray/sub"

# Строит base64-файл подписки для одного пользователя
buildUserSubFile() {
    local uuid="$1" label="$2"
    local safe_label
    safe_label=$(echo "$label" | tr -cd 'A-Za-z0-9_-')
    mkdir -p "$SUB_DIR"

    local lines=""

    # XHTTP ссылка
    if [ -f "$configPath" ]; then
        local xp xd xep
        xp=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // .inbounds[0].streamSettings.wsSettings.path' "$configPath" 2>/dev/null)
        xd=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.host // ""' "$configPath" 2>/dev/null)
        [ -z "$xd" ] || [ "$xd" = "null" ] && \
            xd=$(grep -E '^\s*server_name\s+' "$nginxPath" 2>/dev/null | grep -v '_' | awk '{print $2}' | tr -d ';' | head -1)
        xep=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe=''))" "$xp" 2>/dev/null)
        lines+="vless://${uuid}@${xd}:443?encryption=none&security=tls&sni=${xd}&fp=chrome&type=xhttp&host=${xd}&path=${xep}#${label}"$'\n'
    fi

    # Reality ссылка
    if [ -f "$realityConfigPath" ]; then
        local r_port r_shortId r_destHost r_pubKey r_serverIP
        r_port=$(jq -r '.inbounds[0].port' "$realityConfigPath" 2>/dev/null)
        r_shortId=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$realityConfigPath" 2>/dev/null)
        r_destHost=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$realityConfigPath" 2>/dev/null)
        r_pubKey=$(grep "PublicKey:" /usr/local/etc/xray/reality_client.txt 2>/dev/null | awk '{print $2}')
        r_serverIP=$(_getPublicIP 2>/dev/null || getServerIP)
        lines+="vless://${uuid}@${r_serverIP}:${r_port}?encryption=none&security=reality&sni=${r_destHost}&fp=chrome&pbk=${r_pubKey}&sid=${r_shortId}&type=tcp&flow=xtls-rprx-vision#${label}-Reality"$'\n'
    fi

    printf '%s' "$lines" | base64 -w 0 > "${SUB_DIR}/${safe_label}.txt"
    chmod 644 "${SUB_DIR}/${safe_label}.txt"
}

# Перестраивает файлы подписки для всех пользователей
rebuildAllSubFiles() {
    [ ! -f "$USERS_FILE" ] && return 0
    while IFS='|' read -r uuid label; do
        [ -z "$uuid" ] && continue
        buildUserSubFile "$uuid" "$label"
    done < "$USERS_FILE"
}

# Возвращает subscription URL для пользователя
getSubUrl() {
    local label="$1"
    local domain
    domain=$(grep -E '^\s*server_name\s+' "$nginxPath" 2>/dev/null | grep -v '_' | awk '{print $2}' | tr -d ';' | head -1)
    local safe_label
    safe_label=$(echo "$label" | tr -cd 'A-Za-z0-9_-')
    echo "https://${domain}/sub/${safe_label}.txt"
}

getQrCode() {
    command -v qrencode &>/dev/null || installPackage "qrencode"
    local has_xhttp=false has_reality=false

    [ -f "$configPath" ] && has_xhttp=true
    [ -f "$realityConfigPath" ] && has_reality=true

    if ! $has_xhttp && ! $has_reality; then
        echo "${red}$(msg xray_not_installed)${reset}"
        return 1
    fi

    if $has_xhttp; then
        echo -e "${cyan}=== Vless XHTTP+TLS ===${reset}"
        local url
        url=$(getShareUrl)
        if [ -n "$url" ]; then
            qrencode -t ANSI "$url" 2>/dev/null || true
            echo -e "\n${green}$url${reset}\n"
        else
            echo "${red}$(msg error): getShareUrl${reset}"
        fi
    fi

    if $has_reality; then
        echo -e "${cyan}=== Vless Reality ===${reset}"
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
    local new_uuid
    new_uuid=$(cat /proc/sys/kernel/random/uuid)
    jq ".inbounds[0].settings.clients[0].id = \"$new_uuid\"" \
        "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    systemctl restart xray
    echo "${green}$(msg new_uuid): $new_uuid${reset}"
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

modifyXhttpPath() {
    local oldPath
    oldPath=$(jq -r ".inbounds[0].streamSettings.xhttpSettings.path" "$configPath")
    read -rp "$(msg enter_new_path)" xhttpPath
    [ -z "$xhttpPath" ] && xhttpPath=$(generateRandomPath)
    # Убираем спецсимволы опасные для sed/nginx
    xhttpPath=$(echo "$xhttpPath" | tr -cd 'A-Za-z0-9/_-')
    [[ ! "$xhttpPath" =~ ^/ ]] && xhttpPath="/$xhttpPath"

    local oldPathEscaped newPathEscaped
    oldPathEscaped=$(printf '%s\n' "$oldPath" | sed 's|[[\.*^$()+?{|]|\\&|g')
    newPathEscaped=$(printf '%s\n' "$xhttpPath" | sed 's|[[\.*^$()+?{|]|\\&|g')
    sed -i "s|location ${oldPathEscaped}|location ${newPathEscaped}|g" "$nginxPath"

    jq ".inbounds[0].streamSettings.xhttpSettings.path = \"$xhttpPath\"" \
        "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    systemctl restart xray nginx
    echo "${green}$(msg new_path): $xhttpPath${reset}"
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
    jq ".inbounds[0].streamSettings.xhttpSettings.host = \"$new_domain\"" \
        "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    userDomain="$new_domain"
    configCert
    systemctl restart nginx xray
}

updateXrayCore() {
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    systemctl restart xray xray-reality 2>/dev/null || true
    echo "${green}$(msg xray_updated)${reset}"
}
