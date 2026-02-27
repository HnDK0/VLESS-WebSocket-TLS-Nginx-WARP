#!/bin/bash
# =================================================================
# warp.sh — Cloudflare WARP: установка, домены, watchdog
# =================================================================

installWarp() {
    command -v warp-cli &>/dev/null && { echo "info: warp-cli уже установлен."; return; }
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS
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
        echo "${green}WARP успешно подключен!${reset}"
    else
        echo "${yellow}WARP запущен, но проверка не прошла. Продолжаем...${reset}"
    fi
}

applyWarpDomains() {
    [ ! -f "$warpDomainsFile" ] && printf 'openai.com\nchatgpt.com\noaistatic.com\noaiusercontent.com\nauth0.openai.com\n' > "$warpDomainsFile"
    local domains_json
    domains_json=$(awk 'NF {printf "\"domain:%s\",", $1}' "$warpDomainsFile" | sed 's/,$//')

    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        jq "(.routing.rules[] | select(.outboundTag == \"warp\")) |= (.domain = [$domains_json] | del(.port))" \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    done
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
}

toggleWarpMode() {
    echo "Выберите режим работы WARP:"
    echo "1) Global — весь трафик через WARP"
    echo "2) Split — только список доменов"
    echo "3) OFF — отключить WARP от Xray"
    echo "0) Назад"
    read -rp "Ваш выбор: " warp_mode

    case "$warp_mode" in
        1)
            for cfg in "$configPath" "$realityConfigPath"; do
                [ -f "$cfg" ] || continue
                jq '(.routing.rules[] | select(.outboundTag == "warp")) |= (.port = "0-65535" | del(.domain))' \
                    "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
            done
            echo "${green}Global: Весь трафик через WARP.${reset}"
            systemctl restart xray 2>/dev/null || true
            systemctl restart xray-reality 2>/dev/null || true
            ;;
        2)
            applyWarpDomains
            echo "${green}Split: Только список доменов через WARP.${reset}"
            ;;
        3)
            for cfg in "$configPath" "$realityConfigPath"; do
                [ -f "$cfg" ] || continue
                jq 'del(.routing.rules[] | select(.outboundTag == "warp"))' \
                    "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
            done
            echo "${green}WARP отключён от Xray.${reset}"
            systemctl restart xray 2>/dev/null || true
            systemctl restart xray-reality 2>/dev/null || true
            ;;
        0) return ;;
        *) echo "${red}Отмена.${reset}" ;;
    esac
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

setupWarpWatchdog() {
    cat > /usr/local/bin/warp-watchdog.sh << 'WDOG'
#!/bin/bash
CHECK_URL="https://www.cloudflare.com/cdn-cgi/trace/"
PROXY="socks5://127.0.0.1:40000"
MAX_LATENCY=5

result=$(curl -s --connect-timeout $MAX_LATENCY -x "$PROXY" "$CHECK_URL" 2>/dev/null)
if echo "$result" | grep -q "warp=on\|warp=plus"; then exit 0; fi

logger -t warp-watchdog "WARP не отвечает — переподключение..."
warp-cli --accept-tos disconnect 2>/dev/null
sleep 2
warp-cli --accept-tos connect
sleep 5

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
    echo "${green}WARP watchdog установлен.${reset}"
}
