#!/bin/bash
# =================================================================
# reality.sh — VLESS + Reality: конфиг, сервис, управление
# =================================================================

getRealityStatus() {
    if [ -f "$realityConfigPath" ]; then
        local port
        port=$(jq -r '.inbounds[0].port' "$realityConfigPath" 2>/dev/null)
        echo "${green}ON ($(msg reality_port) $port)${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

writeRealityConfig() {
    local realityPort="$1"
    local dest="$2"
    local destHost="${dest%%:*}"

    echo -e "${cyan}$(msg reality_keygen)${reset}"
    local keys privKey pubKey shortId new_uuid

    keys=$(/usr/local/bin/xray x25519 2>/dev/null) || { echo "${red}$(msg reality_keys_fail)${reset}"; return 1; }
    privKey=$(echo "$keys" | tr -d '\r' | awk '/PrivateKey:/{print $2}')
    pubKey=$(echo "$keys"  | tr -d '\r' | awk '/Password:/{print $2}')
    [ -z "$privKey" ] || [ -z "$pubKey" ] && { echo "${red}$(msg reality_keys_err)${reset}"; return 1; }

    shortId=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c1-16)
    new_uuid=$(cat /proc/sys/kernel/random/uuid)

    mkdir -p /usr/local/etc/xray

    cat > "$realityConfigPath" << EOF
{
    "log": {
        "access": "none",
        "error": "/var/log/xray/error.log",
        "loglevel": "error"
    },
    "inbounds": [{
        "port": $realityPort,
        "listen": "0.0.0.0",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$new_uuid", "flow": "xtls-rprx-vision"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": false,
                "dest": "$dest",
                "serverNames": ["$destHost"],
                "privateKey": "$privKey",
                "shortIds": ["$shortId"]
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

    cat > /usr/local/etc/xray/reality_client.txt << EOF
=== Reality параметры для клиента ===
UUID:       $new_uuid
PublicKey:  $pubKey
ShortId:    $shortId
ServerName: $destHost
Port:       $realityPort
Flow:       xtls-rprx-vision
EOF

    echo "${green}$(msg reality_config_ok)${reset}"
    cat /usr/local/etc/xray/reality_client.txt
}

setupRealityService() {
    # Создаём пользователя xray если не существует
    id xray &>/dev/null || useradd -r -s /sbin/nologin -d /usr/local/etc/xray xray
    cat > /etc/systemd/system/xray-reality.service << 'EOF'
[Unit]
Description=Xray Reality Service
After=network.target nss-lookup.target

[Service]
User=xray
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/reality.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray-reality
    systemctl restart xray-reality
    echo "${green}$(msg reality_service_ok)${reset}"
}

installReality() {
    echo -e "${cyan}$(msg reality_setup_title)${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS

    read -rp "$(msg reality_port_prompt)" realityPort
    [ -z "$realityPort" ] && realityPort=8443
    if ! [[ "$realityPort" =~ ^[0-9]+$ ]] || [ "$realityPort" -lt 1024 ] || [ "$realityPort" -gt 65535 ]; then
        echo "${red}$(msg invalid_port)${reset}"; return 1
    fi

    echo -e "${cyan}$(msg reality_dest_title)${reset}"
    echo "1) microsoft.com:443"
    echo "2) www.apple.com:443"
    echo "3) www.amazon.com:443"
    echo "$(msg reality_dest_custom)"
    read -rp "Выбор [1]: " dest_choice
    case "${dest_choice:-1}" in
        1) dest="microsoft.com:443" ;;
        2) dest="www.apple.com:443" ;;
        3) dest="www.amazon.com:443" ;;
        4) read -rp "$(msg reality_dest_prompt)" dest
           [ -z "$dest" ] && { echo "${red}$(msg reality_dest_empty)${reset}"; return 1; } ;;
        *) dest="microsoft.com:443" ;;
    esac

    echo -e "${cyan}$(msg reality_open_port) $realityPort $(msg reality_ufw)${reset}"
    ufw allow "$realityPort"/tcp comment 'Xray Reality' 2>/dev/null || true

    writeRealityConfig "$realityPort" "$dest" || return 1
    setupRealityService || return 1

    # Синхронизируем WARP и Relay домены в новый конфиг
    [ -f "$warpDomainsFile" ] && applyWarpDomains
    [ -f "$relayConfigFile" ] && applyRelayDomains
    [ -f "$psiphonConfigFile" ] && applyPsiphonDomains

    echo -e "\n${green}$(msg reality_installed)${reset}"
    showRealityQR
}

showRealityInfo() {
    [ ! -f "$realityConfigPath" ] && { echo "${red}$(msg reality_not_installed)${reset}"; return 1; }

    local uuid port shortId destHost privKey pubKey serverIP
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$realityConfigPath")
    port=$(jq -r '.inbounds[0].port' "$realityConfigPath")
    shortId=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$realityConfigPath")
    destHost=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$realityConfigPath")
    privKey=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$realityConfigPath")

    local tmpkeys
    tmpkeys=$(/usr/local/bin/xray x25519 2>/dev/null) || true
    pubKey=$(grep "PublicKey:" /usr/local/etc/xray/reality_client.txt 2>/dev/null | awk '{print $2}')

    serverIP=$(getServerIP)

    echo "--------------------------------------------------"
    echo "UUID:        $uuid"
    echo "IP: $serverIP"
    echo "$(msg reality_port): $port"
    echo "PublicKey:   $pubKey"
    echo "ShortId:     $shortId"
    echo "ServerName:  $destHost"
    echo "Flow:        xtls-rprx-vision"
    echo "--------------------------------------------------"
    local url="vless://${uuid}@${serverIP}:${port}?encryption=none&security=reality&sni=${destHost}&fp=chrome&pbk=${pubKey}&sid=${shortId}&type=tcp&flow=xtls-rprx-vision#Reality-${serverIP}"
    echo -e "${green}$url${reset}"
    echo "--------------------------------------------------"
}

showRealityQR() {
    [ ! -f "$realityConfigPath" ] && { echo "${red}$(msg reality_not_installed)${reset}"; return 1; }

    local uuid port shortId destHost pubKey serverIP
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$realityConfigPath")
    port=$(jq -r '.inbounds[0].port' "$realityConfigPath")
    shortId=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$realityConfigPath")
    destHost=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$realityConfigPath")
    pubKey=$(grep "PublicKey:" /usr/local/etc/xray/reality_client.txt 2>/dev/null | awk '{print $2}')
    serverIP=$(getServerIP)

    local url="vless://${uuid}@${serverIP}:${port}?encryption=none&security=reality&sni=${destHost}&fp=chrome&pbk=${pubKey}&sid=${shortId}&type=tcp&flow=xtls-rprx-vision#Reality-${serverIP}"
    command -v qrencode &>/dev/null || installPackage "qrencode"
    qrencode -t ANSI "$url"
    echo -e "\n${green}$url${reset}\n"
}

modifyRealityUUID() {
    [ ! -f "$realityConfigPath" ] && { echo "${red}$(msg reality_not_installed)${reset}"; return 1; }
    local new_uuid
    new_uuid=$(cat /proc/sys/kernel/random/uuid)
    jq ".inbounds[0].settings.clients[0].id = \"$new_uuid\"" \
        "$realityConfigPath" > "${realityConfigPath}.tmp" && mv "${realityConfigPath}.tmp" "$realityConfigPath"
    systemctl restart xray-reality
    echo "${green}New UUID: $new_uuid${reset}"
}

modifyRealityPort() {
    [ ! -f "$realityConfigPath" ] && { echo "${red}$(msg reality_not_installed)${reset}"; return 1; }
    local oldPort
    oldPort=$(jq '.inbounds[0].port' "$realityConfigPath")
    read -rp "$(msg reality_port) [$oldPort]: " newPort
    [ -z "$newPort" ] && return
    if ! [[ "$newPort" =~ ^[0-9]+$ ]] || [ "$newPort" -lt 1024 ] || [ "$newPort" -gt 65535 ]; then
        echo "${red}$(msg invalid_port)${reset}"; return 1
    fi
    ufw allow "$newPort"/tcp comment 'Xray Reality' 2>/dev/null || true
    ufw delete allow "$oldPort"/tcp 2>/dev/null || true
    jq ".inbounds[0].port = $newPort" \
        "$realityConfigPath" > "${realityConfigPath}.tmp" && mv "${realityConfigPath}.tmp" "$realityConfigPath"
    systemctl restart xray-reality
    echo "${green}$(msg reality_port_changed) $newPort${reset}"
}

modifyRealityDest() {
    [ ! -f "$realityConfigPath" ] && { echo "${red}$(msg reality_not_installed)${reset}"; return 1; }
    local oldDest
    oldDest=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest' "$realityConfigPath")
    echo "$(msg reality_current_dest): $oldDest"
    echo "1) microsoft.com:443"
    echo "2) www.apple.com:443"
    echo "3) www.amazon.com:443"
    echo "$(msg reality_dest_custom)"
    read -rp "Выбор: " choice
    case "$choice" in
        1) newDest="microsoft.com:443" ;;
        2) newDest="www.apple.com:443" ;;
        3) newDest="www.amazon.com:443" ;;
        4) read -rp "Введите dest (host:port): " newDest ;;
        *) return ;;
    esac
    local newHost="${newDest%%:*}"
    jq ".inbounds[0].streamSettings.realitySettings.dest = \"$newDest\" |
        .inbounds[0].streamSettings.realitySettings.serverNames = [\"$newHost\"]" \
        "$realityConfigPath" > "${realityConfigPath}.tmp" && mv "${realityConfigPath}.tmp" "$realityConfigPath"
    systemctl restart xray-reality
    echo "${green}$(msg reality_dest_changed) $newDest${reset}"
}

removeReality() {
    echo -e "${red}$(msg reality_remove_confirm) $(msg yes_no)${reset}"
    read -r confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop xray-reality 2>/dev/null || true
        systemctl disable xray-reality 2>/dev/null || true
        rm -f /etc/systemd/system/xray-reality.service
        rm -f "$realityConfigPath" /usr/local/etc/xray/reality_client.txt
        systemctl daemon-reload
        echo "${green}$(msg removed)${reset}"
    fi
}

manageReality() {
    set +e
    while true; do
        clear
        echo -e "${cyan}$(msg reality_title)${reset}"
        echo -e "$(msg status): $(getRealityStatus)"
        echo ""
        echo -e "${green}1.${reset} $(msg reality_install)"
        echo -e "${green}2.${reset} $(msg reality_qr)"
        echo -e "${green}3.${reset} $(msg reality_info)"
        echo -e "${green}4.${reset} $(msg reality_uuid)"
        echo -e "${green}5.${reset} $(msg reality_port)"
        echo -e "${green}6.${reset} $(msg reality_dest)"
        echo -e "${green}7.${reset} $(msg reality_restart)"
        echo -e "${green}8.${reset} $(msg reality_logs)"
        echo -e "${green}9.${reset} $(msg reality_remove)"
        echo -e "${green}0.${reset} $(msg back)"
        echo ""
        read -rp "$(msg choose)" choice
        case $choice in
            1) installReality ;;
            2) showRealityQR ;;
            3) showRealityInfo ;;
            4) modifyRealityUUID ;;
            5) modifyRealityPort ;;
            6) modifyRealityDest ;;
            7) systemctl restart xray-reality && echo "${green}$(msg restarted)${reset}" ;;
            8) journalctl -u xray-reality -n 50 --no-pager ;;
            9) removeReality ;;
            0) break ;;
        esac
        [ "${choice}" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}
