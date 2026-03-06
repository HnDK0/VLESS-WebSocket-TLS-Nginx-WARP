#!/bin/bash
# =================================================================
# users.sh — Управление пользователями (multi-UUID)
# Метки хранятся в /usr/local/etc/xray/users.conf
# Формат: UUID|LABEL
# =================================================================

USERS_FILE="/usr/local/etc/xray/users.conf"

# ── Внутренние утилиты ────────────────────────────────────────────

_usersCount() {
    [ -f "$USERS_FILE" ] && grep -c '.' "$USERS_FILE" 2>/dev/null || echo 0
}

_usersList() {
    [ -f "$USERS_FILE" ] && cat "$USERS_FILE" || true
}

_uuidByLine() {
    sed -n "${1}p" "$USERS_FILE" | cut -d'|' -f1
}

_labelByLine() {
    sed -n "${1}p" "$USERS_FILE" | cut -d'|' -f2
}

# Применяет текущий users.conf в оба конфига Xray
_applyUsersToConfigs() {
    [ ! -f "$USERS_FILE" ] && return 0

    # Формируем JSON массив клиентов
    local clients_json="["
    local first=true
    while IFS='|' read -r uuid label; do
        [ -z "$uuid" ] && continue
        $first || clients_json+=","
        clients_json+="{\"id\":\"${uuid}\",\"flow\":\"xtls-rprx-vision\",\"email\":\"${label}\"}"
        first=false
    done < "$USERS_FILE"
    clients_json+="]"

    # XHTTP конфиг — без flow (flow только для Reality/TCP)
    local clients_json_ws="["
    first=true
    while IFS='|' read -r uuid label; do
        [ -z "$uuid" ] && continue
        $first || clients_json_ws+=","
        clients_json_ws+="{\"id\":\"${uuid}\",\"email\":\"${label}\"}"
        first=false
    done < "$USERS_FILE"
    clients_json_ws+="]"

    if [ -f "$configPath" ]; then
        jq --argjson c "$clients_json_ws" \
            '.inbounds[0].settings.clients = $c' \
            "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    fi

    if [ -f "$realityConfigPath" ]; then
        jq --argjson c "$clients_json" \
            '.inbounds[0].settings.clients = $c' \
            "$realityConfigPath" > "${realityConfigPath}.tmp" && mv "${realityConfigPath}.tmp" "$realityConfigPath"
    fi

    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
}

# Инициализация — если users.conf не существует, создаём из текущего конфига
_initUsersFile() {
    if [ -f "$USERS_FILE" ]; then return 0; fi
    mkdir -p "$(dirname "$USERS_FILE")"

    # Берём существующий UUID из xray конфига
    local existing_uuid=""
    if [ -f "$configPath" ]; then
        existing_uuid=$(jq -r '.inbounds[0].settings.clients[0].id // ""' "$configPath" 2>/dev/null)
    elif [ -f "$realityConfigPath" ]; then
        existing_uuid=$(jq -r '.inbounds[0].settings.clients[0].id // ""' "$realityConfigPath" 2>/dev/null)
    fi

    if [ -n "$existing_uuid" ] && [ "$existing_uuid" != "null" ]; then
        echo "${existing_uuid}|default" > "$USERS_FILE"
        echo "${green}$(msg users_migrated): $existing_uuid${reset}"
    fi
}

# ── Команды ───────────────────────────────────────────────────────

showUsersList() {
    _initUsersFile
    local count
    count=$(_usersCount)
    if [ "$count" -eq 0 ]; then
        echo "${yellow}$(msg users_empty)${reset}"; return
    fi

    echo -e "${cyan}$(msg users_list) ($count):${reset}"
    echo ""
    local i=1
    while IFS='|' read -r uuid label; do
        [ -z "$uuid" ] && continue
        printf "  ${green}%2d.${reset} %-20s  %s\n" "$i" "$label" "$uuid"
        i=$((i + 1))
    done < "$USERS_FILE"
    echo ""
}

addUser() {
    _initUsersFile
    read -rp "$(msg users_label_prompt)" label
    [ -z "$label" ] && label="user$(($(  _usersCount) + 1))"
    # Убираем символ | из метки — он используется как разделитель
    label=$(echo "$label" | tr -d '|')

    local new_uuid
    new_uuid=$(cat /proc/sys/kernel/random/uuid)
    echo "${new_uuid}|${label}" >> "$USERS_FILE"
    _applyUsersToConfigs
    updateSub &>/dev/null || true
    echo "${green}$(msg users_added): $label ($new_uuid)${reset}"
}

deleteUser() {
    _initUsersFile
    local count
    count=$(_usersCount)
    if [ "$count" -eq 0 ]; then
        echo "${yellow}$(msg users_empty)${reset}"; return
    fi
    if [ "$count" -eq 1 ]; then
        echo "${red}$(msg users_last_warn)${reset}"; return
    fi

    showUsersList
    read -rp "$(msg users_del_prompt)" num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$count" ]; then
        echo "${red}$(msg invalid)${reset}"; return 1
    fi

    local label
    label=$(_labelByLine "$num")
    echo -e "${red}$(msg users_del_confirm) '$label'? $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "$(msg cancel)"; return 0; }

    sed -i "${num}d" "$USERS_FILE"
    _applyUsersToConfigs
    updateSub &>/dev/null || true
    echo "${green}$(msg removed): $label${reset}"
}

showUserQR() {
    _initUsersFile
    local count
    count=$(_usersCount)
    if [ "$count" -eq 0 ]; then
        echo "${yellow}$(msg users_empty)${reset}"; return
    fi

    showUsersList
    read -rp "$(msg users_qr_prompt)" num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$count" ]; then
        echo "${red}$(msg invalid)${reset}"; return 1
    fi

    local uuid label
    uuid=$(_uuidByLine "$num")
    label=$(_labelByLine "$num")

    command -v qrencode &>/dev/null || installPackage "qrencode"

    # XHTTP конфиг
    if [ -f "$configPath" ]; then
        local xray_path xray_userDomain encoded_path
        xray_path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // .inbounds[0].streamSettings.wsSettings.path' "$configPath" 2>/dev/null)
        xray_userDomain=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.host // ""' "$configPath" 2>/dev/null)
        [ -z "$xray_userDomain" ] || [ "$xray_userDomain" = "null" ] && \
            xray_userDomain=$(grep -E '^\s*server_name\s+' "$nginxPath" 2>/dev/null | grep -v '_' | awk '{print $2}' | tr -d ';' | head -1)
        encoded_path=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe=''))" "$xray_path" 2>/dev/null)
        local url_xhttp="vless://${uuid}@${xray_userDomain}:443?encryption=none&security=tls&sni=${xray_userDomain}&fp=chrome&alpn=h2%2Chttp%2F1.1&type=xhttp&host=${xray_userDomain}&path=${encoded_path}#${label}"
        echo -e "${cyan}=== XHTTP+TLS: $label ===${reset}"
        qrencode -t ANSI "$url_xhttp" 2>/dev/null || true
        echo -e "\n${green}$url_xhttp${reset}\n"
    fi

    # Reality конфиг
    if [ -f "$realityConfigPath" ]; then
        local r_port r_shortId r_destHost r_pubKey r_serverIP
        r_port=$(jq -r '.inbounds[0].port' "$realityConfigPath" 2>/dev/null)
        r_shortId=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$realityConfigPath" 2>/dev/null)
        r_destHost=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$realityConfigPath" 2>/dev/null)
        r_pubKey=$(grep "PublicKey:" /usr/local/etc/xray/reality_client.txt 2>/dev/null | awk '{print $2}')
        r_serverIP=$(_getPublicIP 2>/dev/null || getServerIP)
        local url_reality="vless://${uuid}@${r_serverIP}:${r_port}?encryption=none&security=reality&sni=${r_destHost}&fp=chrome&pbk=${r_pubKey}&sid=${r_shortId}&type=tcp&flow=xtls-rprx-vision#${label}-Reality"
        echo -e "${cyan}=== Reality: $label ===${reset}"
        qrencode -t ANSI "$url_reality" 2>/dev/null || true
        echo -e "\n${green}$url_reality${reset}\n"
    fi
}

renameUser() {
    _initUsersFile
    local count
    count=$(_usersCount)
    [ "$count" -eq 0 ] && { echo "${yellow}$(msg users_empty)${reset}"; return; }

    showUsersList
    read -rp "$(msg users_rename_prompt)" num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$count" ]; then
        echo "${red}$(msg invalid)${reset}"; return 1
    fi

    local old_label uuid
    old_label=$(_labelByLine "$num")
    uuid=$(_uuidByLine "$num")
    read -rp "$(msg users_new_label) [$old_label]: " new_label
    [ -z "$new_label" ] && return
    new_label=$(echo "$new_label" | tr -d '|')

    sed -i "${num}s/.*/${uuid}|${new_label}/" "$USERS_FILE"
    _applyUsersToConfigs
    updateSub &>/dev/null || true
    echo "${green}$(msg saved): $old_label → $new_label${reset}"
}

manageUsers() {
    set +e
    _initUsersFile
    while true; do
        clear
        echo -e "${cyan}$(msg users_title)${reset}"
        echo ""
        showUsersList
        echo -e "${green}1.${reset} $(msg users_add)"
        echo -e "${green}2.${reset} $(msg users_del)"
        echo -e "${green}3.${reset} $(msg users_qr)"
        echo -e "${green}4.${reset} $(msg users_rename)"
        echo -e "${green}0.${reset} $(msg back)"
        echo ""
        read -rp "$(msg choose)" choice
        case $choice in
            1) addUser ;;
            2) deleteUser ;;
            3) showUserQR ;;
            4) renameUser ;;
            0) break ;;
        esac
        [ "$choice" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}
