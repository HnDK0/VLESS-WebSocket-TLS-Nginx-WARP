#!/bin/bash
# =================================================================
# tor.sh — Tor: установка, управление, смена страны выхода
# SOCKS5 на 127.0.0.1:40003
# =================================================================

TOR_PORT=40003
TOR_CONTROL_PORT=40004
TOR_CONFIG="/etc/tor/torrc"
torDomainsFile='/usr/local/etc/xray/tor_domains.txt'

getTorStatus() {
    if systemctl is-active --quiet tor 2>/dev/null; then
        local country=""
        if grep -q "^ExitNodes" "$TOR_CONFIG" 2>/dev/null; then
            country=$(grep "^ExitNodes" "$TOR_CONFIG" | grep -oP '\{[A-Z]+\}' | tr -d '{}' | head -1)
        fi
        echo "${green}ON${country:+ ($country)}${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

installTor() {
    if command -v tor &>/dev/null; then
        echo "info: tor уже установлен."; return 0
    fi
    echo -e "${cyan}Установка Tor...${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS
    ${PACKAGE_MANAGEMENT_INSTALL} tor || {
        echo "${red}Ошибка установки Tor.${reset}"; return 1
    }
    echo "${green}Tor установлен.${reset}"
}

writeTorConfig() {
    local country="${1:-}"

    cat > "$TOR_CONFIG" << EOF
SocksPort 127.0.0.1:${TOR_PORT}
ControlPort 127.0.0.1:${TOR_CONTROL_PORT}
SocksPolicy accept 127.0.0.1
Log notice file /var/log/tor/notices.log
DataDirectory /var/lib/tor
EOF

    if [ -n "$country" ]; then
        cat >> "$TOR_CONFIG" << EOF
ExitNodes {${country}}
StrictNodes 1
EOF
    fi

    echo "${green}Tor конфиг записан.${reset}"
}

setupTorService() {
    systemctl enable tor
    systemctl restart tor
    sleep 5

    if curl -s --connect-timeout 15 -x socks5://127.0.0.1:${TOR_PORT} https://api.ipify.org &>/dev/null; then
        echo "${green}Tor запущен и работает.${reset}"
    else
        echo "${yellow}Tor запущен, но проверка не прошла. Требуется время для подключения (30-60 сек).${reset}"
    fi
}

applyTorOutbound() {
    local tor_ob='{"tag":"tor","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":40003}]}}'

    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        local has_ob
        has_ob=$(jq '.outbounds[] | select(.tag=="tor")' "$cfg" 2>/dev/null)
        if [ -z "$has_ob" ]; then
            jq --argjson ob "$tor_ob" '.outbounds += [$ob]' \
                "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
        fi
        local has_rule
        has_rule=$(jq '.routing.rules[] | select(.outboundTag=="tor")' "$cfg" 2>/dev/null)
        if [ -z "$has_rule" ]; then
            jq '.routing.rules = [.routing.rules[0]] + [{"type":"field","domain":[],"outboundTag":"tor"}] + .routing.rules[1:]' \
                "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
        fi
    done
}

applyTorDomains() {
    [ ! -f "$torDomainsFile" ] && touch "$torDomainsFile"
    local domains_json
    domains_json=$(awk 'NF {printf "\"domain:%s\",", $1}' "$torDomainsFile" | sed 's/,$//')

    applyTorOutbound

    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        jq "(.routing.rules[] | select(.outboundTag == \"tor\")) |= (.domain = [$domains_json] | del(.port))" \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    done
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
    echo "${green}Tor Split применён.${reset}"
}

toggleTorGlobal() {
    applyTorOutbound
    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        jq '(.routing.rules[] | select(.outboundTag == "tor")) |= (.port = "0-65535" | del(.domain))' \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    done
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
    echo "${green}Tor Global: весь трафик через Tor.${reset}"
}

removeTorFromConfigs() {
    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        jq 'del(.outbounds[] | select(.tag=="tor")) | del(.routing.rules[] | select(.outboundTag=="tor"))' \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    done
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
}

checkTorIP() {
    echo "Реальный IP сервера : $(getServerIP)"
    echo "Проверка через Tor (может занять 30 сек)..."
    local ip
    ip=$(curl -s --connect-timeout 30 -x socks5://127.0.0.1:${TOR_PORT} https://api.ipify.org 2>/dev/null || echo "Недоступен")
    echo "IP через Tor        : $ip"
    if [ "$ip" != "Недоступен" ]; then
        local country
        country=$(curl -s --connect-timeout 10 -x socks5://127.0.0.1:${TOR_PORT} \
            "http://ip-api.com/line/${ip}?fields=countryCode" 2>/dev/null | tr -d '[:space:]')
        echo "Страна выхода       : ${country:-неизвестно}"
    fi
}

renewTorCircuit() {
    if command -v tor-resolve &>/dev/null || systemctl is-active --quiet tor; then
        echo -e "${cyan}Обновление цепи Tor...${reset}"
        (echo -e "AUTHENTICATE \"\"\r\nSIGNAL NEWNYM\r\nQUIT" | \
            nc 127.0.0.1 ${TOR_CONTROL_PORT} 2>/dev/null) || true
        echo "${green}Запрос на новую цепь отправлен.${reset}"
    else
        echo "${red}Tor не запущен.${reset}"
    fi
}

changeTorCountry() {
    echo -e "${cyan}Выберите страну выхода Tor:${reset}"
    echo " 1) DE — Германия"
    echo " 2) NL — Нидерланды"
    echo " 3) US — США"
    echo " 4) GB — Великобритания"
    echo " 5) FR — Франция"
    echo " 6) SE — Швеция"
    echo " 7) CH — Швейцария"
    echo " 8) FI — Финляндия"
    echo " 9) Авто (любая страна)"
    echo "10) Ввести код вручную"
    read -rp "Выбор: " c
    local country
    case "$c" in
        1) country="DE" ;; 2) country="NL" ;; 3) country="US" ;;
        4) country="GB" ;; 5) country="FR" ;; 6) country="SE" ;;
        7) country="CH" ;; 8) country="FI" ;; 9) country="" ;;
        10) read -rp "Код страны (2 буквы, например RO): " country ;;
        *) return ;;
    esac

    # Обновляем конфиг
    grep -v "^ExitNodes\|^StrictNodes" "$TOR_CONFIG" > /tmp/torrc.tmp
    if [ -n "$country" ]; then
        echo "ExitNodes {${country}}" >> /tmp/torrc.tmp
        echo "StrictNodes 1" >> /tmp/torrc.tmp
    fi
    mv /tmp/torrc.tmp "$TOR_CONFIG"
    systemctl restart tor
    echo "${green}Страна изменена на ${country:-Авто}. Перезапуск Tor...${reset}"
}

removeTor() {
    echo -e "${red}Удалить Tor? (y/n)${reset}"
    read -r confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop tor 2>/dev/null || true
        systemctl disable tor 2>/dev/null || true
        removeTorFromConfigs
        rm -f "$torDomainsFile"
        [ -z "${PACKAGE_MANAGEMENT_REMOVE:-}" ] && identifyOS
        ${PACKAGE_MANAGEMENT_REMOVE} tor 2>/dev/null || true
        echo "${green}Tor удалён.${reset}"
    fi
}

installTorFull() {
    echo -e "${cyan}=== Установка Tor ===${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS
    installTor || return 1

    echo -e "${cyan}Выберите страну выхода:${reset}"
    echo " 1) DE — Германия"
    echo " 2) NL — Нидерланды"
    echo " 3) US — США"
    echo " 4) GB — Великобритания"
    echo " 5) FR — Франция"
    echo " 6) SE — Швеция"
    echo " 7) CH — Швейцария"
    echo " 8) FI — Финляндия"
    echo " 9) Авто (любая страна)"
    echo "10) Ввести код вручную"
    read -rp "Выбор [9]: " country_choice

    local country
    case "${country_choice:-9}" in
        1) country="DE" ;; 2) country="NL" ;; 3) country="US" ;;
        4) country="GB" ;; 5) country="FR" ;; 6) country="SE" ;;
        7) country="CH" ;; 8) country="FI" ;; 9) country="" ;;
        10) read -rp "Код страны: " country ;;
        *) country="" ;;
    esac

    writeTorConfig "$country"
    setupTorService
    applyTorDomains

    echo -e "\n${green}Tor установлен!${reset}"
    echo "Добавьте домены в список (пункт 3) для Split режима."
    echo "${yellow}Tor медленнее обычного интернета — рекомендуется Split режим.${reset}"
}


# ------------------------------------------------------------------
# Мосты (Bridges)
# ------------------------------------------------------------------

getTorBridgeStatus() {
    if grep -q "^UseBridges 1" "$TOR_CONFIG" 2>/dev/null; then
        local btype
        btype=$(grep "^ClientTransportPlugin" "$TOR_CONFIG" 2>/dev/null | awk '{print $1}' | head -1)
        local count
        count=$(grep -c "^Bridge " "$TOR_CONFIG" 2>/dev/null || echo 0)
        echo "${green}ON (${count} мостов)${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

installObfs4() {
    if command -v obfs4proxy &>/dev/null; then
        echo "info: obfs4proxy уже установлен."; return 0
    fi
    echo -e "${cyan}Установка obfs4proxy...${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS
    ${PACKAGE_MANAGEMENT_INSTALL} obfs4proxy 2>/dev/null || {
        echo "${yellow}obfs4proxy не найден в репо, пробуем lyrebird...${reset}"
        ${PACKAGE_MANAGEMENT_INSTALL} lyrebird 2>/dev/null || {
            echo "${red}Не удалось установить obfs4proxy/lyrebird.${reset}"; return 1
        }
    }
}

addTorBridges() {
    echo -e "${cyan}=== Настройка мостов Tor ===${reset}"
    echo ""
    echo "Тип моста:"
    echo "1) obfs4       — рекомендуется, маскирует трафик"
    echo "2) snowflake   — через WebRTC, сложно заблокировать"
    echo "3) meek-azure  — через CDN Azure"
    echo "4) Ввести вручную (любой тип)"
    echo "0) Назад"
    echo ""
    echo "${yellow}Получить мосты: https://bridges.torproject.org/${reset}"
    echo ""
    read -rp "Тип [1]: " bridge_type_choice
    [ "${bridge_type_choice}" = "0" ] && return

    local transport=""
    case "${bridge_type_choice:-1}" in
        1) transport="obfs4" ;;
        2) transport="snowflake" ;;
        3) transport="meek_lite" ;;
        4) transport="" ;;
    esac

    # Устанавливаем obfs4proxy если нужен
    if [ "$transport" = "obfs4" ] || [ "$transport" = "meek_lite" ]; then
        installObfs4 || return 1
    fi

    if [ "$transport" = "snowflake" ]; then
        [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS
        ${PACKAGE_MANAGEMENT_INSTALL} snowflake-client 2>/dev/null ||         ${PACKAGE_MANAGEMENT_INSTALL} tor-geoipdb 2>/dev/null || true
    fi

    echo ""
    echo "Вставьте строки мостов (по одной, пустая строка — конец):"
    echo "Пример: obfs4 1.2.3.4:443 FINGERPRINT cert=... iat-mode=0"
    echo ""

    local bridges=()
    while true; do
        read -rp "> " bridge_line
        [ -z "$bridge_line" ] && break
        bridges+=("$bridge_line")
    done

    if [ ${#bridges[@]} -eq 0 ]; then
        echo "${red}Мосты не введены.${reset}"; return 1
    fi

    # Удаляем старые настройки мостов
    grep -v "^UseBridges\|^ClientTransportPlugin\|^Bridge " "$TOR_CONFIG" > /tmp/torrc.tmp
    mv /tmp/torrc.tmp "$TOR_CONFIG"

    # Добавляем новые
    echo "UseBridges 1" >> "$TOR_CONFIG"

    if [ "$transport" = "obfs4" ] || [ "$transport" = "meek_lite" ]; then
        local obfs4_bin
        obfs4_bin=$(command -v obfs4proxy || command -v lyrebird || echo "obfs4proxy")
        echo "ClientTransportPlugin obfs4,meek_lite exec ${obfs4_bin}" >> "$TOR_CONFIG"
    fi

    if [ "$transport" = "snowflake" ]; then
        local sf_bin
        sf_bin=$(command -v snowflake-client || echo "snowflake-client")
        echo "ClientTransportPlugin snowflake exec ${sf_bin} -log /var/log/tor/snowflake.log" >> "$TOR_CONFIG"
    fi

    for bridge in "${bridges[@]}"; do
        echo "Bridge ${bridge}" >> "$TOR_CONFIG"
    done

    systemctl restart tor
    echo "${green}Мосты настроены (${#bridges[@]} шт). Tor перезапущен.${reset}"
}

removeTorBridges() {
    grep -v "^UseBridges\|^ClientTransportPlugin\|^Bridge " "$TOR_CONFIG" > /tmp/torrc.tmp
    mv /tmp/torrc.tmp "$TOR_CONFIG"
    systemctl restart tor
    echo "${green}Мосты удалены. Tor перезапущен.${reset}"
}

manageTor() {
    set +e
    while true; do
        clear
        echo -e "${cyan}=== Управление Tor ===${reset}"
        echo -e "Статус: $(getTorStatus)"
        echo ""
        if command -v tor &>/dev/null; then
            local country="Авто"
            grep -q "^ExitNodes" "$TOR_CONFIG" 2>/dev/null && \
                country=$(grep "^ExitNodes" "$TOR_CONFIG" | grep -oP '\{[A-Z]+\}' | tr -d '{}' | head -1)
            echo -e "  Страна:  ${green}${country}${reset}"
            echo -e "  Мосты:   $(getTorBridgeStatus)"
            echo -e "  SOCKS5:  127.0.0.1:$TOR_PORT"
            [ -f "$torDomainsFile" ] && echo -e "  Доменов: $(wc -l < "$torDomainsFile")"
        fi
        echo ""
        echo -e "${green}1.${reset} Установить Tor"
        echo -e "${green}2.${reset} Переключить режим (Global/Split)"
        echo -e "${green}3.${reset} Добавить домен в список"
        echo -e "${green}4.${reset} Удалить домен из списка"
        echo -e "${green}5.${reset} Редактировать список доменов (Nano)"
        echo -e "${green}6.${reset} Сменить страну выхода"
        echo -e "${green}7.${reset} Проверить IP через Tor"
        echo -e "${green}8.${reset} Обновить цепь (новый IP)"
        echo -e "${green}9.${reset} Перезапустить"
        echo -e "${green}10.${reset} Логи Tor"
        echo -e "${green}11.${reset} Настройка мостов (Bridges)"
        echo -e "${green}12.${reset} Удалить мосты"
        echo -e "${green}13.${reset} Удалить Tor"
        echo -e "${green}0.${reset} Назад"
        echo ""
        read -rp "Выберите: " choice
        case $choice in
            1)  installTorFull ;;
            2)
                ! command -v tor &>/dev/null && { echo "${red}Сначала установите Tor (п.1)${reset}"; read -r; continue; }
                echo "1) Global — весь трафик через Tor"
                echo "2) Split — только список доменов"
                echo "3) OFF — отключить Tor от Xray"
                echo "0) Назад"
                read -rp "Выбор: " mode
                case "$mode" in
                    1) toggleTorGlobal ;;
                    2) applyTorDomains ;;
                    3) removeTorFromConfigs; echo "${green}Tor отключён от Xray.${reset}" ;;
                esac
                ;;
            3)
                ! command -v tor &>/dev/null && { echo "${red}Сначала установите Tor (п.1)${reset}"; read -r; continue; }
                read -rp "Домен (например rutracker.org): " domain
                [ -z "$domain" ] && continue
                echo "$domain" >> "$torDomainsFile"
                sort -u "$torDomainsFile" -o "$torDomainsFile"
                applyTorDomains
                echo "${green}Домен $domain добавлен.${reset}"
                ;;
            4)
                [ ! -f "$torDomainsFile" ] && { echo "Список пуст"; read -r; continue; }
                nl "$torDomainsFile"
                read -rp "Номер для удаления: " num
                [[ "$num" =~ ^[0-9]+$ ]] && sed -i "${num}d" "$torDomainsFile" && applyTorDomains
                ;;
            5)
                [ ! -f "$torDomainsFile" ] && touch "$torDomainsFile"
                nano "$torDomainsFile"
                applyTorDomains
                ;;
            6)  changeTorCountry ;;
            7)  checkTorIP ;;
            8)  renewTorCircuit ;;
            9)  systemctl restart tor && echo "${green}Перезапущен.${reset}" ;;
            10) tail -n 50 /var/log/tor/notices.log 2>/dev/null || journalctl -u tor -n 50 --no-pager ;;
            11) addTorBridges ;;
            12) removeTorBridges ;;
            13) removeTor ;;
            0)  break ;;
        esac
        echo -e "\n${cyan}Нажмите Enter...${reset}"
        read -r
    done
}
