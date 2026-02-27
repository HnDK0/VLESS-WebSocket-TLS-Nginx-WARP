#!/bin/bash
# =================================================================
# Xray VLESS + WebSocket + TLS + Nginx + WARP + CDN + Reality
# Версия: 2.4
# =================================================================

# Цвета для вывода
red=$(tput setaf 1 && tput bold)
green=$(tput setaf 2 && tput bold)
yellow=$(tput setaf 3 && tput bold)
cyan=$(tput setaf 6 && tput bold)
reset=$(tput sgr0)

# Пути
configPath='/usr/local/etc/xray/config.json'
nginxPath='/etc/nginx/conf.d/xray.conf'
cf_key_file="/root/.cloudflare_api"
warpDomainsFile='/usr/local/etc/xray/warp_domains.txt'
relayDomainsFile='/usr/local/etc/xray/relay_domains.txt'
relayConfigFile='/usr/local/etc/xray/relay.conf'
psiphonDomainsFile='/usr/local/etc/xray/psiphon_domains.txt'
psiphonConfigFile='/usr/local/etc/xray/psiphon.json'
psiphonBin='/usr/local/bin/psiphon-tunnel-core'

# --- ХУКИ ДЛЯ ACME.SH ---
case "${1:-}" in
    "open-80")
        ufw status | grep -q inactive && exit 0
        ufw allow from any to any port 80 proto tcp comment 'ACME temp' &>/dev/null
        exit 0
        ;;
    "close-80")
        ufw status | grep -q inactive && exit 0
        ufw status numbered | grep 'ACME temp' | awk -F"[][]" '{print $2}' | sort -rn | while read -r n; do
            echo "y" | ufw delete "$n" &>/dev/null
        done
        exit 0
        ;;
esac

# ============================================================
# УТИЛИТЫ
# ============================================================

isRoot() {
    if [[ "$EUID" -ne '0' ]]; then
        echo "${red}error: You must run this script as root!${reset}"
        exit 1
    fi
}

identifyOS() {
    if [[ "$(uname)" != 'Linux' ]]; then
        echo "error: This operating system is not supported."
        exit 1
    fi
    if command -v apt &>/dev/null; then
        PACKAGE_MANAGEMENT_INSTALL='apt -y --no-install-recommends install'
        PACKAGE_MANAGEMENT_REMOVE='apt purge -y'
        PACKAGE_MANAGEMENT_UPDATE='apt update'
    elif command -v dnf &>/dev/null; then
        PACKAGE_MANAGEMENT_INSTALL='dnf -y install'
        PACKAGE_MANAGEMENT_REMOVE='dnf remove -y'
        PACKAGE_MANAGEMENT_UPDATE='dnf update'
    elif command -v yum &>/dev/null; then
        PACKAGE_MANAGEMENT_INSTALL='yum -y install'
        PACKAGE_MANAGEMENT_REMOVE='yum remove -y'
        PACKAGE_MANAGEMENT_UPDATE='yum update'
        ${PACKAGE_MANAGEMENT_INSTALL} 'epel-release' &>/dev/null
    else
        echo "error: Package manager not supported."
        exit 1
    fi
}

installPackage() {
    local package_name="$1"
    if ${PACKAGE_MANAGEMENT_INSTALL} "$package_name" &>/dev/null; then
        echo "info: $package_name installed."
    else
        echo "warn: Fixing dependencies for $package_name..."
        dpkg --configure -a 2>/dev/null || true
        ${PACKAGE_MANAGEMENT_UPDATE} &>/dev/null || true
        if ${PACKAGE_MANAGEMENT_INSTALL} "$package_name"; then
            echo "info: $package_name installed after fix."
        else
            echo "${red}error: Installation of $package_name failed.${reset}"
            return 1
        fi
    fi
}

uninstallPackage() {
    ${PACKAGE_MANAGEMENT_REMOVE} "$1" && echo "info: $1 uninstalled."
}

run_task() {
    local msg="$1"
    shift
    echo -e "\n${yellow}>>> $msg${reset}"
    if eval "$@"; then
        echo -e "[${green} DONE ${reset}] $msg"
    else
        echo -e "[${red} FAIL ${reset}] $msg"
        #      а критические задачи сами решают, умирать ли.
        return 1
    fi
}

# ============================================================
# СТАТУС / ИНФОРМАЦИЯ
# ============================================================

checkCertExpiry() {
    if [ -f /etc/nginx/cert/cert.pem ]; then
        local expire_date
        expire_date=$(openssl x509 -enddate -noout -in /etc/nginx/cert/cert.pem | cut -d= -f2)
        local expire_epoch now_epoch days_left
        expire_epoch=$(date -d "$expire_date" +%s)
        now_epoch=$(date +%s)
        days_left=$(( (expire_epoch - now_epoch) / 86400 ))

        if [ "$days_left" -le 0 ]; then
            echo "${red}SSL: EXPIRED!${reset}"
        elif [ "$days_left" -lt 15 ]; then
            echo "${red}SSL: $days_left days${reset}"
        else
            echo "${green}SSL: OK ($days_left d)${reset}"
        fi
    else
        echo "${red}SSL: MISSING${reset}"
    fi
}

getServiceStatus() {
    if systemctl is-active --quiet "$1"; then
        echo "${green}RUNNING${reset}"
    else
        echo "${red}STOPPED${reset}"
    fi
}

getWarpStatusRaw() {
    if command -v warp-cli &>/dev/null; then
        if warp-cli --accept-tos status 2>/dev/null | grep -q "Connected"; then
            echo "ACTIVE"
        else
            echo "OFF"
        fi
    else
        echo "NOT_INSTALLED"
    fi
}

getBbrStatus() {
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        echo "${green}ON${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

getF2BStatus() {
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo "${green}ON${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

getWebJailStatus() {
    if [ -f /etc/fail2ban/filter.d/nginx-probe.conf ]; then
        if fail2ban-client status nginx-probe &>/dev/null; then
            echo "${green}PROTECTED${reset}"
        else
            echo "${yellow}OFF${reset}"
        fi
    else
        echo "${red}NO${reset}"
    fi
}

getCdnStatus() {
    if [ -f /etc/nginx/conf.d/cloudflare_whitelist.conf ]; then
        echo "${green}ON${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

# ============================================================
# ВСПОМОГАТЕЛЬНЫЕ
# ============================================================

setupAlias() {
    local script_full_path
    script_full_path=$(readlink -f "$0")
    chmod +x "$script_full_path"
    ln -sf "$script_full_path" /usr/local/bin/vwn
    echo -e "${green}Команда 'vwn' доступна.${reset}"
}

generateRandomPath() {
    echo "/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 12)"
}

setNginxCert() {
    [ ! -d '/etc/nginx/cert' ] && mkdir -p '/etc/nginx/cert'
    if [ ! -f /etc/nginx/cert/default.crt ]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout /etc/nginx/cert/default.key \
            -out /etc/nginx/cert/default.crt \
            -subj "/CN=localhost" &>/dev/null
    fi
}

# ============================================================
# CLOUDFLARE CDN
# ============================================================

setupCloudflareIPs() {
    echo -e "${cyan}Настройка Cloudflare IP...${reset}"

    # --- Файл 1: cloudflare_real_ips.conf ---
    # set_real_ip_from + real_ip_header — восстанавливает реальный IP клиента
    # из заголовка CF-Connecting-IP (надёжнее X-Forwarded-For).
    # ВАЖНО: должен быть в контексте http{}, подключается через include в nginx.conf.

    # --- Файл 2: cloudflare_whitelist.conf ---
    # geo-блок для проверки: является ли подключившийся IP адресом Cloudflare.
    # Используется в xray.conf: if ($cloudflare_ip != 1) { return 444; }
    # ВАЖНО: geo{} тоже должен быть в http{}, include в nginx.conf.

    local tmp_r tmp_w
    tmp_r=$(mktemp) && tmp_w=$(mktemp) || return 1
    trap 'rm -f "$tmp_r" "$tmp_w"' RETURN

    # Заголовок real_ip файла
    cat > "$tmp_r" << 'REALIP_HDR'
# Cloudflare real IP restore
# Подключается из http{} в nginx.conf
REALIP_HDR

    # Заголовок whitelist файла
    cat > "$tmp_w" << 'GEO_HDR'
# Cloudflare IP whitelist (geo map)
# Подключается из http{} в nginx.conf
geo $realip_remote_addr $cloudflare_ip {
    default 0;
GEO_HDR

    local ok=0
    for t in v4 v6; do
        local result
        result=$(curl -fsSL --connect-timeout 10 "https://www.cloudflare.com/ips-$t" 2>/dev/null) || {
            echo "${yellow}Предупреждение: не удалось получить Cloudflare ips-$t${reset}"
            continue
        }
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            echo "set_real_ip_from $ip;" >> "$tmp_r"
            echo "    $ip 1;" >> "$tmp_w"
            ok=1
        done < <(echo "$result" | grep -E '^[0-9a-fA-F:.]+(/[0-9]+)?$')
    done

    [ "$ok" -eq 0 ] && { echo "${red}Ошибка: не получен ни один IP Cloudflare.${reset}"; return 1; }

    # CF-Connecting-IP надёжнее X-Forwarded-For — подделать нельзя, т.к. Cloudflare
    # всегда добавляет его сам. X-Forwarded-For может быть подделан клиентом.
    echo "real_ip_header CF-Connecting-IP;" >> "$tmp_r"
    echo "real_ip_recursive on;" >> "$tmp_r"
    echo "}" >> "$tmp_w"

    mkdir -p /etc/nginx/conf.d
    mv -f "$tmp_r" /etc/nginx/conf.d/cloudflare_real_ips.conf
    mv -f "$tmp_w" /etc/nginx/conf.d/cloudflare_whitelist.conf

    # Подключаем оба файла в http{} nginx.conf (если ещё не добавлены)
    # include *.conf из conf.d УЖЕ есть — но geo{} и set_real_ip_from
    # должны идти ДО остальных server{} блоков, поэтому явный include надёжнее.
    for inc in cloudflare_real_ips cloudflare_whitelist; do
        if ! grep -q "${inc}" /etc/nginx/nginx.conf 2>/dev/null; then
            # Вставляем сразу после открывающего http {
            sed -i "/^http {/a\\    include /etc/nginx/conf.d/${inc}.conf;" /etc/nginx/nginx.conf
        fi
    done

    # Проверяем синтаксис до применения
    nginx -t 2>/dev/null || {
        echo "${red}Ошибка синтаксиса nginx после добавления CDN конфигов!${reset}"
        nginx -t
        return 1
    }

    echo "${green}Cloudflare IPs настроены ($(grep -c 'set_real_ip_from' /etc/nginx/conf.d/cloudflare_real_ips.conf) подсетей).${reset}"
}

toggleCdnMode() {
    if [ -f /etc/nginx/conf.d/cloudflare_whitelist.conf ]; then
        echo -e "${yellow}CDN режим активен. Отключить? (y/n)${reset}"
        read -r confirm
        if [[ "$confirm" == "y" ]]; then
            rm -f /etc/nginx/conf.d/cloudflare_whitelist.conf
            rm -f /etc/nginx/conf.d/cloudflare_real_ips.conf
            # Удаляем include строки из nginx.conf
            sed -i '/cloudflare_real_ips\|cloudflare_whitelist/d' /etc/nginx/nginx.conf 2>/dev/null || true
            # Удаляем CF-проверку из xray.conf
            sed -i '/cloudflare_ip.*!=.*1/d' "$nginxPath" 2>/dev/null || true
            nginx -t && systemctl reload nginx
            echo "${green}CDN режим отключен. Прямой доступ разрешён.${reset}"
        fi
    else
        echo -e "${cyan}Включение CDN режима...${reset}"
        setupCloudflareIPs || return 1

        local wsPath
        wsPath=$(jq -r ".inbounds[0].streamSettings.wsSettings.path" "$configPath" 2>/dev/null)

        if [ -n "$wsPath" ] && [ "$wsPath" != "null" ]; then
            # Проверяем, не добавлена ли уже проверка
            if ! grep -q "cloudflare_ip" "$nginxPath" 2>/dev/null; then
                # Вставляем if-блок на строку ПЕРЕД "location $wsPath {"
                # Используем python3 для надёжной вставки (избегаем проблем sed с / в пути)
                python3 - "$nginxPath" "$wsPath" << 'PYEOF'
import sys, re

path = sys.argv[1]
wspath = sys.argv[2]

with open(path, 'r') as f:
    content = f.read()

# Ищем "location <wspath> {" и вставляем проверку перед ним
cf_check = '    if ($cloudflare_ip != 1) { return 444; }\n\n'
pattern = r'(\s+location ' + re.escape(wspath) + r'\s*\{)'
replacement = cf_check + r'\1'
new_content = re.sub(pattern, replacement, content, count=1)

if new_content == content:
    print(f"WARN: location {wspath} не найден в конфиге, CF-проверка не добавлена", file=sys.stderr)
else:
    print(f"OK: CF-проверка добавлена перед location {wspath}")

with open(path, 'w') as f:
    f.write(new_content)
PYEOF
            fi
        fi

        nginx -t || { echo "${red}Ошибка синтаксиса nginx!${reset}"; nginx -t; return 1; }
        systemctl reload nginx
        echo "${green}CDN режим включён! Только Cloudflare IP имеют доступ.${reset}"
    fi
}

# ============================================================
# WARP
# ============================================================

applyWarpDomains() {
    [ ! -f "$warpDomainsFile" ] && printf 'openai.com\nchatgpt.com\ncloudflare.com\n' > "$warpDomainsFile"
    local domains_json
    domains_json=$(awk 'NF {printf "\"domain:%s\",", $1}' "$warpDomainsFile" | sed 's/,$//')

    # Обновляем WS конфиг
    if [ -f "$configPath" ]; then
        jq "(.routing.rules[] | select(.outboundTag == \"warp\")) |= (.domain = [$domains_json] | del(.port))" \
            "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
        systemctl restart xray 2>/dev/null || true
    fi

    # Обновляем Reality конфиг
    if [ -f "$realityConfigPath" ]; then
        jq "(.routing.rules[] | select(.outboundTag == \"warp\")) |= (.domain = [$domains_json] | del(.port))" \
            "$realityConfigPath" > "${realityConfigPath}.tmp" && mv "${realityConfigPath}.tmp" "$realityConfigPath"
        systemctl restart xray-reality 2>/dev/null || true
    fi
}

toggleWarpMode() {
    echo "Выберите режим работы WARP:"
    echo "1) Весь трафик через WARP (Global)"
    echo "2) Только выбранные домены (Split)"
    read -rp "Ваш выбор: " warp_mode

    case "$warp_mode" in
        1)
            for cfg in "$configPath" "$realityConfigPath"; do
                [ -f "$cfg" ] || continue
                jq '(.routing.rules[] | select(.outboundTag == "warp")) |= (.port = "0-65535" | del(.domain))' \
                    "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
            done
            echo "${green}Global: Весь трафик через WARP.${reset}"
            ;;
        2)
            applyWarpDomains
            echo "${green}Split: Только список доменов через WARP.${reset}"
            return
            ;;
        *)
            echo "${red}Отмена.${reset}"; return ;;
    esac
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
}

checkWarpStatus() {
    echo "--------------------------------------------------"
    local real_ip warp_ip
    real_ip=$(getServerIP)
    warp_ip=$(curl -s --connect-timeout 5 -x socks5://127.0.0.1:40000 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || echo "Error/Offline")
    echo "Реальный IP сервера : $real_ip"
    echo "IP через WARP SOCKS : $warp_ip"
    echo "--------------------------------------------------"
}


# ============================================================
# RELAY — VLESS/VMess/Trojan/SOCKS через внешний сервер
# ============================================================

parseRelayUrl() {
    local url="$1"
    local protocol host port uuid security sni pbk sid path ws_host net_type

    protocol=$(echo "$url" | grep -oP "^[a-z0-9]+")

    case "$protocol" in
        vless|trojan)
            uuid=$(echo "$url" | grep -oP "(?<=://)[^@]+")
            host=$(echo "$url" | grep -oP "(?<=@)[^:@]+")
            port=$(echo "$url" | grep -oP ":[0-9]+" | grep -oP "[0-9]+" | head -1)
            security=$(echo "$url" | grep -oP "(?<=security=)[^&#]+")
            sni=$(echo "$url" | grep -oP "(?<=sni=)[^&#]+")
            pbk=$(echo "$url" | grep -oP "(?<=pbk=)[^&#]+")
            sid=$(echo "$url" | grep -oP "(?<=sid=)[^&#]+")
            net_type=$(echo "$url" | grep -oP "(?<=type=)[^&#]+")
            path=$(python3 -c "import urllib.parse,re; m=re.search(r'path=([^&#]+)', '$url'); print(urllib.parse.unquote(m.group(1))) if m else print('/')" 2>/dev/null)
            ws_host=$(echo "$url" | grep -oP "(?<=host=)[^&#]+")
            ;;
        socks5|socks)
            protocol="socks"
            host=$(echo "$url" | grep -oP "(?<=://)[^:@/]+" | head -1)
            port=$(echo "$url" | grep -oP "(?<=:)[0-9]+(?=$|/|#)" | tail -1)
            uuid=""
            security="none"
            net_type="tcp"
            ;;
        vmess)
            local b64 json
            b64=$(echo "$url" | sed 's|vmess://||')
            json=$(echo "$b64" | base64 -d 2>/dev/null)
            host=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('add',''))" 2>/dev/null)
            port=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('port',''))" 2>/dev/null)
            uuid=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
            sni=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sni',''))" 2>/dev/null)
            net_type=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('net','tcp'))" 2>/dev/null)
            path=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('path','/'))" 2>/dev/null)
            ws_host=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('host',''))" 2>/dev/null)
            security=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tls','none'))" 2>/dev/null)
            ;;
        *)
            echo "${red}Неизвестный протокол: $protocol${reset}"; return 1 ;;
    esac

    [ -z "$host" ] || [ -z "$port" ] && { echo "${red}Не удалось распарсить адрес/порт.${reset}"; return 1; }

    cat > "$relayConfigFile" << RELAYEOF
RELAY_PROTOCOL=${protocol}
RELAY_HOST=${host}
RELAY_PORT=${port}
RELAY_UUID=${uuid}
RELAY_SECURITY=${security:-none}
RELAY_SNI=${sni:-}
RELAY_PBK=${pbk:-}
RELAY_SID=${sid:-}
RELAY_NET=${net_type:-tcp}
RELAY_PATH=${path:-/}
RELAY_WS_HOST=${ws_host:-${host}}
RELAYEOF
    echo "${green}Реле настроено: $protocol://$host:$port${reset}"
}

buildRelayOutbound() {
    [ ! -f "$relayConfigFile" ] && return 1
    # shellcheck source=/dev/null
    source "$relayConfigFile"

    local stream_block=""
    if [ "$RELAY_PROTOCOL" != "socks" ]; then
        case "$RELAY_NET" in
            ws)
                stream_block=", \"streamSettings\": {\"network\": \"ws\", \"security\": \"${RELAY_SECURITY}\", \"wsSettings\": {\"path\": \"${RELAY_PATH}\", \"headers\": {\"Host\": \"${RELAY_WS_HOST}\"}}, \"tlsSettings\": {\"serverName\": \"${RELAY_SNI}\", \"allowInsecure\": false}}"
                ;;
            tcp)
                if [ "$RELAY_SECURITY" = "reality" ]; then
                    stream_block=", \"streamSettings\": {\"network\": \"tcp\", \"security\": \"reality\", \"realitySettings\": {\"serverName\": \"${RELAY_SNI}\", \"publicKey\": \"${RELAY_PBK}\", \"shortId\": \"${RELAY_SID}\", \"fingerprint\": \"chrome\"}}"
                else
                    stream_block=", \"streamSettings\": {\"network\": \"tcp\", \"security\": \"${RELAY_SECURITY}\"}"
                fi
                ;;
            *)
                stream_block=", \"streamSettings\": {\"network\": \"${RELAY_NET}\", \"security\": \"${RELAY_SECURITY}\"}"
                ;;
        esac
    fi

    if [ "$RELAY_PROTOCOL" = "socks" ]; then
        echo "{\"tag\": \"relay\", \"protocol\": \"socks\", \"settings\": {\"servers\": [{\"address\": \"${RELAY_HOST}\", \"port\": ${RELAY_PORT}}]}}"
    elif [ "$RELAY_PROTOCOL" = "vmess" ]; then
        echo "{\"tag\": \"relay\", \"protocol\": \"vmess\", \"settings\": {\"vnext\": [{\"address\": \"${RELAY_HOST}\", \"port\": ${RELAY_PORT}, \"users\": [{\"id\": \"${RELAY_UUID}\", \"alterId\": 0, \"security\": \"auto\"}]}]}${stream_block}}"
    else
        echo "{\"tag\": \"relay\", \"protocol\": \"${RELAY_PROTOCOL}\", \"settings\": {\"vnext\": [{\"address\": \"${RELAY_HOST}\", \"port\": ${RELAY_PORT}, \"users\": [{\"id\": \"${RELAY_UUID}\", \"encryption\": \"none\", \"flow\": \"xtls-rprx-vision\"}]}]}${stream_block}}"
    fi
}

getRelayStatus() {
    if [ ! -f "$relayConfigFile" ]; then
        echo "${red}OFF${reset}"; return
    fi
    # shellcheck source=/dev/null
    source "$relayConfigFile"
    local mode="Split"
    if [ -f "$configPath" ]; then
        if jq -e '.routing.rules[] | select(.outboundTag=="relay" and .port=="0-65535")' "$configPath" &>/dev/null 2>&1; then
            mode="Global"
        fi
    fi
    echo "${green}ON ($RELAY_PROTOCOL://$RELAY_HOST:$RELAY_PORT | $mode)${reset}"
}

applyRelayToConfigs() {
    [ ! -f "$relayConfigFile" ] && { echo "${red}Реле не настроено.${reset}"; return 1; }
    local relay_outbound
    relay_outbound=$(buildRelayOutbound) || return 1

    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        local has_relay
        has_relay=$(jq '.outbounds[] | select(.tag=="relay")' "$cfg" 2>/dev/null)
        if [ -z "$has_relay" ]; then
            jq --argjson ob "$relay_outbound" '.outbounds += [$ob]' \
                "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
        else
            jq --argjson ob "$relay_outbound" '(.outbounds[] | select(.tag=="relay")) |= $ob' \
                "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
        fi
        local has_rule
        has_rule=$(jq '.routing.rules[] | select(.outboundTag=="relay")' "$cfg" 2>/dev/null)
        if [ -z "$has_rule" ]; then
            # Вставляем правило relay ПЕРЕД правилом warp (индекс 1)
            jq '.routing.rules = [.routing.rules[0]] + [{"type":"field","domain":[],"outboundTag":"relay"}] + .routing.rules[1:]' \
                "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
        fi
    done
}

removeRelayFromConfigs() {
    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        jq 'del(.outbounds[] | select(.tag=="relay")) | del(.routing.rules[] | select(.outboundTag=="relay"))' \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    done
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
}

applyRelayDomains() {
    [ ! -f "$relayConfigFile" ] && { echo "${red}Реле не настроено.${reset}"; return 1; }
    [ ! -f "$relayDomainsFile" ] && touch "$relayDomainsFile"
    local domains_json
    domains_json=$(awk 'NF {printf "\"domain:%s\",", $1}' "$relayDomainsFile" | sed 's/,$//')

    applyRelayToConfigs || return 1

    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        jq "(.routing.rules[] | select(.outboundTag == \"relay\")) |= (.domain = [$domains_json] | del(.port))" \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    done
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
    echo "${green}Relay Split применён.${reset}"
}

toggleRelayGlobal() {
    applyRelayToConfigs || return 1
    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        jq '(.routing.rules[] | select(.outboundTag == "relay")) |= (.port = "0-65535" | del(.domain))' \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    done
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
    echo "${green}Relay Global: весь трафик через реле.${reset}"
}

manageRelay() {
    set +e
    while true; do
        clear
        local s_relay
        s_relay=$(getRelayStatus)
        echo -e "${cyan}=== Управление Relay ===${reset}"
        echo -e "Статус: $s_relay"
        echo ""
        if [ -f "$relayConfigFile" ]; then
            # shellcheck source=/dev/null
            source "$relayConfigFile"
            echo -e "  Сервер: ${green}$RELAY_PROTOCOL://$RELAY_HOST:$RELAY_PORT${reset}"
            [ -f "$relayDomainsFile" ] && echo -e "  Доменов: $(wc -l < "$relayDomainsFile")"
        fi
        echo ""
        echo -e "${green}1.${reset} Настроить реле (вставить ссылку)"
        echo -e "${green}2.${reset} Переключить режим (Global/Split)"
        echo -e "${green}3.${reset} Добавить домен в список"
        echo -e "${green}4.${reset} Удалить домен из списка"
        echo -e "${green}5.${reset} Редактировать список доменов (Nano)"
        echo -e "${green}6.${reset} Проверить IP через реле"
        echo -e "${green}7.${reset} Удалить реле"
        echo -e "${green}0.${reset} Назад"
        echo ""
        read -rp "Выберите: " choice
        case $choice in
            1)
                echo "Вставьте ссылку (vless:// vmess:// trojan:// socks5://):"
                read -rp "> " relay_url
                [ -z "$relay_url" ] && continue
                parseRelayUrl "$relay_url" || { read -r; continue; }
                applyRelayDomains
                ;;
            2)
                [ ! -f "$relayConfigFile" ] && { echo "${red}Сначала настройте реле (п.1)${reset}"; read -r; continue; }
                echo "1) Global — весь трафик через реле"
                echo "2) Split — только список доменов"
                read -rp "Выбор: " mode
                case "$mode" in
                    1) toggleRelayGlobal ;;
                    2) applyRelayDomains ;;
                esac
                ;;
            3)
                [ ! -f "$relayConfigFile" ] && { echo "${red}Сначала настройте реле (п.1)${reset}"; read -r; continue; }
                read -rp "Домен (например netflix.com): " domain
                [ -z "$domain" ] && continue
                echo "$domain" >> "$relayDomainsFile"
                sort -u "$relayDomainsFile" -o "$relayDomainsFile"
                applyRelayDomains
                echo "${green}Домен $domain добавлен.${reset}"
                ;;
            4)
                [ ! -f "$relayDomainsFile" ] && { echo "Список пуст"; read -r; continue; }
                nl "$relayDomainsFile"
                read -rp "Номер для удаления: " num
                [[ "$num" =~ ^[0-9]+$ ]] && sed -i "${num}d" "$relayDomainsFile" && applyRelayDomains
                ;;
            5)
                [ ! -f "$relayDomainsFile" ] && touch "$relayDomainsFile"
                nano "$relayDomainsFile"
                applyRelayDomains
                ;;
            6)
                [ ! -f "$relayConfigFile" ] && { echo "${red}Реле не настроено.${reset}"; read -r; continue; }
                source "$relayConfigFile"
                echo "Реальный IP сервера : $(getServerIP)"
                echo "Проверка через реле..."

                if [ "$RELAY_PROTOCOL" = "socks" ]; then
                    relay_ip=$(curl -s --connect-timeout 8 -x "socks5://$RELAY_HOST:$RELAY_PORT" https://api.ipify.org 2>/dev/null || echo "Недоступен")
                else
                    # Запускаем временный Xray с SOCKS5 inbound → relay outbound
                    local relay_outbound
                    relay_outbound=$(buildRelayOutbound)
                    cat > /tmp/relay_test.json << TESTEOF
{
    "log": {"loglevel": "none"},
    "inbounds": [{
        "port": 19999, "listen": "127.0.0.1",
        "protocol": "socks",
        "settings": {"auth": "noauth", "udp": false}
    }],
    "outbounds": [$relay_outbound]
}
TESTEOF
                    /usr/local/bin/xray run -config /tmp/relay_test.json &>/dev/null &
                    local xray_pid=$!
                    sleep 3
                    relay_ip=$(curl -s --connect-timeout 10 -x socks5://127.0.0.1:19999 https://api.ipify.org 2>/dev/null || echo "Недоступен")
                    kill $xray_pid 2>/dev/null
                    rm -f /tmp/relay_test.json
                fi

                echo "IP через реле       : $relay_ip"
                ;;
            7)
                echo -e "${red}Удалить реле? (y/n)${reset}"
                read -r confirm
                if [[ "$confirm" == "y" ]]; then
                    removeRelayFromConfigs
                    rm -f "$relayConfigFile"
                    echo "${green}Реле удалено.${reset}"
                fi
                ;;
            0) break ;;
        esac
        echo -e "\n${cyan}Нажмите Enter...${reset}"
        read -r
    done
}


addDomainToWarpProxy() {
    read -rp "Домен для WARP (например, netflix.com): " domain
    [ -z "$domain" ] && return
    [ ! -f "$warpDomainsFile" ] && touch "$warpDomainsFile"
    if ! grep -q "^${domain}$" "$warpDomainsFile"; then
        echo "$domain" >> "$warpDomainsFile"
        sort -u "$warpDomainsFile" -o "$warpDomainsFile"
        applyWarpDomains
        echo "${green}Домен $domain добавлен.${reset}"
    else
        echo "${yellow}Домен уже в списке.${reset}"
    fi
}

deleteDomainFromWarpProxy() {
    if [ ! -f "$warpDomainsFile" ]; then echo "Список пуст"; return; fi
    echo "Текущие домены в WARP:"
    nl "$warpDomainsFile"
    read -rp "Введите номер для удаления: " num
    if [[ "$num" =~ ^[0-9]+$ ]]; then
        sed -i "${num}d" "$warpDomainsFile"
        applyWarpDomains
        echo "${green}Домен удален.${reset}"
    fi
}

# ============================================================
# SSL
# ============================================================

openPort80() {
    ufw status | grep -q inactive && return
    ufw allow from any to any port 80 proto tcp comment 'ACME temp'
}

closePort80() {
    ufw status | grep -q inactive && return
    ufw status numbered | grep 'ACME temp' | awk -F"[][]" '{print $2}' | sort -rn | while read -r n; do
        echo "y" | ufw delete "$n"
    done
}

configCert() {
    if [[ -z "${userDomain:-}" ]]; then
        read -rp "Введите домен для выпуска SSL: " userDomain
    fi
    [ -z "$userDomain" ] && { echo "${red}Домен не задан.${reset}"; return 1; }

    echo -e "\n${cyan}Метод SSL:${reset}"
    echo "1) Cloudflare DNS API (порт 80 не нужен)"
    echo "2) Standalone (временно открыть порт 80)"
    read -rp "Ваш выбор: " cert_method

    installPackage "socat" || true
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl -fsSL https://get.acme.sh | sh -s email="acme@${userDomain}"
    fi

    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    if [ "$cert_method" == "1" ]; then
        [ -f "$cf_key_file" ] && source "$cf_key_file"
        if [[ -z "${CF_Email:-}" || -z "${CF_Key:-}" ]]; then
            echo "${green}Настройка Cloudflare DNS API:${reset}"
            read -rp "Cloudflare Email: " CF_Email
            read -rp "Cloudflare Global API Key: " CF_Key
            printf "export CF_Email='%s'\nexport CF_Key='%s'\n" "$CF_Email" "$CF_Key" > "$cf_key_file"
            chmod 600 "$cf_key_file"
        fi
        export CF_Email CF_Key
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$userDomain" --force
    else
        openPort80
        ~/.acme.sh/acme.sh --issue --standalone -d "$userDomain" \
            --pre-hook "/usr/local/bin/vwn open-80" \
            --post-hook "/usr/local/bin/vwn close-80" \
            --force
        closePort80
    fi

    mkdir -p /etc/nginx/cert
    ~/.acme.sh/acme.sh --install-cert -d "$userDomain" \
        --key-file /etc/nginx/cert/cert.key \
        --fullchain-file /etc/nginx/cert/cert.pem \
        --reloadcmd "systemctl reload nginx"

    echo "${green}SSL успешно настроен для $userDomain${reset}"
}

# ============================================================
# УСТАНОВКА КОМПОНЕНТОВ
# ============================================================

installXray() {
    command -v xray &>/dev/null && { echo "info: xray уже установлен."; return; }
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

installWarp() {
    command -v warp-cli &>/dev/null && { echo "info: warp-cli уже установлен."; return; }
    if command -v apt &>/dev/null; then
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
            | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
            | tee /etc/apt/sources.list.d/cloudflare-client.list
    else
        curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
            | tee /etc/yum.repos.d/cloudflare-warp.repo
    fi
    ${PACKAGE_MANAGEMENT_UPDATE} &>/dev/null
    installPackage "cloudflare-warp"
}

configWarp() {
    systemctl enable --now warp-svc
    sleep 3

    if ! warp-cli --accept-tos registration show &>/dev/null; then
        warp-cli --accept-tos registration delete &>/dev/null || true
        local attempts=0
        while [ $attempts -lt 3 ]; do
            warp-cli --accept-tos registration new && break
            attempts=$((attempts + 1))
            sleep 3
        done
    fi

    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos set-proxy-port 40000 2>/dev/null || true
    warp-cli --accept-tos connect
    sleep 5

    local warp_check
    warp_check=$(curl -s --connect-timeout 8 -x socks5://127.0.0.1:40000 \
        https://www.cloudflare.com/cdn-cgi/trace/ 2>/dev/null | grep 'warp=')
    if [[ "$warp_check" == *"warp=on"* ]] || [[ "$warp_check" == *"warp=plus"* ]]; then
        echo "${green}WARP успешно подключен! ($warp_check)${reset}"
    else
        echo "${yellow}WARP запущен, но проверка не прошла. Продолжаем...${reset}"
    fi
}

# ============================================================
# КОНФИГУРАЦИОННЫЕ ФАЙЛЫ
# ============================================================

writeXrayConfig() {
    local xrayPort="$1"
    local wsPath="$2"
    local new_uuid
    new_uuid=$(cat /proc/sys/kernel/random/uuid)

    mkdir -p /usr/local/etc/xray /var/log/xray

    #  - sniffing для корректной маршрутизации доменов
    #  - правило блокировки WARP-петель (локальные IP в free outbound)
    #  - fallbacks для случаев некорректных подключений
    #  - log уровень warning вместо none для диагностики
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
        "sniffing": {
            "enabled": false
        }
    }],
    "outbounds": [
        {
            "tag": "free",
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIPv4"
            }
        },
        {
            "tag": "warp",
            "protocol": "socks",
            "settings": {
                "servers": [{"address": "127.0.0.1", "port": 40000}]
            }
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

setupWarpWatchdog() {
    # WARP имеет свойство тихо отваливаться под нагрузкой.
    # Watchdog каждые 2 минуты проверяет SOCKS5 и переподключает если нужно.
    cat > /usr/local/bin/warp-watchdog.sh << 'WDOG'
#!/bin/bash
CHECK_URL="https://www.cloudflare.com/cdn-cgi/trace/"
PROXY="socks5://127.0.0.1:40000"
MAX_LATENCY=5

result=$(curl -s --connect-timeout $MAX_LATENCY -x "$PROXY" "$CHECK_URL" 2>/dev/null)

if echo "$result" | grep -q "warp=on\|warp=plus"; then
    exit 0
fi

logger -t warp-watchdog "WARP не отвечает — переподключение..."
warp-cli --accept-tos disconnect 2>/dev/null
sleep 2
warp-cli --accept-tos connect
sleep 5

# Проверяем ещё раз
result2=$(curl -s --connect-timeout $MAX_LATENCY -x "$PROXY" "$CHECK_URL" 2>/dev/null)
if echo "$result2" | grep -q "warp=on\|warp=plus"; then
    logger -t warp-watchdog "WARP восстановлен."
else
    logger -t warp-watchdog "WARP не восстановился — перезапуск сервиса..."
    systemctl restart warp-svc
    sleep 8
    warp-cli --accept-tos connect
fi
WDOG
    chmod +x /usr/local/bin/warp-watchdog.sh

    cat > /etc/cron.d/warp-watchdog << 'EOF'
# Проверка WARP каждые 2 минуты
*/2 * * * * root /usr/local/bin/warp-watchdog.sh
EOF
    chmod 644 /etc/cron.d/warp-watchdog
    echo "${green}WARP watchdog установлен (проверка каждые 2 мин).${reset}"
}

writeNginxConfig() {
    local xrayPort="$1"
    local domain="$2"
    local proxyUrl="$3"
    local wsPath="$4"

    local proxy_host
    proxy_host=$(echo "$proxyUrl" | sed 's|https://||;s|http://||;s|/.*||')

    setNginxCert

    cat > /etc/nginx/nginx.conf << 'NGINXMAIN'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    log_format main '$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer"';
    access_log /var/log/nginx/access.log main buffer=16k flush=5s;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 75s;
    keepalive_requests 1000;
    types_hash_max_size 2048;
    server_tokens off;

    proxy_buffers 8 16k;
    proxy_buffer_size 32k;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include /etc/nginx/conf.d/*.conf;
}
NGINXMAIN

    cat > /etc/nginx/conf.d/default.conf << 'DEFAULTCONF'
server {
    listen 80 default_server;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl default_server;
    ssl_certificate /etc/nginx/cert/default.crt;
    ssl_certificate_key /etc/nginx/cert/default.key;
    server_name _;
    return 444;
}
DEFAULTCONF

    cat > "$nginxPath" << EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $domain;

    ssl_certificate /etc/nginx/cert/cert.pem;
    ssl_certificate_key /etc/nginx/cert/cert.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;

    location $wsPath {
        if (\$http_upgrade != "websocket") { return 404; }

        proxy_redirect off;
        proxy_pass http://127.0.0.1:$xrayPort;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;

        # Реальный IP клиента — при CDN приходит от Cloudflare в CF-Connecting-IP.
        # real_ip модуль (cloudflare_real_ips.conf) уже восстанавливает \$remote_addr,
        # поэтому X-Real-IP будет содержать настоящий IP пользователя, не CF-ноду.
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        # Отключаем буферизацию — критично для WebSocket
        proxy_buffering off;
        proxy_cache off;
        proxy_request_buffering off;

        # Таймауты — без них idle WS рвётся через 60с (nginx default)
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 10s;
    }

    location / {
        proxy_ssl_server_name on;
        proxy_pass $proxyUrl;
        proxy_set_header Host $proxy_host;
    }
}
EOF
}

# ============================================================
# ИНФОРМАЦИЯ О КОНФИГЕ / QR
# ============================================================

getConfigInfo() {
    if [ ! -f "$configPath" ]; then
        echo "${red}Конфиг Xray не найден!${reset}"
        return 1
    fi
    xray_uuid=$(jq -r ".inbounds[0].settings.clients[0].id" "$configPath" 2>/dev/null)
    xray_userDomain=$(grep -m 1 -oP "server_name\s+\K\S+" "$nginxPath" 2>/dev/null | grep -v '_' | head -n 1 | tr -d ';')
    [ -z "$xray_userDomain" ] && xray_userDomain=$(getServerIP)
    xray_path=$(jq -r ".inbounds[0].streamSettings.wsSettings.path" "$configPath" 2>/dev/null)
}

getShareUrl() {
    getConfigInfo || return 1
    local encoded_path
    encoded_path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$xray_path'))" 2>/dev/null \
        || echo "$xray_path" | sed 's|/|%2F|g')
    echo "vless://${xray_uuid}@${xray_userDomain}:443?encryption=none&security=tls&sni=${xray_userDomain}&type=ws&host=${xray_userDomain}&path=${encoded_path}#${xray_userDomain}"
}

getQrCode() {
    command -v qrencode &>/dev/null || installPackage "qrencode"
    local url
    url=$(getShareUrl) || return 1
    qrencode -t ANSI "$url"
    echo -e "\n${green}$url${reset}\n"
}

# ============================================================
# ИЗМЕНЕНИЕ ПАРАМЕТРОВ
# ============================================================

modifyXrayUUID() {
    local new_uuid
    new_uuid=$(cat /proc/sys/kernel/random/uuid)
    jq ".inbounds[0].settings.clients[0].id = \"$new_uuid\"" \
        "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    systemctl restart xray
    echo "${green}New UUID: $new_uuid${reset}"
}

modifyXrayPort() {
    local oldPort
    oldPort=$(jq ".inbounds[0].port" "$configPath")
    read -rp "New Xray Port [$oldPort]: " xrayPort
    [ -z "$xrayPort" ] && return
    if ! [[ "$xrayPort" =~ ^[0-9]+$ ]] || [ "$xrayPort" -lt 1024 ] || [ "$xrayPort" -gt 65535 ]; then
        echo "${red}Некорректный порт.${reset}"; return 1
    fi
    jq ".inbounds[0].port = $xrayPort" \
        "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    sed -i "s|127.0.0.1:${oldPort}|127.0.0.1:${xrayPort}|g" "$nginxPath"
    systemctl restart xray nginx
    echo "${green}Порт изменен на $xrayPort${reset}"
}

modifyWsPath() {
    local oldPath
    oldPath=$(jq -r ".inbounds[0].streamSettings.wsSettings.path" "$configPath")
    read -rp "Новый Path (с / в начале, или Enter для случайного): " wsPath
    [ -z "$wsPath" ] && wsPath=$(generateRandomPath)
    [[ ! "$wsPath" =~ ^/ ]] && wsPath="/$wsPath"

    local oldPathEscaped newPathEscaped
    oldPathEscaped=$(echo "$oldPath" | sed 's|/|\\/|g')
    newPathEscaped=$(echo "$wsPath" | sed 's|/|\\/|g')
    sed -i "s|location ${oldPathEscaped}|location ${newPathEscaped}|g" "$nginxPath"

    jq ".inbounds[0].streamSettings.wsSettings.path = \"$wsPath\"" \
        "$configPath" > "${configPath}.tmp" && mv "${configPath}.tmp" "$configPath"
    systemctl restart xray nginx
    echo "${green}New Path: $wsPath${reset}"
}

modifyProxyPassUrl() {
    read -rp "New Proxy Pass URL (например, https://google.com): " newUrl
    [ -z "$newUrl" ] && return
    local oldUrl
    oldUrl=$(grep "proxy_pass" "$nginxPath" | grep -v "127.0.0.1" | awk '{print $2}' | tr -d ';' | head -1)
    local oldUrlEscaped newUrlEscaped
    oldUrlEscaped=$(echo "$oldUrl" | sed 's|[/&]|\\&|g')
    newUrlEscaped=$(echo "$newUrl" | sed 's|[/&]|\\&|g')
    sed -i "s|${oldUrlEscaped}|${newUrlEscaped}|g" "$nginxPath"
    systemctl reload nginx
    echo "${green}Proxy Pass обновлен.${reset}"
}

modifyDomain() {
    getConfigInfo || return 1
    echo "Текущий домен: $xray_userDomain"
    read -rp "Введите новый домен: " new_domain
    [ -z "$new_domain" ] && return
    sed -i "s/server_name ${xray_userDomain};/server_name ${new_domain};/" "$nginxPath"
    userDomain="$new_domain"
    configCert
    systemctl restart nginx xray
}

# ============================================================
# БЕЗОПАСНОСТЬ
# ============================================================

changeSshPort() {
    read -rp "Введите новый SSH порт [22]: " new_ssh_port
    if ! [[ "$new_ssh_port" =~ ^[0-9]+$ ]] || [ "$new_ssh_port" -lt 1 ] || [ "$new_ssh_port" -gt 65535 ]; then
        echo "${red}Некорректный порт.${reset}"; return 1
    fi
    ufw allow "$new_ssh_port"/tcp comment 'SSH'
    sed -i "s/^#\?Port [0-9]*/Port $new_ssh_port/" /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh
    echo "${green}SSH порт изменен на $new_ssh_port. UFW правило добавлено.${reset}"
    echo "${yellow}Не забудьте закрыть старый порт (ufw delete allow 22/tcp) после проверки!${reset}"
}

enableBBR() {
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        echo "${yellow}BBR уже активен.${reset}"; return
    fi
    grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    grep -q "default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    sysctl -p
    echo "${green}BBR включен.${reset}"
}

setupFail2Ban() {
    echo -e "${cyan}Настройка Fail2Ban...${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS
    ${PACKAGE_MANAGEMENT_INSTALL} "fail2ban" &>/dev/null

    local ssh_port
    ssh_port=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -1)
    ssh_port="${ssh_port:-22}"

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 2h
findtime = 10m
maxretry = 5
action = %(action_mwl)s

[sshd]
enabled  = true
port     = $ssh_port
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 24h
EOF
    systemctl restart fail2ban && systemctl enable fail2ban
    echo "${green}Fail2Ban настроен (SSH на порту $ssh_port).${reset}"
}

setupWebJail() {
    echo -e "${cyan}Настройка Web-Jail...${reset}"
    [ ! -f /etc/fail2ban/jail.local ] && setupFail2Ban

    cat > /etc/fail2ban/filter.d/nginx-probe.conf << 'EOF'
[Definition]
failregex = ^<HOST> - .* "(GET|POST|HEAD) .*(\.php|wp-login|admin|\.env|\.git|config\.js|setup\.cgi|xmlrpc).*" (400|403|404|405) \d+
ignoreregex = ^<HOST> - .* "(GET|POST) /favicon.ico.*"
EOF

    if ! grep -q "\[nginx-probe\]" /etc/fail2ban/jail.local; then
        cat >> /etc/fail2ban/jail.local << 'EOF'

[nginx-probe]
enabled  = true
port     = http,https
filter   = nginx-probe
logpath  = /var/log/nginx/access.log
maxretry = 5
bantime  = 24h
EOF
    fi
    systemctl restart fail2ban
    echo "${green}Web-Jail активирован.${reset}"
}

# ============================================================
# ЛОГИ
# ============================================================

clearLogs() {
    echo -e "${cyan}Очистка логов...${reset}"
    for f in /var/log/xray/access.log /var/log/xray/error.log \
              /var/log/nginx/access.log /var/log/nginx/error.log; do
        [ -f "$f" ] && : > "$f"
    done
    journalctl --vacuum-size=100M &>/dev/null
    echo "${green}Логи очищены.${reset}"
}

setupLogrotate() {
    cat > /etc/logrotate.d/xray << 'EOF'
/var/log/xray/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    dateext
    sharedscripts
    postrotate
        systemctl kill -s USR1 xray 2>/dev/null || true
    endscript
}
EOF
    echo "${green}Авто-ротация логов настроена.${reset}"
}

# ============================================================
# CRON: SSL АВТООБНОВЛЕНИЕ
# ============================================================

setupSslCron() {
    cat > /etc/cron.d/acme-renew << 'EOF'
# SSL автообновление — каждые 35 дней в 03:00
0 3 */35 * * root /root/.acme.sh/acme.sh --cron --home /root/.acme.sh --pre-hook "/usr/local/bin/vwn open-80" --post-hook "/usr/local/bin/vwn close-80" >> /var/log/acme_cron.log 2>&1
EOF
    chmod 644 /etc/cron.d/acme-renew
    echo "${green}Автообновление SSL через /etc/cron.d/acme-renew.${reset}"
}

removeSslCron() {
    rm -f /etc/cron.d/acme-renew
    echo "${green}Автообновление SSL отключено.${reset}"
}

checkSslCronStatus() {
    [ -f /etc/cron.d/acme-renew ] && echo "${green}ВКЛЮЧЕНО${reset}" || echo "${red}ВЫКЛЮЧЕНО${reset}"
}

manageSslCron() {
    while true; do
        clear
        echo -e "${cyan}=== Управление автообновлением SSL ===${reset}"
        echo -e "Статус: $(checkSslCronStatus)"
        echo ""
        echo -e "${green}1.${reset} Включить (с хуками UFW)"
        echo -e "${green}2.${reset} Выключить"
        echo -e "${green}3.${reset} Показать задачу"
        echo -e "${green}0.${reset} Назад"
        read -rp "Выберите: " choice
        case $choice in
            1) setupSslCron; read -r ;;
            2) removeSslCron; read -r ;;
            3) cat /etc/cron.d/acme-renew 2>/dev/null || echo "Нет задачи"; read -r ;;
            0) break ;;
        esac
    done
}

# ============================================================
# CRON: АВТООЧИСТКА ЛОГОВ
# ============================================================

setupLogClearCron() {
    cat > /usr/local/bin/clear-logs.sh << 'EOF'
#!/bin/bash
for f in /var/log/xray/access.log /var/log/xray/error.log \
          /var/log/nginx/access.log /var/log/nginx/error.log; do
    [ -f "$f" ] && : > "$f"
done
journalctl --vacuum-size=100M &>/dev/null
EOF
    chmod +x /usr/local/bin/clear-logs.sh

    cat > /etc/cron.d/clear-logs << 'EOF'
# Очистка логов — каждое воскресенье в 04:00
0 4 * * 0 root /usr/local/bin/clear-logs.sh
EOF
    chmod 644 /etc/cron.d/clear-logs
    echo "${green}Автоочистка логов настроена (воскр. 04:00).${reset}"
}

removeLogClearCron() {
    rm -f /etc/cron.d/clear-logs /usr/local/bin/clear-logs.sh
    echo "${green}Автоочистка логов отключена.${reset}"
}

checkLogClearCronStatus() {
    [ -f /etc/cron.d/clear-logs ] && echo "${green}ВКЛЮЧЕНО${reset}" || echo "${red}ВЫКЛЮЧЕНО${reset}"
}

manageLogClearCron() {
    while true; do
        clear
        echo -e "${cyan}=== Управление автоочисткой логов ===${reset}"
        echo -e "Статус: $(checkLogClearCronStatus)"
        echo ""
        echo -e "${green}1.${reset} Включить (раз в неделю)"
        echo -e "${green}2.${reset} Выключить"
        echo -e "${green}3.${reset} Показать задачу"
        echo -e "${green}0.${reset} Назад"
        read -rp "Выберите: " choice
        case $choice in
            1) setupLogClearCron; read -r ;;
            2) removeLogClearCron; read -r ;;
            3) cat /etc/cron.d/clear-logs 2>/dev/null || echo "Нет задачи"; read -r ;;
            0) break ;;
        esac
    done
}

# ============================================================
# REALITY
# ============================================================

realityConfigPath='/usr/local/etc/xray/reality.json'

generateRealityKeys() {
    /usr/local/bin/xray x25519 2>/dev/null || { echo "${red}Ошибка генерации ключей Reality${reset}"; return 1; }
}

getServerIP() {
    local ip
    # Пробуем несколько сервисов по очереди
    for url in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://checkip.amazonaws.com"; do
        ip=$(curl -s --connect-timeout 5 "$url" 2>/dev/null | tr -d '[:space:]')
        # Проверяем что получили валидный IPv4
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
    done
    # Последний вариант — из сетевых интерфейсов
    ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    echo "${ip:-UNKNOWN}"
}

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
    local dest="$2"        # например microsoft.com:443
    local destHost="${dest%%:*}"

    echo -e "${cyan}Генерация ключей Reality...${reset}"
    local keys privKey pubKey shortId new_uuid

    # Генерируем x25519 ключи
    keys=$(/usr/local/bin/xray x25519 2>/dev/null) || { echo "${red}Ошибка: xray x25519 не работает${reset}"; return 1; }

    privKey=$(echo "$keys" | tr -d '\r' | awk '/PrivateKey:/{print $2}')
    pubKey=$(echo "$keys"  | tr -d '\r' | awk '/Password:/{print $2}')

    [ -z "$privKey" ] || [ -z "$pubKey" ] && { echo "${red}Ошибка получения ключей${reset}"; return 1; }

    # Генерируем shortId — избегаем SIGPIPE из-за pipefail
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
            "clients": [{
                "id": "$new_uuid",
                "flow": "xtls-rprx-vision"
            }],
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
        "sniffing": {
            "enabled": false
        }
    }],
    "outbounds": [
        {
            "tag": "free",
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIPv4"
            }
        },
        {
            "tag": "warp",
            "protocol": "socks",
            "settings": {
                "servers": [{"address": "127.0.0.1", "port": 40000}]
            }
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

    # Сохраняем публичный ключ и shortId для показа пользователю
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
    # Создаём отдельный systemd сервис для Reality-инстанса Xray
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
        4)
            read -rp "Введите dest (host:port): " dest
            [ -z "$dest" ] && { echo "${red}Dest не указан.${reset}"; return 1; }
            ;;
        *) dest="microsoft.com:443" ;;
    esac

    echo -e "${cyan}Открываем порт $realityPort в UFW...${reset}"
    ufw allow "$realityPort"/tcp comment 'Xray Reality' 2>/dev/null || true

    writeRealityConfig "$realityPort" "$dest" || return 1
    setupRealityService || return 1

    echo -e "\n${green}Reality установлен!${reset}"
    showRealityQR
}

showRealityInfo() {
    if [ ! -f "$realityConfigPath" ]; then
        echo "${red}Reality не установлен.${reset}"; return 1
    fi

    local uuid port privKey shortId destHost pubKey
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$realityConfigPath")
    port=$(jq -r '.inbounds[0].port' "$realityConfigPath")
    shortId=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$realityConfigPath")
    destHost=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$realityConfigPath")
    privKey=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$realityConfigPath")

    # Получаем публичный ключ (Password в новом формате xray)
    local tmpkeys
    tmpkeys=$(echo "$privKey" | xray x25519 2>/dev/null) || true
    pubKey=$(echo "$tmpkeys" | awk '/Password:/{print $2}')
    [ -z "$pubKey" ] && pubKey=$(awk '/PublicKey:/{print $2}' /usr/local/etc/xray/reality_client.txt 2>/dev/null)

    local serverIP
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
    if [ ! -f "$realityConfigPath" ]; then
        echo "${red}Reality не установлен.${reset}"; return 1
    fi

    local uuid port shortId destHost privKey pubKey serverIP
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
        local s_reality
        s_reality=$(getRealityStatus)
        echo -e "${cyan}=== Управление VLESS + Reality ===${reset}"
        echo -e "Статус: $s_reality"
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

# ============================================================
# UFW
# ============================================================

manageUFW() {
    while true; do
        clear
        echo -e "${cyan}=== Управление UFW Firewall ===${reset}"
        echo ""
        ufw status verbose 2>/dev/null || echo "UFW не активен"
        echo ""
        echo -e "${green}1.${reset} Открыть порт"
        echo -e "${green}2.${reset} Закрыть порт"
        echo -e "${green}3.${reset} Включить UFW"
        echo -e "${green}4.${reset} Выключить UFW"
        echo -e "${green}5.${reset} Сбросить UFW"
        echo -e "${green}0.${reset} Назад"
        read -rp "Выберите: " choice
        case $choice in
            1)
                read -rp "Порт: " port
                read -rp "Протокол [tcp/udp/any]: " proto
                [ "$proto" = "any" ] && proto=""
                [ -n "$port" ] && ufw allow "${port}${proto:+/}${proto}" \
                    && echo "${green}Порт $port открыт${reset}"
                read -r ;;
            2)
                read -rp "Порт для закрытия: " port
                [ -n "$port" ] && ufw delete allow "$port" \
                    && echo "${green}Порт $port закрыт${reset}"
                read -r ;;
            3) echo "y" | ufw enable && echo "${green}UFW включен${reset}"; read -r ;;
            4) ufw disable && echo "${green}UFW выключен${reset}"; read -r ;;
            5)
                echo -e "${red}Удалить ВСЕ правила? (y/n)${reset}"
                read -r confirm
                [[ "$confirm" == "y" ]] && ufw --force reset && echo "${green}UFW сброшен${reset}"
                read -r ;;
            0) break ;;
        esac
    done
}

# ============================================================
# УСТАНОВКА
# ============================================================

prepareSoftware() {
    identifyOS
    echo "--- [1/3] Подготовка системы ---"
    run_task "Чистка пакетов" "rm -f /var/lib/dpkg/lock* && dpkg --configure -a 2>/dev/null || true"
    run_task "Обновление репозиториев" "${PACKAGE_MANAGEMENT_UPDATE}"

    echo "--- [2/3] Установка компонентов ---"
    for p in tar gpg unzip nginx jq nano ufw socat curl qrencode python3; do
        run_task "Установка $p" "installPackage $p" || true
    done

    run_task "Установка Xray-core" installXray
    run_task "Установка Cloudflare WARP" installWarp

    echo "--- [3/3] Безопасность ---"
    run_task "Настройка UFW (22, 443)" "ufw allow 22/tcp && ufw allow 443/tcp && ufw allow 443/udp && echo 'y' | ufw enable"
    cat > /etc/sysctl.d/99-xray.conf << 'SYSCTL'
net.ipv4.icmp_echo_ignore_all = 1
net.ipv6.icmp.echo_ignore_all = 1
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSCTL
    sysctl --system &>/dev/null
    sysctl -p /etc/sysctl.d/99-xray.conf &>/dev/null
    echo "${green}Системные параметры применены (Anti-Ping IPv4+IPv6, IPv6 отключён).${reset}"
}

install() {
    isRoot
    clear
    echo "${green}>>> Установка Xray VLESS + WARP + CDN <<<${reset}"
    prepareSoftware

    echo -e "\n${green}--- Настройка параметров ---${reset}"
    read -rp "Введите Домен (vpn.example.com): " userDomain
    [ -z "$userDomain" ] && { echo "${red}Домен обязателен!${reset}"; return 1; }
    read -rp "Порт Xray [16500]: " xrayPort
    [ -z "$xrayPort" ] && xrayPort=16500
    wsPath=$(generateRandomPath)
    read -rp "Сайт-заглушка [https://httpbin.org/]: " proxyUrl
    [ -z "$proxyUrl" ] && proxyUrl='https://httpbin.org/'

    echo -e "\n${green}--- Финализация ---${reset}"
    run_task "Создание конфига Xray"  "writeXrayConfig '$xrayPort' '$wsPath'"
    run_task "Создание конфига Nginx" "writeNginxConfig '$xrayPort' '$userDomain' '$proxyUrl' '$wsPath'"
    run_task "Настройка WARP"         configWarp
    run_task "Выпуск SSL сертификата" "userDomain='$userDomain' configCert"
    run_task "Применение правил WARP" applyWarpDomains
    run_task "Ротация логов"          setupLogrotate
    run_task "Автоочистка логов"      setupLogClearCron
    run_task "Автообновление SSL"     setupSslCron
    run_task "WARP Watchdog"          setupWarpWatchdog

    systemctl enable --now xray nginx
    systemctl restart xray nginx

    echo -e "\n${green}Установка завершена!${reset}"
    getQrCode
}

# ============================================================
# ГЛАВНОЕ МЕНЮ
# ============================================================

menu() {
    set +e
    while true; do
        clear
        local s_nginx s_xray s_warp s_ssl s_bbr s_f2b s_jail s_cdn s_reality
        s_nginx=$(getServiceStatus nginx)
        s_xray=$(getServiceStatus xray)
        s_warp=$(getWarpStatusRaw)
        s_ssl=$(checkCertExpiry)
        s_bbr=$(getBbrStatus)
        s_f2b=$(getF2BStatus)
        s_jail=$(getWebJailStatus)
        s_cdn=$(getCdnStatus)
        s_reality=$(getRealityStatus)
        local s_relay
        s_relay=$(getRelayStatus)

        echo -e "${cyan}================================================================${reset}"
        echo -e "   ${red}XRAY VLESS + WARP + CDN + REALITY${reset} | $(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}================================================================${reset}"
        echo -e "  NGINX: $s_nginx  |  XRAY: $s_xray  |  WARP: ${green}${s_warp}${reset}"
        echo -e "  $s_ssl  |  BBR: $s_bbr  |  F2B: $s_f2b"
        echo -e "  WebJail: $s_jail  |  CDN: $s_cdn  |  Reality: $s_reality"
        echo -e "  Relay: $s_relay"
        echo -e "${cyan}----------------------------------------------------------------${reset}"

        echo -e "\t${green}1.${reset}  Установить Xray (VLESS+WS+TLS+WARP+CDN)"
        echo -e "\t${green}2.${reset}  Показать QR-код и ссылку"
        echo -e "\t${green}3.${reset}  Сменить UUID"
        echo -e "\t—————————————— Конфигурация —————————————"
        echo -e "\t${green}4.${reset}  Изменить порт Xray"
        echo -e "\t${green}5.${reset}  Изменить путь WebSocket"
        echo -e "\t${green}6.${reset}  Изменить сайт-заглушку"
        echo -e "\t${green}7.${reset}  Перевыпустить SSL сертификат"
        echo -e "\t${green}8.${reset}  Сменить домен"
        echo -e "\t—————————————— CDN и WARP ———————————————"
        echo -e "\t${green}9.${reset}  Переключить CDN режим (ON/OFF)"
        echo -e "\t${green}10.${reset} Переключить режим WARP (Global/Split)"
        echo -e "\t${green}11.${reset} Добавить домен в WARP"
        echo -e "\t${green}12.${reset} Удалить домен из WARP"
        echo -e "\t${green}13.${reset} Редактировать список WARP (Nano)"
        echo -e "\t${green}14.${reset} Проверить IP (Real vs WARP)"
        echo -e "\t—————————————— Безопасность —————————————"
        echo -e "\t${green}15.${reset} Включить BBR"
        echo -e "\t${green}16.${reset} Включить Fail2Ban"
        echo -e "\t${green}17.${reset} Включить Web-Jail"
        echo -e "\t${green}18.${reset} Сменить SSH порт"
        echo -e "\t${green}30.${reset} Установить WARP Watchdog"
        echo -e "\t—————————————— Логи —————————————————————"
        echo -e "\t${green}19.${reset} Логи Xray (access)"
        echo -e "\t${green}20.${reset} Логи Xray (error)"
        echo -e "\t${green}21.${reset} Логи Nginx (access)"
        echo -e "\t${green}22.${reset} Логи Nginx (error)"
        echo -e "\t${green}23.${reset} Очистить все логи"
        echo -e "\t—————————————— Сервисы ——————————————————"
        echo -e "\t${green}24.${reset} Перезапустить все сервисы"
        echo -e "\t${green}25.${reset} Обновить Xray-core"
        echo -e "\t${green}26.${reset} Полное удаление"
        echo -e "\t—————————————— UFW, SSL, Logs ———————————"
        echo -e "\t${green}27.${reset} Управление UFW"
        echo -e "\t${green}28.${reset} Управление автообновлением SSL"
        echo -e "\t${green}29.${reset} Управление автоочисткой логов"
        echo -e "\t—————————————— Reality ——————————————————"
        echo -e "\t${green}31.${reset} Управление VLESS + Reality"
        echo -e "\t—————————————— Relay —————————————————————"
        echo -e "\t${green}32.${reset} Управление Relay (внешний сервер)"
        echo -e "\t—————————————— Выход ————————————————————"
        echo -e "\t${green}0.${reset}  Выйти"
        echo -e "${cyan}----------------------------------------------------------------${reset}"

        read -rp "Выберите пункт: " num
        case $num in
            1)  install ;;
            2)  getQrCode ;;
            3)  modifyXrayUUID ;;
            4)  modifyXrayPort ;;
            5)  modifyWsPath ;;
            6)  modifyProxyPassUrl ;;
            7)  getConfigInfo && userDomain="$xray_userDomain" && configCert ;;
            8)  modifyDomain ;;
            9)  toggleCdnMode ;;
            10) toggleWarpMode ;;
            11) addDomainToWarpProxy ;;
            12) deleteDomainFromWarpProxy ;;
            13) nano "$warpDomainsFile" && applyWarpDomains ;;
            14) checkWarpStatus ;;
            15) enableBBR ;;
            16) setupFail2Ban ;;
            17) setupWebJail ;;
            18) changeSshPort ;;
            30) setupWarpWatchdog ;;
            19) tail -n 80 /var/log/xray/access.log ;;
            20) tail -n 80 /var/log/xray/error.log ;;
            21) tail -n 80 /var/log/nginx/access.log ;;
            22) tail -n 80 /var/log/nginx/error.log ;;
            23) clearLogs ;;
            24) systemctl restart xray nginx warp-svc ;;
            25) bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install ;;
            26)
                echo -e "${red}Удалить Xray, Nginx, WARP и все конфиги? (y/n)${reset}"
                read -r confirm
                if [[ "$confirm" == "y" ]]; then
                    systemctl stop nginx xray warp-svc 2>/dev/null || true
                    warp-cli disconnect 2>/dev/null || true
                    uninstallPackage 'nginx*' || true
                    uninstallPackage 'cloudflare-warp' || true
                    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove || true
                    systemctl stop xray-reality 2>/dev/null || true
                    systemctl disable xray-reality 2>/dev/null || true
                    rm -f /etc/systemd/system/xray-reality.service
                    rm -rf /etc/nginx /usr/local/etc/xray /root/.cloudflare_api "$warpDomainsFile" \
                           "$relayDomainsFile" "$relayConfigFile" \
                           /etc/cron.d/acme-renew /etc/cron.d/clear-logs /etc/cron.d/warp-watchdog \
                           /usr/local/bin/warp-watchdog.sh /usr/local/bin/clear-logs.sh \
                           /etc/sysctl.d/99-xray.conf
                    systemctl daemon-reload
                    echo "${green}Удаление завершено.${reset}"
                fi ;;
            27) manageUFW ;;
            28) manageSslCron ;;
            29) manageLogClearCron ;;
            31) manageReality ;;
            32) manageRelay ;;
            0)  exit 0 ;;
            *)  echo -e "${red}Неверный пункт!${reset}"; sleep 1 ;;
        esac
        echo -e "\n${cyan}Нажмите Enter...${reset}"
        read -r
    done
}

# ============================================================
# ТОЧКА ВХОДА
# ============================================================

isRoot
setupAlias
menu "$@"
