#!/bin/bash
# =================================================================
# reality.sh — VLESS + Reality: конфиг, сервис, управление
# =================================================================

getRealityStatus() {
    if [ -f "$realityConfigPath" ]; then
        local port
        port=$(jq -r '.inbounds[0].port' "$realityConfigPath" 2>/dev/null)
        echo "${green}ON (порт $port)${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

writeRealityConfig() {
    local realityPort="$1"
    local dest="$2"
    local destHost="${dest%%:*}"

    echo -e "${cyan}Генерация ключей Reality...${reset}"
    local keys privKey pubKey shortId new_uuid

    keys=$(/usr/local/bin/xray x25519 2>/dev/null) || { echo "${red}Ошибка: xray x25519 не работает${reset}"; return 1; }
    privKey=$(echo "$keys" | tr -d '\r' | awk '/PrivateKey:/{print $2}')
    pubKey=$(echo "$keys"  | tr -d '\r' | awk '/Password:/{print $2}')
    [ -z "$privKey" ] || [ -z "$pubKey" ] && { echo "${red}Ошибка получения ключей${reset}"; return 1; }

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

    echo "${green}Reality конфиг создан.${reset}"
    cat /usr/local/etc/xray/reality_client.txt
}

setupRealityService() {
    cat > /etc/systemd/system/xray-reality.service << 'EOF'
[Unit]
Description=Xray Reality Service
After=network.target nss-lookup.target

[Service]
User=nobody
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
    echo "${green}xray-reality сервис запущен.${reset}"
}

installReality() {
    echo -e "${cyan}=== Установка VLESS + Reality ===${reset}"

    read -rp "Порт Reality [8443]: " realityPort
    [ -z "$realityPort" ] && realityPort=8443
    if ! [[ "$realityPort" =~ ^[0-9]+$ ]] || [ "$realityPort" -lt 1024 ] || [ "$realityPort" -gt 65535 ]; then
        echo "${red}Некорректный порт.${reset}"; return 1
    fi

    echo -e "${cyan}Сайт для маскировки (dest):${reset}"
    echo "1) microsoft.com:443"
    echo "2) www.apple.com:443"
    echo "3) www.amazon.com:443"
    echo "4) Ввести свой"
    read -rp "Выбор [1]: " dest_choice
    case "${dest_choice:-1}" in
        1) dest="microsoft.com:443" ;;
        2) dest="www.apple.com:443" ;;
        3) dest="www.amazon.com:443" ;;
        4) read -rp "Введите dest (host:port): " dest
           [ -z "$dest" ] && { echo "${red}Dest не указан.${reset}"; return 1; } ;;
        *) dest="microsoft.com:443" ;;
    esac

    echo -e "${cyan}Открываем порт $realityPort в UFW...${reset}"
    ufw allow "$realityPort"/tcp comment 'Xray Reality' 2>/dev/null || true

    writeRealityConfig "$realityPort" "$dest" || return 1
    setupRealityService || return 1

    # Синхронизируем WARP и Relay домены в новый конфиг
    [ -f "$warpDomainsFile" ] && applyWarpDomains
    [ -f "$relayConfigFile" ] && applyRelayDomains
    [ -f "$psiphonConfigFile" ] && applyPsiphonDomains

    echo -e "\n${green}Reality установлен!${reset}"
    showRealityQR
}

showRealityInfo() {
    [ ! -f "$realityConfigPath" ] && { echo "${red}Reality не установлен.${reset}"; return 1; }

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
    echo "IP сервера:  $serverIP"
    echo "Порт:        $port"
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
    [ ! -f "$realityConfigPath" ] && { echo "${red}Reality не установлен.${reset}"; return 1; }

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
    [ ! -f "$realityConfigPath" ] && { echo "${red}Reality не установлен.${reset}"; return 1; }
    local new_uuid
    new_uuid=$(cat /proc/sys/kernel/random/uuid)
    jq ".inbounds[0].settings.clients[0].id = \"$new_uuid\"" \
        "$realityConfigPath" > "${realityConfigPath}.tmp" && mv "${realityConfigPath}.tmp" "$realityConfigPath"
    systemctl restart xray-reality
    echo "${green}New UUID: $new_uuid${reset}"
}

modifyRealityPort() {
    [ ! -f "$realityConfigPath" ] && { echo "${red}Reality не установлен.${reset}"; return 1; }
    local oldPort
    oldPort=$(jq '.inbounds[0].port' "$realityConfigPath")
    read -rp "Новый порт [$oldPort]: " newPort
    [ -z "$newPort" ] && return
    if ! [[ "$newPort" =~ ^[0-9]+$ ]] || [ "$newPort" -lt 1024 ] || [ "$newPort" -gt 65535 ]; then
        echo "${red}Некорректный порт.${reset}"; return 1
    fi
    ufw allow "$newPort"/tcp comment 'Xray Reality' 2>/dev/null || true
    ufw delete allow "$oldPort"/tcp 2>/dev/null || true
    jq ".inbounds[0].port = $newPort" \
        "$realityConfigPath" > "${realityConfigPath}.tmp" && mv "${realityConfigPath}.tmp" "$realityConfigPath"
    systemctl restart xray-reality
    echo "${green}Порт Reality изменён на $newPort${reset}"
}

modifyRealityDest() {
    [ ! -f "$realityConfigPath" ] && { echo "${red}Reality не установлен.${reset}"; return 1; }
    local oldDest
    oldDest=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest' "$realityConfigPath")
    echo "Текущий dest: $oldDest"
    echo "1) microsoft.com:443"
    echo "2) www.apple.com:443"
    echo "3) www.amazon.com:443"
    echo "4) Ввести свой"
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
    echo "${green}Dest изменён на $newDest${reset}"
}

removeReality() {
    echo -e "${red}Удалить Reality? (y/n)${reset}"
    read -r confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop xray-reality 2>/dev/null || true
        systemctl disable xray-reality 2>/dev/null || true
        rm -f /etc/systemd/system/xray-reality.service
        rm -f "$realityConfigPath" /usr/local/etc/xray/reality_client.txt
        systemctl daemon-reload
        echo "${green}Reality удалён.${reset}"
    fi
}

manageReality() {
    set +e
    while true; do
        clear
        echo -e "${cyan}=== Управление VLESS + Reality ===${reset}"
        echo -e "Статус: $(getRealityStatus)"
        echo ""
        echo -e "${green}1.${reset} Установить Reality"
        echo -e "${green}2.${reset} Показать QR-код и ссылку"
        echo -e "${green}3.${reset} Показать параметры клиента"
        echo -e "${green}4.${reset} Сменить UUID"
        echo -e "${green}5.${reset} Изменить порт"
        echo -e "${green}6.${reset} Изменить dest (сайт маскировки)"
        echo -e "${green}7.${reset} Перезапустить сервис"
        echo -e "${green}8.${reset} Логи Reality"
        echo -e "${green}9.${reset} Удалить Reality"
        echo -e "${green}0.${reset} Назад"
        echo ""
        read -rp "Выберите: " choice
        case $choice in
            1) installReality ;;
            2) showRealityQR ;;
            3) showRealityInfo ;;
            4) modifyRealityUUID ;;
            5) modifyRealityPort ;;
            6) modifyRealityDest ;;
            7) systemctl restart xray-reality && echo "${green}Перезапущен.${reset}" ;;
            8) journalctl -u xray-reality -n 50 --no-pager ;;
            9) removeReality ;;
            0) break ;;
        esac
        echo -e "\n${cyan}Нажмите Enter...${reset}"
        read -r
    done
}
