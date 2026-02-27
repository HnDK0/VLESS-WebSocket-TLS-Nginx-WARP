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
        # Определяем режим по конфигу Xray
        local mode="маршрут OFF"
        if [ -f "$configPath" ]; then
            local ps_rule
            ps_rule=$(jq -r '.routing.rules[] | select(.outboundTag=="psiphon") | if .port == "0-65535" then "Global" elif (.domain | length) > 0 then "Split" else "OFF" end' "$configPath" 2>/dev/null | head -1)
            [ -n "$ps_rule" ] && mode="$ps_rule"
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

installPsiphonBinary() {
    if [ -f "$psiphonBin" ]; then
        echo "info: $(msg psiphon_already)"; return 0
    fi

    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS
    echo -e "${cyan}$(msg psiphon_dl)${reset}"
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch_name="x86_64" ;;
        aarch64) arch_name="arm64" ;;
        armv7l)  arch_name="arm" ;;
        *)       echo "${red}$(msg psiphon_arch_unsupported)${reset}"; return 1 ;;
    esac

    local bin_url="https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries/raw/master/linux/psiphon-tunnel-core-${arch_name}"
    curl -fsSL -o "$psiphonBin" "$bin_url" || {
        echo "${red}$(msg psiphon_dl_fail)${reset}"; return 1
    }
    chmod +x "$psiphonBin"
    echo "${green}$(msg psiphon_installed_bin): $psiphonBin${reset}"
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
    # Создаём пользователя и директорию
    id psiphon &>/dev/null || useradd -r -s /sbin/nologin -d /var/lib/psiphon psiphon
    mkdir -p /var/lib/psiphon
    chown -R psiphon:psiphon /var/lib/psiphon
    chown -R psiphon:psiphon /var/log/psiphon
    chmod 755 /var/lib/psiphon
}

setupPsiphonService() {
    cat > "$PSIPHON_SERVICE" << EOF
[Unit]
Description=Psiphon Tunnel Core
After=network.target

[Service]
Type=simple
User=psiphon
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
        echo "${green}$(msg psiphon_running)${reset}"
    else
        echo "${yellow}$(msg psiphon_started)${reset}"
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
    [ ! -f "$psiphonConfigFile" ] && { echo "${red}$(msg psiphon_not_setup)${reset}"; return 1; }
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
    echo "${green}$(msg psiphon_split_ok)${reset}"
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
    echo "${green}$(msg psiphon_global_ok)${reset}"
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
    echo "$(msg psiphon_real_ip) : $(getServerIP)"
    echo "$(msg psiphon_ip)..."
    local ip
    ip=$(curl -s --connect-timeout 15 -x socks5://127.0.0.1:${PSIPHON_PORT} https://api.ipify.org 2>/dev/null || echo "$(msg unavailable)")
    echo "$(msg psiphon_ip) : $ip"
    if [ "$ip" != "$(msg unavailable)" ]; then
        local country
        country=$(curl -s --connect-timeout 8 -x socks5://127.0.0.1:${PSIPHON_PORT}             "http://ip-api.com/line/${ip}?fields=countryCode" 2>/dev/null | tr -d '[:space:]')
        echo "$(msg psiphon_exit_country) : ${country:-$(msg unknown)}"
    fi
}

removePsiphon() {
    echo -e "${red}$(msg psiphon_remove_confirm) $(msg yes_no)${reset}"
    read -r confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop psiphon 2>/dev/null || true
        systemctl disable psiphon 2>/dev/null || true
        rm -f "$PSIPHON_SERVICE" "$psiphonBin" "$psiphonConfigFile" "$psiphonDomainsFile"
        rm -rf /var/lib/psiphon /var/log/psiphon
        systemctl daemon-reload
        removePsiphonFromConfigs
        echo "${green}$(msg removed)${reset}"
    fi
}

installPsiphon() {
    echo -e "${cyan}$(msg psiphon_setup_title)${reset}"

    installPsiphonBinary || return 1

    echo -e "${cyan}$(msg psiphon_country_select)${reset}"
    echo " $(msg country_de)"
    echo " $(msg country_nl)"
    echo " $(msg country_us)"
    echo " $(msg country_gb)"
    echo " $(msg country_fr)"
    echo " $(msg country_at)"
    echo " $(msg country_ca)"
    echo " $(msg country_se)"
    echo " $(msg psiphon_country_auto)"
    echo "$(msg psiphon_country_manual)"
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
        10) read -rp "$(msg psiphon_country_prompt)" country ;;
        *) country="DE" ;;
    esac

    writePsiphonConfig "$country"
    setupPsiphonService

    # Добавляем в Xray конфиги с пустым списком доменов (Split режим)
    applyPsiphonDomains

    echo -e "\n${green}$(msg psiphon_installed)${reset}"
    echo "$(msg psiphon_hint)"
}

changeCountry() {
    [ ! -f "$psiphonConfigFile" ] && { echo "${red}$(msg psiphon_not_setup)${reset}"; return 1; }

    echo -e "${cyan}$(msg psiphon_change_country)${reset}"
    echo " 1) DE  2) NL  3) US  4) GB  5) FR"
    echo " $(msg country_at)  $(msg country_ca)  $(msg country_se)  $(msg psiphon_country_auto)  $(msg psiphon_country_manual)"
    read -rp "Выбор: " c
    local country
    case "$c" in
        1) country="DE" ;; 2) country="NL" ;; 3) country="US" ;;
        4) country="GB" ;; 5) country="FR" ;; 6) country="AT" ;;
        7) country="CA" ;; 8) country="SE" ;; 9) country="" ;;
        10) read -rp "$(msg country): " country ;;
        *) return ;;
    esac

    jq ".EgressRegion = \"$country\"" "$psiphonConfigFile" \
        > "${psiphonConfigFile}.tmp" && mv "${psiphonConfigFile}.tmp" "$psiphonConfigFile"
    systemctl restart psiphon
    echo "${green}$(msg psiphon_country_changed) ${country:-$(msg auto)}. $(msg psiphon_country_restarting)${reset}"
}

managePsiphon() {
    set +e
    while true; do
        clear
        echo -e "${cyan}$(msg psiphon_title)${reset}"
        echo -e "$(msg status): $(getPsiphonStatus)"
        echo ""
        if [ -f "$psiphonConfigFile" ]; then
            local country
            country=$(jq -r '.EgressRegion // "Авто"' "$psiphonConfigFile" 2>/dev/null)
            echo -e "  $(msg country): ${green}${country:-$(msg auto)}${reset}"
            echo -e "  $(msg psiphon_socks5): 127.0.0.1:$PSIPHON_PORT"
            [ -f "$psiphonDomainsFile" ] && echo -e "  $(msg domains_count): $(wc -l < "$psiphonDomainsFile")"
        fi
        echo ""
        echo -e "${green}1.${reset} $(msg psiphon_install)"
        echo -e "${green}2.${reset} $(msg psiphon_mode)"
        echo -e "${green}3.${reset} $(msg psiphon_add)"
        echo -e "${green}4.${reset} $(msg psiphon_del)"
        echo -e "${green}5.${reset} $(msg psiphon_edit)"
        echo -e "${green}6.${reset} $(msg psiphon_country)"
        echo -e "${green}7.${reset} $(msg psiphon_check)"
        echo -e "${green}8.${reset} $(msg psiphon_restart)"
        echo -e "${green}9.${reset} $(msg psiphon_logs)"
        echo -e "${green}10.${reset} $(msg psiphon_remove)"
        echo -e "${green}0.${reset} $(msg back)"
        echo ""
        read -rp "$(msg choose)" choice
        case $choice in
            1)  installPsiphon ;;
            2)
                [ ! -f "$psiphonConfigFile" ] && { echo "${red}$(msg psiphon_not_installed)${reset}"; read -r; continue; }
                echo "$(msg psiphon_mode_1)"
                echo "$(msg psiphon_mode_2)"
                echo "$(msg psiphon_mode_3)"
                echo "$(msg back)"
                read -rp "Выбор: " mode
                case "$mode" in
                    1) togglePsiphonGlobal ;;
                    2) applyPsiphonDomains ;;
                    3) removePsiphonFromConfigs; echo "${green}$(msg psiphon_off_ok)${reset}" ;;
                    0) continue ;;
                esac
                ;;
            3)
                [ ! -f "$psiphonConfigFile" ] && { echo "${red}$(msg psiphon_not_installed)${reset}"; read -r; continue; }
                read -rp "$(msg psiphon_domain_prompt)" domain
                [ -z "$domain" ] && continue
                echo "$domain" >> "$psiphonDomainsFile"
                sort -u "$psiphonDomainsFile" -o "$psiphonDomainsFile"
                applyPsiphonDomains
                echo "${green}$(msg psiphon_domain_added)${reset}"
                ;;
            4)
                [ ! -f "$psiphonDomainsFile" ] && { echo "$(msg warp_list_empty)"; read -r; continue; }
                nl "$psiphonDomainsFile"
                read -rp "$(msg warp_domain_del)" num
                [[ "$num" =~ ^[0-9]+$ ]] && sed -i "${num}d" "$psiphonDomainsFile" && applyPsiphonDomains
                ;;
            5)
                [ ! -f "$psiphonDomainsFile" ] && touch "$psiphonDomainsFile"
                nano "$psiphonDomainsFile"
                applyPsiphonDomains
                ;;
            6)  changeCountry ;;
            7)  checkPsiphonIP ;;
            8)  systemctl restart psiphon && echo "${green}$(msg restarted)${reset}" ;;
            9)  tail -n 50 /var/log/psiphon/psiphon.log 2>/dev/null || journalctl -u psiphon -n 50 --no-pager ;;
            10) removePsiphon ;;
            0)  break ;;
        esac
        [ "${choice}" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}
