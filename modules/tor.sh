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
        # Определяем режим по конфигу Xray
        local mode="маршрут OFF"
        if [ -f "$configPath" ]; then
            local tor_rule
            tor_rule=$(jq -r '.routing.rules[] | select(.outboundTag=="tor") | if .port == "0-65535" then "Global" elif (.domain | length) > 0 then "Split" else "OFF" end' "$configPath" 2>/dev/null | head -1)
            [ -n "$tor_rule" ] && mode="$tor_rule"
        fi
        local country_str="${country:+, $country}"
        case "$mode" in
            Global) echo "${green}ON | Global${country_str}${reset}" ;;
            Split)  echo "${green}ON | Split${country_str}${reset}" ;;
            *)      echo "${yellow}ON | $(msg mode_off)${country_str}${reset}" ;;
        esac
    else
        echo "${red}OFF${reset}"
    fi
}

installTor() {
    if command -v tor &>/dev/null; then
        echo "info: $(msg tor_already)"; return 0
    fi
    echo -e "${cyan}$(msg tor_installing)${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS
    ${PACKAGE_MANAGEMENT_INSTALL} tor || {
        echo "${red}$(msg tor_install_fail)${reset}"; return 1
    }
    echo "${green}$(msg tor_installed)${reset}"
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

    echo "${green}$(msg tor_config_ok)${reset}"
}

setupTorService() {
    systemctl enable tor
    systemctl restart tor
    sleep 5

    if curl -s --connect-timeout 15 -x socks5://127.0.0.1:${TOR_PORT} https://api.ipify.org &>/dev/null; then
        echo "${green}$(msg tor_running)${reset}"
    else
        echo "${yellow}$(msg tor_started)${reset}"
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
    echo "${green}$(msg tor_split_ok)${reset}"
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
    echo "${green}$(msg tor_global_ok)${reset}"
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
    echo "$(msg tor_real_ip) : $(getServerIP)"
    echo "$(msg tor_checking)"
    local ip
    ip=$(curl -s --connect-timeout 30 -x socks5://127.0.0.1:${TOR_PORT} https://api.ipify.org 2>/dev/null || echo "$(msg unavailable)")
    echo "$(msg tor_ip) : $ip"
    if [ "$ip" != "$(msg unavailable)" ]; then
        local country
        country=$(curl -s --connect-timeout 10 -x socks5://127.0.0.1:${TOR_PORT} \
            "http://ip-api.com/line/${ip}?fields=countryCode" 2>/dev/null | tr -d '[:space:]')
        echo "$(msg tor_exit_country) : ${country:-$(msg unknown)}"
    fi
}

renewTorCircuit() {
    if command -v tor-resolve &>/dev/null || systemctl is-active --quiet tor; then
        echo -e "${cyan}$(msg tor_circuit_title)${reset}"
        (echo -e "AUTHENTICATE \"\"\r\nSIGNAL NEWNYM\r\nQUIT" | \
            nc 127.0.0.1 ${TOR_CONTROL_PORT} 2>/dev/null) || true
        echo "${green}$(msg tor_circuit_sent)${reset}"
    else
        echo "${red}$(msg tor_not_running)${reset}"
    fi
}

changeTorCountry() {
    echo -e "${cyan}$(msg tor_country_select)${reset}"
    echo " $(msg country_de)"
    echo " $(msg country_nl)"
    echo " $(msg country_us)"
    echo " $(msg country_gb)"
    echo " $(msg country_fr)"
    echo " $(msg country_se)"
    echo " $(msg country_ch)"
    echo " $(msg country_fi)"
    echo " $(msg tor_country_auto)"
    echo "$(msg tor_country_manual)"
    read -rp "Выбор: " c
    local country
    case "$c" in
        1) country="DE" ;; 2) country="NL" ;; 3) country="US" ;;
        4) country="GB" ;; 5) country="FR" ;; 6) country="SE" ;;
        7) country="CH" ;; 8) country="FI" ;; 9) country="" ;;
        10) read -rp "$(msg tor_country_prompt)" country ;;
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
    echo "${green}$(msg tor_country_changed) ${country:-$(msg auto)}. $(msg tor_country_restarting)${reset}"
}

removeTor() {
    echo -e "${red}$(msg tor_remove_confirm) $(msg yes_no)${reset}"
    read -r confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop tor 2>/dev/null || true
        systemctl disable tor 2>/dev/null || true
        removeTorFromConfigs
        rm -f "$torDomainsFile"
        [ -z "${PACKAGE_MANAGEMENT_REMOVE:-}" ] && identifyOS
        ${PACKAGE_MANAGEMENT_REMOVE} tor 2>/dev/null || true
        echo "${green}$(msg removed)${reset}"
    fi
}

installTorFull() {
    echo -e "${cyan}$(msg tor_setup_title)${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS
    installTor || return 1

    echo -e "${cyan}$(msg tor_country_select)${reset}"
    echo " $(msg country_de)"
    echo " $(msg country_nl)"
    echo " $(msg country_us)"
    echo " $(msg country_gb)"
    echo " $(msg country_fr)"
    echo " $(msg country_se)"
    echo " $(msg country_ch)"
    echo " $(msg country_fi)"
    echo " $(msg tor_country_auto)"
    echo "$(msg tor_country_manual)"
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

    echo -e "\n${green}$(msg tor_installed_ok)${reset}"
    echo "$(msg tor_hint)"
    echo "${yellow}$(msg tor_slow)${reset}"
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
        echo "${green}ON (${count} $(msg bridges_count))${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

installObfs4() {
    if command -v obfs4proxy &>/dev/null; then
        echo "info: $(msg obfs4_already)"; return 0
    fi
    echo -e "${cyan}$(msg obfs4_installing)${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS
    ${PACKAGE_MANAGEMENT_INSTALL} obfs4proxy 2>/dev/null || {
        echo "${yellow}$(msg tor_obfs4_try)${reset}"
        ${PACKAGE_MANAGEMENT_INSTALL} lyrebird 2>/dev/null || {
            echo "${red}$(msg tor_obfs4_fail)${reset}"; return 1
        }
    }
}

addTorBridges() {
    echo -e "${cyan}$(msg tor_bridge_title)${reset}"
    echo ""
    echo "$(msg tor_bridge_type)"
    echo "$(msg tor_bridge_1)"
    echo "$(msg tor_bridge_2)"
    echo "$(msg tor_bridge_3)"
    echo "$(msg tor_bridge_4)"
    echo "$(msg back)"
    echo ""
    echo "${yellow}$(msg tor_bridge_url)${reset}"
    echo ""
    read -rp "$(msg tor_bridge_choice)" bridge_type_choice
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
    echo "$(msg tor_bridge_paste)"
    echo "$(msg tor_bridge_example)"
    echo ""

    local bridges=()
    while true; do
        read -rp "> " bridge_line
        [ -z "$bridge_line" ] && break
        bridges+=("$bridge_line")
    done

    if [ ${#bridges[@]} -eq 0 ]; then
        echo "${red}$(msg tor_bridge_empty)${reset}"; return 1
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
    echo "${green}$(msg tor_bridge_ok)${reset}"
}

removeTorBridges() {
    grep -v "^UseBridges\|^ClientTransportPlugin\|^Bridge " "$TOR_CONFIG" > /tmp/torrc.tmp
    mv /tmp/torrc.tmp "$TOR_CONFIG"
    systemctl restart tor
    echo "${green}$(msg tor_bridge_removed)${reset}"
}

manageTor() {
    set +e
    while true; do
        clear
        echo -e "${cyan}$(msg tor_title)${reset}"
        echo -e "$(msg status): $(getTorStatus)"
        echo ""
        if command -v tor &>/dev/null; then
            local country="Авто"
            grep -q "^ExitNodes" "$TOR_CONFIG" 2>/dev/null && \
                country=$(grep "^ExitNodes" "$TOR_CONFIG" | grep -oP '\{[A-Z]+\}' | tr -d '{}' | head -1)
            echo -e "  $(msg country): ${green}${country}${reset}"
            echo -e "  $(msg tor_bridges_status): $(getTorBridgeStatus)"
            echo -e "  $(msg tor_socks5): 127.0.0.1:$TOR_PORT"
            [ -f "$torDomainsFile" ] && echo -e "  $(msg domains_count): $(wc -l < "$torDomainsFile")"
        fi
        echo ""
        echo -e "${green}1.${reset} $(msg tor_install)"
        echo -e "${green}2.${reset} $(msg tor_mode)"
        echo -e "${green}3.${reset} $(msg tor_add)"
        echo -e "${green}4.${reset} $(msg tor_del)"
        echo -e "${green}5.${reset} $(msg tor_edit)"
        echo -e "${green}6.${reset} $(msg tor_country)"
        echo -e "${green}7.${reset} $(msg tor_check)"
        echo -e "${green}8.${reset} $(msg tor_renew)"
        echo -e "${green}9.${reset} $(msg tor_restart)"
        echo -e "${green}10.${reset} $(msg tor_logs)"
        echo -e "${green}11.${reset} $(msg tor_bridges)"
        echo -e "${green}12.${reset} $(msg tor_bridges_remove)"
        echo -e "${green}13.${reset} $(msg tor_remove)"
        echo -e "${green}0.${reset} $(msg back)"
        echo ""
        read -rp "$(msg choose)" choice
        case $choice in
            1)  installTorFull ;;
            2)
                ! command -v tor &>/dev/null && { echo "${red}$(msg tor_not_installed)${reset}"; read -r; continue; }
                echo "$(msg tor_mode_1)"
                echo "$(msg tor_mode_2)"
                echo "$(msg tor_mode_3)"
                echo "$(msg back)"
                read -rp "Выбор: " mode
                case "$mode" in
                    1) toggleTorGlobal ;;
                    2) applyTorDomains ;;
                    3) removeTorFromConfigs; echo "${green}$(msg tor_off_ok)${reset}" ;;
                    0) continue ;;
                esac
                ;;
            3)
                ! command -v tor &>/dev/null && { echo "${red}$(msg tor_not_installed)${reset}"; read -r; continue; }
                read -rp "$(msg tor_domain_prompt)" domain
                [ -z "$domain" ] && continue
                echo "$domain" >> "$torDomainsFile"
                sort -u "$torDomainsFile" -o "$torDomainsFile"
                applyTorDomains
                echo "${green}$(msg tor_domain_added)${reset}"
                ;;
            4)
                [ ! -f "$torDomainsFile" ] && { echo "$(msg warp_list_empty)"; read -r; continue; }
                nl "$torDomainsFile"
                read -rp "$(msg warp_domain_del)" num
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
            9)  systemctl restart tor && echo "${green}$(msg restarted)${reset}" ;;
            10) tail -n 50 /var/log/tor/notices.log 2>/dev/null || journalctl -u tor -n 50 --no-pager ;;
            11) addTorBridges ;;
            12) removeTorBridges ;;
            13) removeTor ;;
            0)  break ;;
        esac
        [ "${choice}" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}
