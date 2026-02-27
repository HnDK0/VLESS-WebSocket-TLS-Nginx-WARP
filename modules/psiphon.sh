#!/bin/bash
# =================================================================
# psiphon.sh — Psiphon: установка, домены, управление
# Использует psiphon-tunnel-core ConsoleClient
# SOCKS5 на 127.0.0.1:40002
# =================================================================

PSIPHON_PORT=40002
PSIPHON_SERVICE="/etc/systemd/system/psiphon.service"

# Публичные PropagationChannelId/SponsorId из открытых клиентов Psiphon
PSIPHON_PROPAGATION_CHANNEL="24BCA4EE20BEB92C"
PSIPHON_SPONSOR_ID="721AE60D76700F5A"

getPsiphonStatus() {
    if systemctl is-active --quiet psiphon 2>/dev/null; then
        local country=""
        [ -f "$psiphonConfigFile" ] && country=$(jq -r '.EgressRegion // ""' "$psiphonConfigFile" 2>/dev/null)
        echo "${green}ON${country:+ ($country)}${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

installPsiphonBinary() {
    if [ -f "$psiphonBin" ]; then
        echo "info: psiphon уже установлен."; return 0
    fi

    echo -e "${cyan}Скачивание Psiphon tunnel core...${reset}"
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch_name="x86_64" ;;
        aarch64) arch_name="arm64" ;;
        armv7l)  arch_name="arm" ;;
        *)       echo "${red}Архитектура $arch не поддерживается.${reset}"; return 1 ;;
    esac

    local bin_url="https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries/raw/master/linux/psiphon-tunnel-core-${arch_name}"
    curl -fsSL -o "$psiphonBin" "$bin_url" || {
        echo "${red}Ошибка скачивания Psiphon.${reset}"; return 1
    }
    chmod +x "$psiphonBin"
    echo "${green}Psiphon установлен: $psiphonBin${reset}"
}

writePsiphonConfig() {
    local country="${1:-}"
    mkdir -p /usr/local/etc/xray
    mkdir -p /var/log/psiphon

    cat > "$psiphonConfigFile" << EOF
{
    "PropagationChannelId": "$PSIPHON_PROPAGATION_CHANNEL",
    "SponsorId": "$PSIPHON_SPONSOR_ID",
    "LocalSocksProxyPort": $PSIPHON_PORT,
    "LocalHttpProxyPort": 0,
    "DisableLocalSocksProxy": false,
    "DisableLocalHTTPProxy": true,
    "EgressRegion": "${country}",
    "DataRootDirectory": "/var/lib/psiphon",
    "UseIndistinguishableTLS": true,
    "TunnelProtocol": "",
    "ConnectionWorkerPoolSize": 10,
    "LimitTunnelProtocols": []
}
EOF
    mkdir -p /var/lib/psiphon
}

setupPsiphonService() {
    cat > "$PSIPHON_SERVICE" << EOF
[Unit]
Description=Psiphon Tunnel Core
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=$psiphonBin -config $psiphonConfigFile
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/psiphon/psiphon.log
StandardError=append:/var/log/psiphon/psiphon.log

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable psiphon
    systemctl restart psiphon
    sleep 5

    # Проверяем что SOCKS5 поднялся
    if curl -s --connect-timeout 10 -x socks5://127.0.0.1:${PSIPHON_PORT} https://api.ipify.org &>/dev/null; then
        echo "${green}Psiphon запущен и работает.${reset}"
    else
        echo "${yellow}Psiphon запущен, но проверка не прошла. Может потребоваться время для подключения.${reset}"
    fi
}

applyPsiphonOutbound() {
    # Добавляет psiphon outbound (SOCKS5 на 40002) в оба конфига Xray
    local psiphon_ob='{"tag":"psiphon","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":40002}]}}'

    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        local has_ob
        has_ob=$(jq '.outbounds[] | select(.tag=="psiphon")' "$cfg" 2>/dev/null)
        if [ -z "$has_ob" ]; then
            jq --argjson ob "$psiphon_ob" '.outbounds += [$ob]' \
                "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
        fi
        local has_rule
        has_rule=$(jq '.routing.rules[] | select(.outboundTag=="psiphon")' "$cfg" 2>/dev/null)
        if [ -z "$has_rule" ]; then
            # Вставляем правило после block, перед warp
            jq '.routing.rules = [.routing.rules[0]] + [{"type":"field","domain":[],"outboundTag":"psiphon"}] + .routing.rules[1:]' \
                "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
        fi
    done
}

applyPsiphonDomains() {
    [ ! -f "$psiphonConfigFile" ] && { echo "${red}Psiphon не настроен.${reset}"; return 1; }
    [ ! -f "$psiphonDomainsFile" ] && touch "$psiphonDomainsFile"
    local domains_json
    domains_json=$(awk 'NF {printf "\"domain:%s\",", $1}' "$psiphonDomainsFile" | sed 's/,$//')

    applyPsiphonOutbound

    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        jq "(.routing.rules[] | select(.outboundTag == \"psiphon\")) |= (.domain = [$domains_json] | del(.port))" \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    done
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
    echo "${green}Psiphon Split применён.${reset}"
}

togglePsiphonGlobal() {
    applyPsiphonOutbound
    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        jq '(.routing.rules[] | select(.outboundTag == "psiphon")) |= (.port = "0-65535" | del(.domain))' \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    done
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
    echo "${green}Psiphon Global: весь трафик через Psiphon.${reset}"
}

removePsiphonFromConfigs() {
    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        jq 'del(.outbounds[] | select(.tag=="psiphon")) | del(.routing.rules[] | select(.outboundTag=="psiphon"))' \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    done
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
}

checkPsiphonIP() {
    echo "Реальный IP сервера : $(getServerIP)"
    echo "Проверка через Psiphon..."
    local ip
    ip=$(curl -s --connect-timeout 15 -x socks5://127.0.0.1:${PSIPHON_PORT} https://api.ipify.org 2>/dev/null || echo "Недоступен")
    echo "IP через Psiphon    : $ip"
}

removePsiphon() {
    echo -e "${red}Удалить Psiphon? (y/n)${reset}"
    read -r confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop psiphon 2>/dev/null || true
        systemctl disable psiphon 2>/dev/null || true
        rm -f "$PSIPHON_SERVICE" "$psiphonBin" "$psiphonConfigFile" "$psiphonDomainsFile"
        rm -rf /var/lib/psiphon /var/log/psiphon
        systemctl daemon-reload
        removePsiphonFromConfigs
        echo "${green}Psiphon удалён.${reset}"
    fi
}

installPsiphon() {
    echo -e "${cyan}=== Установка Psiphon ===${reset}"

    installPsiphonBinary || return 1

    echo -e "${cyan}Выберите страну выхода:${reset}"
    echo " 1) DE — Германия"
    echo " 2) NL — Нидерланды"
    echo " 3) US — США"
    echo " 4) GB — Великобритания"
    echo " 5) FR — Франция"
    echo " 6) AT — Австрия"
    echo " 7) CA — Канада"
    echo " 8) SE — Швеция"
    echo " 9) Авто (любая страна)"
    echo "10) Ввести код вручную"
    read -rp "Выбор [1]: " country_choice

    local country
    case "${country_choice:-1}" in
        1) country="DE" ;;
        2) country="NL" ;;
        3) country="US" ;;
        4) country="GB" ;;
        5) country="FR" ;;
        6) country="AT" ;;
        7) country="CA" ;;
        8) country="SE" ;;
        9) country="" ;;
        10) read -rp "Код страны (AT AU BE BG CA CH CZ DE DK EE ES FI FR GB HR HU IE IN IT JP LV NL NO PL PT RO RS SE SG SK US): " country ;;
        *) country="DE" ;;
    esac

    writePsiphonConfig "$country"
    setupPsiphonService

    # Добавляем в Xray конфиги с пустым списком доменов (Split режим)
    applyPsiphonDomains

    echo -e "\n${green}Psiphon установлен!${reset}"
    echo "Добавьте домены в список (пункт 3) для Split режима."
}

changeCountry() {
    [ ! -f "$psiphonConfigFile" ] && { echo "${red}Psiphon не установлен.${reset}"; return 1; }

    echo -e "${cyan}Смена страны Psiphon:${reset}"
    echo " 1) DE  2) NL  3) US  4) GB  5) FR"
    echo " 6) AT  7) CA  8) SE  9) Авто  10) Ввести вручную"
    read -rp "Выбор: " c
    local country
    case "$c" in
        1) country="DE" ;; 2) country="NL" ;; 3) country="US" ;;
        4) country="GB" ;; 5) country="FR" ;; 6) country="AT" ;;
        7) country="CA" ;; 8) country="SE" ;; 9) country="" ;;
        10) read -rp "Код страны: " country ;;
        *) return ;;
    esac

    jq ".EgressRegion = \"$country\"" "$psiphonConfigFile" \
        > "${psiphonConfigFile}.tmp" && mv "${psiphonConfigFile}.tmp" "$psiphonConfigFile"
    systemctl restart psiphon
    echo "${green}Страна изменена на ${country:-Авто}. Перезапуск...${reset}"
}

managePsiphon() {
    set +e
    while true; do
        clear
        echo -e "${cyan}=== Управление Psiphon ===${reset}"
        echo -e "Статус: $(getPsiphonStatus)"
        echo ""
        if [ -f "$psiphonConfigFile" ]; then
            local country
            country=$(jq -r '.EgressRegion // "Авто"' "$psiphonConfigFile" 2>/dev/null)
            echo -e "  Страна: ${green}${country:-Авто}${reset}"
            echo -e "  SOCKS5: 127.0.0.1:$PSIPHON_PORT"
            [ -f "$psiphonDomainsFile" ] && echo -e "  Доменов: $(wc -l < "$psiphonDomainsFile")"
        fi
        echo ""
        echo -e "${green}1.${reset} Установить Psiphon"
        echo -e "${green}2.${reset} Переключить режим (Global/Split)"
        echo -e "${green}3.${reset} Добавить домен в список"
        echo -e "${green}4.${reset} Удалить домен из списка"
        echo -e "${green}5.${reset} Редактировать список доменов (Nano)"
        echo -e "${green}6.${reset} Сменить страну выхода"
        echo -e "${green}7.${reset} Проверить IP через Psiphon"
        echo -e "${green}8.${reset} Перезапустить"
        echo -e "${green}9.${reset} Логи Psiphon"
        echo -e "${green}10.${reset} Удалить Psiphon"
        echo -e "${green}0.${reset} Назад"
        echo ""
        read -rp "Выберите: " choice
        case $choice in
            1)  installPsiphon ;;
            2)
                [ ! -f "$psiphonConfigFile" ] && { echo "${red}Сначала установите Psiphon (п.1)${reset}"; read -r; continue; }
                echo "1) Global — весь трафик через Psiphon"
                echo "2) Split — только список доменов"
                read -rp "Выбор: " mode
                case "$mode" in
                    1) togglePsiphonGlobal ;;
                    2) applyPsiphonDomains ;;
                esac
                ;;
            3)
                [ ! -f "$psiphonConfigFile" ] && { echo "${red}Сначала установите Psiphon (п.1)${reset}"; read -r; continue; }
                read -rp "Домен (например rutracker.org): " domain
                [ -z "$domain" ] && continue
                echo "$domain" >> "$psiphonDomainsFile"
                sort -u "$psiphonDomainsFile" -o "$psiphonDomainsFile"
                applyPsiphonDomains
                echo "${green}Домен $domain добавлен.${reset}"
                ;;
            4)
                [ ! -f "$psiphonDomainsFile" ] && { echo "Список пуст"; read -r; continue; }
                nl "$psiphonDomainsFile"
                read -rp "Номер для удаления: " num
                [[ "$num" =~ ^[0-9]+$ ]] && sed -i "${num}d" "$psiphonDomainsFile" && applyPsiphonDomains
                ;;
            5)
                [ ! -f "$psiphonDomainsFile" ] && touch "$psiphonDomainsFile"
                nano "$psiphonDomainsFile"
                applyPsiphonDomains
                ;;
            6)  changeCountry ;;
            7)  checkPsiphonIP ;;
            8)  systemctl restart psiphon && echo "${green}Перезапущен.${reset}" ;;
            9)  tail -n 50 /var/log/psiphon/psiphon.log 2>/dev/null || journalctl -u psiphon -n 50 --no-pager ;;
            10) removePsiphon ;;
            0)  break ;;
        esac
        echo -e "\n${cyan}Нажмите Enter...${reset}"
        read -r
    done
}
