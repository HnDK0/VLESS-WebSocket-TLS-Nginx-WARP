#!/bin/bash
# =================================================================
# users.sh — Управление пользователями
# Формат users.conf: UUID|LABEL|TOKEN
# Sub URL: https://<domain>/sub/<label>_<token>.txt
# =================================================================

USERS_FILE="/usr/local/etc/xray/users.conf"
SUB_DIR="/usr/local/etc/xray/sub"

# ── Утилиты ───────────────────────────────────────────────────────

_usersCount() { [ -f "$USERS_FILE" ] && grep -c '.' "$USERS_FILE" 2>/dev/null || echo 0; }
_uuidByLine()  { sed -n "${1}p" "$USERS_FILE" | cut -d'|' -f1; }
_labelByLine() { sed -n "${1}p" "$USERS_FILE" | cut -d'|' -f2; }
_tokenByLine() { sed -n "${1}p" "$USERS_FILE" | cut -d'|' -f3; }
_genToken()    { head /dev/urandom | tr -dc A-Za-z0-9 | head -c 24; }
_safeLabel()   { echo "$1" | tr -cd 'A-Za-z0-9_-'; }
_subFilename() {
    local label="$1" token="$2"
    local safe
    safe=$(_safeLabel "$label")
    echo "${safe}_${token}.txt"
}

# Получает флаг страны (с кэшем в переменной окружения)
_getCachedFlag() {
    if [ -z "${_VWN_FLAG_CACHE:-}" ]; then
        local ip
        ip=$(getServerIP 2>/dev/null)
        _VWN_FLAG_CACHE=$(_getCountryFlag "$ip" 2>/dev/null || echo "🌐")
        export _VWN_FLAG_CACHE
    fi
    echo "$_VWN_FLAG_CACHE"
}

# Домен из wsSettings.host (с fallback на xhttpSettings для обратной совместимости)
_getDomain() {
    local d=""
    [ -f "$configPath" ] && \
        d=$(jq -r '.inbounds[0].streamSettings.wsSettings.host // .inbounds[0].streamSettings.xhttpSettings.host // ""' "$configPath" 2>/dev/null)
    echo "$d"
}

# ── Применить users.conf в оба конфига Xray ───────────────────────

_applyUsersToConfigs() {
    [ ! -f "$USERS_FILE" ] && return 0

    local clients_r="[" clients_x="[" first_r=true first_x=true
    while IFS='|' read -r uuid label token; do
        [ -z "$uuid" ] && continue
        $first_r || clients_r+=","
        clients_r+="{\"id\":\"${uuid}\",\"flow\":\"xtls-rprx-vision\",\"email\":\"${label}\"}"
        first_r=false
        $first_x || clients_x+=","
        clients_x+="{\"id\":\"${uuid}\",\"email\":\"${label}\"}"
        first_x=false
    done < "$USERS_FILE"
    clients_r+="]"; clients_x+="]"

    if [ -f "$configPath" ]; then
        jq --argjson c "$clients_x" '.inbounds[0].settings.clients = $c' \
            "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    fi
    if [ -f "$realityConfigPath" ]; then
        jq --argjson c "$clients_r" '.inbounds[0].settings.clients = $c' \
            "$realityConfigPath" > "${realityConfigPath}.tmp" && mv "${realityConfigPath}.tmp" "$realityConfigPath"
    fi

    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
}

# ── Инициализация ─────────────────────────────────────────────────

_initUsersFile() {
    [ -f "$USERS_FILE" ] && return 0
    mkdir -p "$(dirname "$USERS_FILE")"

    local existing_uuid=""
    if [ -f "$configPath" ]; then
        existing_uuid=$(jq -r '.inbounds[0].settings.clients[0].id // ""' "$configPath" 2>/dev/null)
    fi
    # Если в WS нет UUID — берём из Reality
    if [ -z "$existing_uuid" ] || [ "$existing_uuid" = "null" ]; then
        if [ -f "$realityConfigPath" ]; then
            existing_uuid=$(jq -r '.inbounds[0].settings.clients[0].id // ""' "$realityConfigPath" 2>/dev/null)
        fi
    fi

    if [ -n "$existing_uuid" ] && [ "$existing_uuid" != "null" ]; then
        local token
        token=$(_genToken)
        echo "${existing_uuid}|default|${token}" > "$USERS_FILE"
        echo "${green}$(msg users_migrated): $existing_uuid${reset}"
        # Синхронизируем UUID в оба конфига
        _applyUsersToConfigs 2>/dev/null || true
        buildUserSubFile "$existing_uuid" "default" "$token" 2>/dev/null || true
    fi
}

# ── Subscription ──────────────────────────────────────────────────

buildUserSubFile() {
    local uuid="$1" label="$2" token="$3"
    mkdir -p "$SUB_DIR"
    applyNginxSub 2>/dev/null || true

    local domain lines="" server_ip flag
    domain=$(_getDomain)
    server_ip=$(getServerIP)
    flag=$(_getCountryFlag "$server_ip")

    local active_transport
    active_transport=$(getActiveTransport 2>/dev/null || echo "ws")

    if [ "$active_transport" = "ws" ] && [ -f "$configPath" ] && [ -n "$domain" ]; then
        local wp wep name encoded_name connect_host
        wp=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // ""' "$configPath" 2>/dev/null)
        wep=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe='/'))" "$wp" 2>/dev/null || echo "$wp")
        connect_host=$(getConnectHost 2>/dev/null || echo "$domain")
        [ -z "$connect_host" ] && connect_host="$domain"
        name="${flag} VL-WS-CDN | ${label} ${flag}"
        encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$name" 2>/dev/null || echo "$name")
        lines+="vless://${uuid}@${connect_host}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&type=ws&host=${domain}&path=${wep}#${encoded_name}"$'\n'
    fi

    if [ "$active_transport" = "grpc" ] && [ -f "$grpcConfigPath" ] && [ -n "$domain" ]; then
        local gp gs g_name g_encoded_name g_connect_host
        gp=$(jq -r '.inbounds[0].streamSettings.grpcSettings.serviceName' "$grpcConfigPath" 2>/dev/null)
        gs=$(jq -r '.inbounds[0].settings.clients[0].id' "$grpcConfigPath" 2>/dev/null)
        g_connect_host=$(getConnectHost 2>/dev/null || echo "$domain")
        [ -z "$g_connect_host" ] && g_connect_host="$domain"
        g_name="${flag} VL-gRPC-CDN | ${label} ${flag}"
        g_encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$g_name" 2>/dev/null || echo "$g_name")
        lines+="vless://${gs}@${g_connect_host}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&type=grpc&serviceName=${gp}&mode=gun&host=${domain}#${g_encoded_name}"$'\n'
    fi

    if [ -f "$realityConfigPath" ]; then
        local r_uuid r_port r_shortId r_destHost r_pubKey r_name r_encoded_name
        r_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$realityConfigPath" 2>/dev/null)
        r_port=$(jq -r '.inbounds[0].port' "$realityConfigPath" 2>/dev/null)
        r_shortId=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$realityConfigPath" 2>/dev/null)
        r_destHost=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$realityConfigPath" 2>/dev/null)
        r_pubKey=$(grep "PublicKey:" /usr/local/etc/xray/reality_client.txt 2>/dev/null | awk '{print $NF}')
        r_name="${flag} VL-Reality | ${label} ${flag}"
        r_encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$r_name" 2>/dev/null || echo "$r_name")
        lines+="vless://${r_uuid}@${server_ip}:${r_port}?encryption=none&security=reality&sni=${r_destHost}&fp=chrome&pbk=${r_pubKey}&sid=${r_shortId}&type=tcp&flow=xtls-rprx-vision#${r_encoded_name}"$'\n'
    fi

    local filename safe
    safe=$(_safeLabel "$label")
    filename=$(_subFilename "$label" "$token")
    # Удаляем старые файлы этого label (любой токен) перед записью нового
    rm -f "${SUB_DIR}/${safe}_"*.txt
    printf '%s' "$lines" | base64 -w 0 > "${SUB_DIR}/${filename}"
    chmod 644 "${SUB_DIR}/${filename}"
}

rebuildAllSubFiles() {
    [ ! -f "$USERS_FILE" ] && return 0
    applyNginxSub 2>/dev/null || true
    local count=0
    while IFS='|' read -r uuid label token; do
        [ -z "$uuid" ] && continue
        buildUserSubFile "$uuid" "$label" "$token" && count=$((count+1))
    done < "$USERS_FILE"
    echo "${green}$(msg done) ($count)${reset}"
}

getSubUrl() {
    local label="$1" token="$2"
    local domain
    domain=$(_getDomain)
    [ -z "$domain" ] && { echo ""; return 1; }
    echo "https://${domain}/sub/$(_subFilename "$label" "$token")"
}

# ── Список ────────────────────────────────────────────────────────

showUsersList() {
    _initUsersFile
    local count
    count=$(_usersCount)
    if [ "$count" -eq 0 ]; then
        echo "${yellow}$(msg users_empty)${reset}"; return 1
    fi
    echo -e "${cyan}$(msg users_list) ($count):${reset}\n"
    local i=1
    while IFS='|' read -r uuid label token; do
        [ -z "$uuid" ] && continue
        printf "  ${green}%2d.${reset} %-20s  %s\n" "$i" "$label" "$uuid"
        i=$((i+1))
    done < "$USERS_FILE"
    echo ""
}

# ── CRUD ──────────────────────────────────────────────────────────

addUser() {
    _initUsersFile
    read -rp "$(msg users_label_prompt)" label
    [ -z "$label" ] && label="user$(( $(_usersCount) + 1 ))"
    label=$(echo "$label" | tr -d '|')
    local uuid token
    uuid=$(cat /proc/sys/kernel/random/uuid)
    token=$(_genToken)
    echo "${uuid}|${label}|${token}" >> "$USERS_FILE"
    _applyUsersToConfigs
    buildUserSubFile "$uuid" "$label" "$token" 2>/dev/null || true
    echo "${green}$(msg users_added): $label ($uuid)${reset}"
}

deleteUser() {
    _initUsersFile
    local count
    count=$(_usersCount)
    [ "$count" -eq 0 ] && { echo "${yellow}$(msg users_empty)${reset}"; return; }
    [ "$count" -eq 1 ] && { echo "${red}$(msg users_last_warn)${reset}"; return; }
    showUsersList
    read -rp "$(msg users_del_prompt)" num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$count" ]; then
        echo "${red}$(msg invalid)${reset}"; return 1
    fi
    local label token safe
    label=$(_labelByLine "$num")
    token=$(_tokenByLine "$num")
    safe=$(_safeLabel "$label")
    echo -e "${red}$(msg users_del_confirm) '$label'? $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "$(msg cancel)"; return 0; }
    rm -f "${SUB_DIR}/${safe}_"*.txt
    sed -i "${num}d" "$USERS_FILE"
    _applyUsersToConfigs
    echo "${green}$(msg removed): $label${reset}"
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
    local uuid old_label token old_safe
    uuid=$(_uuidByLine "$num")
    old_label=$(_labelByLine "$num")
    token=$(_tokenByLine "$num")
    old_safe=$(_safeLabel "$old_label")
    read -rp "$(msg users_new_label) [$old_label]: " new_label
    [ -z "$new_label" ] && return
    new_label=$(echo "$new_label" | tr -d '|')
    rm -f "${SUB_DIR}/${old_safe}_"*.txt
    sed -i "${num}s/.*/${uuid}|${new_label}|${token}/" "$USERS_FILE"
    _applyUsersToConfigs
    buildUserSubFile "$uuid" "$new_label" "$token" 2>/dev/null || true
    echo "${green}$(msg saved): $old_label → $new_label${reset}"
}

# ── QR + Subscription ─────────────────────────────────────────────

showUserQR() {
    _initUsersFile
    local count
    count=$(_usersCount)
    [ "$count" -eq 0 ] && { echo "${yellow}$(msg users_empty)${reset}"; return; }
    showUsersList
    read -rp "$(msg users_qr_prompt)" num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$count" ]; then
        echo "${red}$(msg invalid)${reset}"; return 1
    fi

    local uuid label token
    uuid=$(_uuidByLine "$num")
    label=$(_labelByLine "$num")
    token=$(_tokenByLine "$num")

    command -v qrencode &>/dev/null || installPackage "qrencode"

    local domain
    domain=$(_getDomain)
    local active_transport
    active_transport=$(getActiveTransport 2>/dev/null || echo "ws")

    # WebSocket
    if [ "$active_transport" = "ws" ] && [ -f "$configPath" ] && [ -n "$domain" ]; then
        local wp wep url_ws server_ip flag name encoded_name connect_host
        wp=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // ""' "$configPath" 2>/dev/null)
        wep=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe='/'))" "$wp" 2>/dev/null || echo "$wp")
        server_ip=$(getServerIP)
        flag=$(_getCountryFlag "$server_ip")
        connect_host=$(getConnectHost 2>/dev/null || echo "$domain")
        [ -z "$connect_host" ] && connect_host="$domain"
        name="${flag} VL-WS-CDN | ${label} ${flag}"
        encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$name" 2>/dev/null || echo "$name")
        url_ws="vless://${uuid}@${connect_host}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&type=ws&host=${domain}&path=${wep}#${encoded_name}"

        echo -e "${cyan}================================================================${reset}"
        echo -e "   ${name}"
        echo -e "${cyan}================================================================${reset}\n"

        echo -e "${cyan}[ 1. URI ссылка (v2rayNG / Hiddify / Nekoray) ]${reset}"
        qrencode -s 1 -m 1 -t ANSIUTF8 "$url_ws" 2>/dev/null || true
        echo -e "\n${green}${url_ws}${reset}\n"

        echo -e "${cyan}[ 2. Clash Meta / Mihomo ]${reset}"
        echo -e "${yellow}- name: ${name}
  type: vless
  server: ${connect_host}
  port: 443
  uuid: ${uuid}
  tls: true
  servername: ${domain}
  client-fingerprint: chrome
  network: ws
  ws-opts:
    path: ${wp}
    headers:
      Host: ${domain}${reset}\n"

        echo -e "${cyan}================================================================${reset}"
    fi

    # gRPC
    if [ "$active_transport" = "grpc" ] && [ -f "$grpcConfigPath" ] && [ -n "$domain" ]; then
        local gp gs g_name g_encoded_name g_url g_connect_host
        gp=$(jq -r '.inbounds[0].streamSettings.grpcSettings.serviceName' "$grpcConfigPath" 2>/dev/null)
        gs=$(jq -r '.inbounds[0].settings.clients[0].id' "$grpcConfigPath" 2>/dev/null)
        g_connect_host=$(getConnectHost 2>/dev/null || echo "$domain")
        [ -z "$g_connect_host" ] && g_connect_host="$domain"
        g_name="${flag} VL-gRPC-CDN | ${label} ${flag}"
        g_encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$g_name" 2>/dev/null || echo "$g_name")
        g_url="vless://${gs}@${g_connect_host}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&type=grpc&serviceName=${gp}&mode=gun&host=${domain}#${g_encoded_name}"

        echo -e "
${cyan}================================================================${reset}"
        echo -e "   ${g_name}"
        echo -e "${cyan}================================================================${reset}
"
        echo -e "${cyan}[ URI (v2rayNG / Hiddify / Nekoray) ]${reset}"
        qrencode -s 1 -m 1 -t ANSIUTF8 "$g_url" 2>/dev/null || true
        echo -e "
${green}${g_url}${reset}
"
        echo -e "${cyan}[ Clash Meta / Mihomo ]${reset}"
        echo -e "${yellow}- name: ${g_name}
  type: vless
  server: ${g_connect_host}
  port: 443
  uuid: ${gs}
  tls: true
  servername: ${domain}
  client-fingerprint: chrome
  network: grpc
  grpc-opts:
    grpc-service-name: ${gp}${reset}
"
        echo -e "${cyan}================================================================${reset}"
    fi

    # Reality
    if [ -f "$realityConfigPath" ]; then
        local r_uuid r_port r_shortId r_destHost r_pubKey r_serverIP r_flag r_name r_encoded_name url_reality
        r_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$realityConfigPath" 2>/dev/null)
        r_port=$(jq -r '.inbounds[0].port' "$realityConfigPath" 2>/dev/null)
        r_shortId=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$realityConfigPath" 2>/dev/null)
        r_destHost=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$realityConfigPath" 2>/dev/null)
        r_pubKey=$(grep "PublicKey:" /usr/local/etc/xray/reality_client.txt 2>/dev/null | awk '{print $NF}')
        r_serverIP=$(getServerIP)
        r_flag=$(_getCountryFlag "$r_serverIP")
        r_name="${r_flag} VL-Reality | ${label} ${r_flag}"
        r_encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$r_name" 2>/dev/null || echo "$r_name")
        url_reality="vless://${r_uuid}@${r_serverIP}:${r_port}?encryption=none&security=reality&sni=${r_destHost}&fp=chrome&pbk=${r_pubKey}&sid=${r_shortId}&type=tcp&flow=xtls-rprx-vision#${r_encoded_name}"

        echo -e "\n${cyan}=== ${r_name} ===${reset}"
        qrencode -s 1 -m 1 -t ANSIUTF8 "$url_reality" 2>/dev/null || true
        echo -e "\n${green}${url_reality}${reset}\n"
    fi

    # Subscription URL
    buildUserSubFile "$uuid" "$label" "$token" 2>/dev/null || true
    local sub_url
    sub_url=$(getSubUrl "$label" "$token")
    if [ -n "$sub_url" ]; then
        echo -e "${cyan}[ Subscription URL — все протоколы сразу ]${reset}"
        qrencode -s 1 -m 1 -t ANSIUTF8 "$sub_url" 2>/dev/null || true
        echo -e "\n${green}${sub_url}${reset}"
        echo -e "${yellow}v2rayNG: + → Subscription group → URL${reset}"
    fi

    echo -e "\n${cyan}================================================================${reset}"
}

# ── Меню ──────────────────────────────────────────────────────────

manageUsers() {
    set +e
    _initUsersFile
    while true; do
        clear
        echo -e "${cyan}$(msg users_title)${reset}\n"
        showUsersList
        echo -e "${green}1.${reset} $(msg users_add)"
        echo -e "${green}2.${reset} $(msg users_del)"
        echo -e "${green}3.${reset} QR + Subscription URL"
        echo -e "${green}4.${reset} $(msg users_rename)"
        echo -e "${green}5.${reset} $(msg menu_sub)"
        echo ""
        echo -e "${green}0.${reset} $(msg back)"
        echo ""
        read -rp "$(msg choose)" choice
        case $choice in
            1) addUser ;;
            2) deleteUser ;;
            3) showUserQR ;;
            4) renameUser ;;
            5) rebuildAllSubFiles ;;
            0) break ;;
        esac
        [ "$choice" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}
