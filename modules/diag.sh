#!/bin/bash
# =================================================================
# diag.sh — Диагностика всех компонентов VWN
# =================================================================

# Символы статуса
_OK="${green}✓${reset}"
_FAIL="${red}✗${reset}"
_WARN="${yellow}!${reset}"
_SKIP="${cyan}-${reset}"

# Результаты для итогового отчёта
_DIAG_ISSUES=()

_pass() { echo -e "  $_OK  $1"; }
_fail() { echo -e "  $_FAIL  $1"; _DIAG_ISSUES+=("$1"); }
_warn() { echo -e "  $_WARN  $1"; }
_skip() { echo -e "  $_SKIP  $1 $(msg diag_skip)"; }

# ── Проверки ──────────────────────────────────────────────────────

_diagSystem() {
    echo -e "${cyan}[ $(msg diag_section_system) ]${reset}"

    # RAM
    local ram_mb
    ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    local ram_free
    ram_free=$(free -m | awk '/^Mem:/{print $7}')
    if [ "$ram_free" -lt 50 ]; then
        _fail "$(msg diag_ram): ${ram_free}MB $(msg diag_ram_low)"
    else
        _pass "$(msg diag_ram): ${ram_mb}MB total, ${ram_free}MB $(msg diag_ram_free)"
    fi

    # Диск
    local disk_free
    disk_free=$(df -m / | awk 'NR==2{print $4}')
    if [ "$disk_free" -lt 200 ]; then
        _fail "$(msg diag_disk): ${disk_free}MB $(msg diag_disk_low)"
    else
        _pass "$(msg diag_disk): ${disk_free}MB $(msg diag_ram_free)"
    fi

    # Swap
    local swap_total
    swap_total=$(free -m | awk '/^Swap:/{print $2}')
    if [ "${swap_total:-0}" -eq 0 ]; then
        _warn "$(msg diag_swap_none)"
    else
        _pass "$(msg diag_swap): ${swap_total}MB"
    fi

    # Время — важно для TLS
    local time_offset
    time_offset=$(timedatectl 2>/dev/null | grep "System clock" | grep -c "yes" || echo 0)
    if [ "$time_offset" -eq 0 ]; then
        # Проверяем через другой способ
        if timedatectl 2>/dev/null | grep -q "synchronized: yes"; then
            _pass "$(msg diag_time_ok)"
        else
            _warn "$(msg diag_time_warn)"
        fi
    else
        _pass "$(msg diag_time_ok)"
    fi
    echo ""
}

_diagXray() {
    echo -e "${cyan}[ $(msg diag_section_xray) ]${reset}"

    if ! command -v xray &>/dev/null; then
        _fail "$(msg diag_xray_missing)"
        echo ""
        return
    fi
    _pass "$(msg diag_xray_installed): $(xray version 2>/dev/null | head -1 | grep -oP 'Xray \S+')"

    # WS конфиг
    if [ -f "$configPath" ]; then
        if xray -test -config "$configPath" &>/dev/null; then
            _pass "$(msg diag_xhttp_config_ok)"
        else
            _fail "$(msg diag_xhttp_config_bad)"
            xray -test -config "$configPath" 2>&1 | head -5 | sed 's/^/      /'
        fi

        if systemctl is-active --quiet xray 2>/dev/null; then
            _pass "$(msg diag_xhttp_running)"
        else
            _fail "$(msg diag_xhttp_stopped)"
        fi

        # Порт слушается
        local xray_port
        xray_port=$(jq -r '.inbounds[0].port' "$configPath" 2>/dev/null)
        if ss -tlnp 2>/dev/null | grep -q ":${xray_port}"; then
            _pass "$(msg diag_port_listen): $xray_port"
        else
            _fail "$(msg diag_port_not_listen): $xray_port"
        fi
    else
        _skip "WebSocket $(msg diag_not_installed)"
    fi

    # Reality конфиг
    if [ -f "$realityConfigPath" ]; then
        if xray -test -config "$realityConfigPath" &>/dev/null; then
            _pass "$(msg diag_reality_config_ok)"
        else
            _fail "$(msg diag_reality_config_bad)"
            xray -test -config "$realityConfigPath" 2>&1 | head -5 | sed 's/^/      /'
        fi

        if systemctl is-active --quiet xray-reality 2>/dev/null; then
            _pass "$(msg diag_reality_running)"
        else
            _fail "$(msg diag_reality_stopped)"
        fi

        local reality_port
        reality_port=$(jq -r '.inbounds[0].port' "$realityConfigPath" 2>/dev/null)
        if ss -tlnp 2>/dev/null | grep -q ":${reality_port}"; then
            _pass "$(msg diag_port_listen): $reality_port"
        else
            _fail "$(msg diag_port_not_listen): $reality_port"
        fi
    else
        _skip "Reality $(msg diag_not_installed)"
    fi
    echo ""
}

_diagNginx() {
    echo -e "${cyan}[ $(msg diag_section_nginx) ]${reset}"

    if ! command -v nginx &>/dev/null; then
        _skip "Nginx $(msg diag_not_installed)"
        echo ""
        return
    fi

    if nginx -t &>/dev/null; then
        _pass "$(msg diag_nginx_config_ok)"
    else
        _fail "$(msg diag_nginx_config_bad)"
        nginx -t 2>&1 | sed 's/^/      /'
    fi

    if systemctl is-active --quiet nginx 2>/dev/null; then
        _pass "$(msg diag_nginx_running)"
    else
        _fail "$(msg diag_nginx_stopped)"
    fi

    # Порт 443 слушается
    if ss -tlnp 2>/dev/null | grep -q ':443'; then
        _pass "$(msg diag_port_listen): 443"
    else
        _fail "$(msg diag_port_not_listen): 443"
    fi

    # SSL сертификат
    if [ -f /etc/nginx/cert/cert.pem ]; then
        local expire_date expire_epoch now_epoch days_left
        expire_date=$(openssl x509 -enddate -noout -in /etc/nginx/cert/cert.pem 2>/dev/null | cut -d= -f2)
        expire_epoch=$(date -d "$expire_date" +%s 2>/dev/null)
        now_epoch=$(date +%s)
        days_left=$(( (expire_epoch - now_epoch) / 86400 ))
        if [ "$days_left" -le 0 ]; then
            _fail "$(msg diag_ssl_expired)"
        elif [ "$days_left" -lt 15 ]; then
            _warn "$(msg diag_ssl_expiring): $days_left $(msg diag_days)"
        else
            _pass "$(msg diag_ssl_ok): $days_left $(msg diag_days)"
        fi

        # Домен совпадает с сертификатом
        local domain_in_cert
        domain_in_cert=$(openssl x509 -noout -text -in /etc/nginx/cert/cert.pem 2>/dev/null | grep -oP '(?<=DNS:)[^,\s]+' | head -1)
        local domain_in_nginx
        domain_in_nginx=$(grep -E '^\s*server_name\s+' "$nginxPath" 2>/dev/null | grep -v '_' | awk '{print $2}' | tr -d ';' | head -1)
        if [ -n "$domain_in_cert" ] && [ -n "$domain_in_nginx" ]; then
            if [ "$domain_in_cert" = "$domain_in_nginx" ] || [[ "$domain_in_cert" == *"${domain_in_nginx}"* ]]; then
                _pass "$(msg diag_ssl_domain_match): $domain_in_nginx"
            else
                _warn "$(msg diag_ssl_domain_mismatch): cert=$domain_in_cert nginx=$domain_in_nginx"
            fi
        fi
    else
        _fail "$(msg diag_ssl_missing)"
    fi

    # DNS резолвинг домена
    local domain_in_nginx
    domain_in_nginx=$(grep -E '^\s*server_name\s+' "$nginxPath" 2>/dev/null | grep -v '_' | awk '{print $2}' | tr -d ';' | head -1)
    if [ -n "$domain_in_nginx" ]; then
        local resolved_ip server_ip
        resolved_ip=$(getent hosts "$domain_in_nginx" 2>/dev/null | awk '{print $1}' | head -1)
        server_ip=$(getServerIP)
        if [ -z "$resolved_ip" ]; then
            _fail "$(msg diag_dns_fail): $domain_in_nginx"
        elif [ "$resolved_ip" = "$server_ip" ]; then
            _pass "$(msg diag_dns_ok): $domain_in_nginx → $resolved_ip"
        else
            _warn "$(msg diag_dns_mismatch): $domain_in_nginx → $resolved_ip ($(msg diag_server_ip): $server_ip)"
        fi
    fi
    echo ""
}

_diagWarp() {
    echo -e "${cyan}[ $(msg diag_section_warp) ]${reset}"

    if ! command -v warp-cli &>/dev/null; then
        _skip "WARP $(msg diag_not_installed)"
        echo ""
        return
    fi

    if systemctl is-active --quiet warp-svc 2>/dev/null; then
        _pass "$(msg diag_warp_svc_running)"
    else
        _fail "$(msg diag_warp_svc_stopped)"
        echo ""
        return
    fi

    local warp_status
    warp_status=$(warp-cli --accept-tos status 2>/dev/null)
    if echo "$warp_status" | grep -q "Connected"; then
        _pass "$(msg diag_warp_connected)"
    else
        _fail "$(msg diag_warp_disconnected)"
    fi

    # Проверяем что SOCKS5 реально работает
    local warp_ip
    warp_ip=$(curl -s --connect-timeout 8 -x socks5://127.0.0.1:40000 https://api.ipify.org 2>/dev/null)
    if [ -n "$warp_ip" ]; then
        _pass "$(msg diag_warp_socks_ok): $warp_ip"
    else
        _fail "$(msg diag_warp_socks_fail)"
    fi
    echo ""
}

_diagTunnels() {
    local any=false

    if [ -f "$psiphonConfigFile" ]; then
        any=true
        echo -e "${cyan}[ $(msg diag_section_psiphon) ]${reset}"
        if systemctl is-active --quiet psiphon 2>/dev/null; then
            _pass "$(msg diag_psiphon_running)"
            local ps_ip
            ps_ip=$(curl -s --connect-timeout 10 -x socks5://127.0.0.1:40002 https://api.ipify.org 2>/dev/null)
            [ -n "$ps_ip" ] && _pass "$(msg diag_psiphon_socks_ok): $ps_ip" \
                            || _warn "$(msg diag_psiphon_socks_slow)"
        else
            _fail "$(msg diag_psiphon_stopped)"
        fi
        echo ""
    fi

    if command -v tor &>/dev/null; then
        any=true
        echo -e "${cyan}[ $(msg diag_section_tor) ]${reset}"
        if systemctl is-active --quiet tor 2>/dev/null; then
            _pass "$(msg diag_tor_running)"
        else
            _fail "$(msg diag_tor_stopped)"
        fi
        echo ""
    fi

    if [ -f "$relayConfigFile" ]; then
        any=true
        echo -e "${cyan}[ $(msg diag_section_relay) ]${reset}"
        source "$relayConfigFile" 2>/dev/null
        _pass "$(msg diag_relay_configured): ${RELAY_PROTOCOL}://${RELAY_HOST}:${RELAY_PORT}"
        echo ""
    fi
}

_diagConnectivity() {
    echo -e "${cyan}[ $(msg diag_section_connect) ]${reset}"

    # Интернет
    if curl -s --connect-timeout 5 https://api.ipify.org &>/dev/null; then
        local pub_ip
        pub_ip=$(getServerIP)
        _pass "$(msg diag_internet_ok): $pub_ip"
    else
        _fail "$(msg diag_internet_fail)"
    fi

    # Доступность домена снаружи (если есть nginx и домен)
    local domain_in_nginx
    domain_in_nginx=$(grep -E '^\s*server_name\s+' "$nginxPath" 2>/dev/null | grep -v '_' | awk '{print $2}' | tr -d ';' | head -1)
    if [ -n "$domain_in_nginx" ] && command -v nginx &>/dev/null; then
        local http_code
        http_code=$(curl -s --connect-timeout 8 -o /dev/null -w "%{http_code}" "https://${domain_in_nginx}/" 2>/dev/null)
        if [ "$http_code" = "200" ] || [ "$http_code" = "301" ] || [ "$http_code" = "302" ]; then
            _pass "$(msg diag_domain_reachable): $domain_in_nginx ($http_code)"
        elif [ "$http_code" = "000" ]; then
            _fail "$(msg diag_domain_unreachable): $domain_in_nginx"
        else
            _warn "$(msg diag_domain_code): $domain_in_nginx → HTTP $http_code"
        fi
    fi
    echo ""
}

# ── Публичные функции ─────────────────────────────────────────────

runFullDiag() {
    clear
    _DIAG_ISSUES=()
    echo -e "${cyan}================================================================${reset}"
    echo -e "   $(msg diag_title) | $(date +'%d.%m.%Y %H:%M')"
    echo -e "${cyan}================================================================${reset}"
    echo ""

    _diagSystem
    _diagXray
    _diagNginx
    _diagWarp
    _diagTunnels
    _diagConnectivity

    # Итог
    echo -e "${cyan}================================================================${reset}"
    local issue_count=${#_DIAG_ISSUES[@]}
    if [ "$issue_count" -eq 0 ]; then
        echo -e "  ${green}$(msg diag_all_ok)${reset}"
    else
        echo -e "  ${red}$(msg diag_issues_found): $issue_count${reset}"
        echo ""
        for issue in "${_DIAG_ISSUES[@]}"; do
            echo -e "  ${red}✗${reset} $issue"
        done
    fi
    echo -e "${cyan}================================================================${reset}"
}

manageDiag() {
    set +e
    while true; do
        clear
        echo -e "${cyan}$(msg diag_menu_title)${reset}"
        echo ""
        echo -e "${green}1.${reset} $(msg diag_run_full)"
        echo -e "${green}2.${reset} $(msg diag_run_system)"
        echo -e "${green}3.${reset} $(msg diag_run_xray)"
        echo -e "${green}4.${reset} $(msg diag_run_nginx)"
        echo -e "${green}5.${reset} $(msg diag_run_warp)"
        echo -e "${green}6.${reset} $(msg diag_run_tunnels)"
        echo -e "${green}7.${reset} $(msg diag_run_connect)"
        echo -e "${green}0.${reset} $(msg back)"
        echo ""
        read -rp "$(msg choose)" choice
        case $choice in
            1) runFullDiag ;;
            2) clear; _DIAG_ISSUES=(); _diagSystem ;;
            3) clear; _DIAG_ISSUES=(); _diagXray ;;
            4) clear; _DIAG_ISSUES=(); _diagNginx ;;
            5) clear; _DIAG_ISSUES=(); _diagWarp ;;
            6) clear; _DIAG_ISSUES=(); _diagTunnels ;;
            7) clear; _DIAG_ISSUES=(); _diagConnectivity ;;
            0) break ;;
        esac
        [ "$choice" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}
