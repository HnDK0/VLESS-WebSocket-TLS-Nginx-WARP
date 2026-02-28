#!/bin/bash
# =================================================================
# xray.sh — Конфиг Xray WS+TLS, изменение параметров, QR-код
# =================================================================

installXray() {
    command -v xray &>/dev/null && { echo "info: xray already installed."; return; }
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

writeXrayConfig() {
    local xrayPort="$1"
    local wsPath="$2"
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
            "network": "ws",
            "wsSettings": {
                "path": "$wsPath",
                "headers": {}
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
    xray_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // .inbounds[0].streamSettings.xhttpSettings.path' "$configPath" 2>/dev/null)
    xray_port=$(jq -r '.inbounds[0].port' "$configPath" 2>/dev/null)
    # Ищем строго "server_name", исключая proxy_ssl_server_name и server_name _
    xray_userDomain=$(grep -E '^\s*server_name\s+' "$nginxPath" 2>/dev/null \
        | grep -v 'proxy_ssl' \
        | grep -v 'server_name\s*_;' \
        | awk '{print $2}' | tr -d ';' | grep -v '^_$' | head -1)
    [ -z "$xray_userDomain" ] && xray_userDomain=$(_getPublicIP 2>/dev/null || getServerIP)

    if [ -z "$xray_uuid" ] || [ "$xray_uuid" = "null" ]; then
        echo "${red}$(msg xray_not_installed)${reset}" >&2
        return 1
    fi
}

getShareUrl() {
    getConfigInfo || return 1
    local encoded_path network
    encoded_path=$(python3 -c \
        "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" \
        "$xray_path" 2>/dev/null) || encoded_path=$(printf '%s' "$xray_path" | sed 's|/|%2F|g')
    network=$(jq -r '.inbounds[0].streamSettings.network' "$configPath" 2>/dev/null)
    case "$network" in
        xhttp|h2|h3)
            echo "vless://${xray_uuid}@${xray_userDomain}:443?encryption=none&security=tls&sni=${xray_userDomain}&type=xhttp&host=${xray_userDomain}&path=${encoded_path}&flow=xtls-rprx-vision#${xray_userDomain}"
            ;;
        *)
            echo "vless://${xray_uuid}@${xray_userDomain}:443?encryption=none&security=tls&sni=${xray_userDomain}&type=ws&host=${xray_userDomain}&path=${encoded_path}#${xray_userDomain}"
            ;;
    esac
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
        echo -e "${cyan}=== Vless WS+TLS ===${reset}"
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
    if ! [[ "$xrayPort" =~ ^[0-9]+$ ]] || [ "$xrayPort" -lt 1024 ] || [ "$xrayPort" -gt 65535 ]; then
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
    [[ ! "$wsPath" =~ ^/ ]] && wsPath="/$wsPath"

    local oldPathEscaped newPathEscaped
    oldPathEscaped=$(echo "$oldPath" | sed 's|/|\\/|g')
    newPathEscaped=$(echo "$wsPath" | sed 's|/|\\/|g')
    sed -i "s|location ${oldPathEscaped}|location ${newPathEscaped}|g" "$nginxPath"

    jq ".inbounds[0].streamSettings.wsSettings.path = \"$wsPath\"" \
        "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    systemctl restart xray nginx
    echo "${green}$(msg new_path): $wsPath${reset}"
}

modifyProxyPassUrl() {
    read -rp "$(msg enter_proxy_url)" newUrl
    [ -z "$newUrl" ] && return
    local oldUrl
    oldUrl=$(grep "proxy_pass" "$nginxPath" | grep -v "127.0.0.1" | awk '{print $2}' | tr -d ';' | head -1)
    local oldUrlEscaped newUrlEscaped
    oldUrlEscaped=$(echo "$oldUrl" | sed 's|[/&]|\\&|g')
    newUrlEscaped=$(echo "$newUrl" | sed 's|[/&]|\\&|g')
    sed -i "s|${oldUrlEscaped}|${newUrlEscaped}|g" "$nginxPath"
    systemctl reload nginx
    echo "${green}$(msg proxy_updated)${reset}"
}

modifyDomain() {
    getConfigInfo || return 1
    echo "$(msg current_domain): $xray_userDomain"
    read -rp "$(msg enter_new_domain)" new_domain
    [ -z "$new_domain" ] && return
    sed -i "s/server_name ${xray_userDomain};/server_name ${new_domain};/" "$nginxPath"
    userDomain="$new_domain"
    configCert
    systemctl restart nginx xray
}

updateXrayCore() {
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    systemctl restart xray xray-reality 2>/dev/null || true
    echo "${green}$(msg xray_updated)${reset}"
}
