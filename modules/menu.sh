#!/bin/bash
# =================================================================
# menu.sh — Главное меню и функция установки
# =================================================================

prepareSoftware() {
    identifyOS
    echo "--- [1/3] $(msg install_deps) ---"
    run_task "Swap-файл"        setupSwap
    run_task "Чистка пакетов"   "rm -f /var/lib/dpkg/lock* && dpkg --configure -a 2>/dev/null || true"
    run_task "Обновление репозиториев" "$PACKAGE_MANAGEMENT_UPDATE"

    echo "--- [2/3] $(msg install_deps) ---"
    for p in tar gpg unzip jq nano ufw socat curl qrencode python3; do
        run_task "Установка $p" "installPackage '$p'" || true
    done
    run_task "Установка Xray-core"       installXray
    run_task "Установка Cloudflare WARP" installWarp
}

prepareSoftwareWs() {
    prepareSoftware
    run_task "Установка Nginx" "installPackage nginx" || true

    echo "--- [3/3] $(msg menu_sep_sec) ---"
    run_task "Настройка UFW" "ufw allow 22/tcp && ufw allow 443/tcp && ufw allow 443/udp && echo 'y' | ufw enable"
    run_task "Системные параметры" applySysctl
}

# Установка VLESS + WebSocket + TLS + Nginx + WARP + CDN
installWsTls() {
    isRoot
    clear
    identifyOS
    echo "${green}$(msg install_type_ws_title)${reset}"
    prepareSoftwareWs

    echo -e "\n${green}--- $(msg install_version) ---${reset}"

    # Домен
    local userDomain validated_domain
    while true; do
        read -rp "$(msg enter_domain_vpn)" userDomain
        userDomain=$(echo "$userDomain" | tr -d ' ')
        if [ -z "$userDomain" ]; then
            echo "${red}$(msg domain_required)${reset}"; continue
        fi
        if ! validated_domain=$(_validateDomain "$userDomain"); then
            echo "${red}$(msg invalid): '$userDomain' — $(msg enter_domain)${reset}"; continue
        fi
        userDomain="$validated_domain"
        break
    done

    # Порт Xray
    local xrayPort
    while true; do
        read -rp "$(msg enter_xray_port)" xrayPort
        [ -z "$xrayPort" ] && xrayPort=16500
        if ! _validatePort "$xrayPort" &>/dev/null; then
            echo "${red}$(msg invalid_port) (1024-65535)${reset}"; continue
        fi
        break
    done

    local xhttpPath
    xhttpPath=$(generateRandomPath)

    # URL заглушки
    local proxyUrl validated_url
    while true; do
        read -rp "$(msg enter_stub_url)" proxyUrl
        [ -z "$proxyUrl" ] && proxyUrl='https://httpbin.org/'
        if ! validated_url=$(_validateUrl "$proxyUrl"); then
            echo "${red}$(msg invalid) URL — https:// $(msg enter_stub_url)${reset}"; continue
        fi
        proxyUrl="$validated_url"
        break
    done

    echo -e "\n${green}---${reset}"
    run_task "Создание конфига Xray"   "writeXrayConfig '$xrayPort' '$xhttpPath' '$userDomain'"
    run_task "Создание конфига Nginx"  "writeNginxConfig '$xrayPort' '$userDomain' '$proxyUrl' '$xhttpPath'"
    run_task "Настройка WARP"          configWarp
    run_task "Выпуск SSL"              "userDomain='$userDomain' configCert"
    run_task "Применение правил WARP"  applyWarpDomains
    run_task "Ротация логов"           setupLogrotate
    run_task "Автоочистка логов"       setupLogClearCron
    run_task "Автообновление SSL"      setupSslCron
    run_task "WARP Watchdog"           setupWarpWatchdog

    systemctl enable --now xray nginx
    systemctl restart xray nginx

    echo -e "\n${green}$(msg install_complete)${reset}"
    getQrCode
}

# Установка VLESS + Reality + WARP
installRealityOnly() {
    isRoot
    clear
    identifyOS
    echo "${green}$(msg install_type_reality_title)${reset}"
    # Все зависимости, WARP, логи — installReality() сделает сам
    installReality
}

install() {
    isRoot
    clear
    echo -e "${cyan}================================================================${reset}"
    echo -e "   $(msg install_type_title)"
    echo -e "${cyan}================================================================${reset}"
    echo ""
    echo -e "\t${green}$(msg install_type_1)${reset}"
    echo -e "\t${green}$(msg install_type_2)${reset}"
    echo ""
    read -rp "$(msg choose)" install_type_choice
    case "${install_type_choice:-1}" in
        1) installWsTls ;;
        2) installRealityOnly ;;
        *) echo "${red}$(msg invalid)${reset}"; return 1 ;;
    esac
}

fullRemove() {
    echo -e "${red}$(msg remove_confirm) $(msg yes_no)${reset}"
    read -r confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop nginx xray xray-reality warp-svc psiphon tor 2>/dev/null || true
        warp-cli disconnect 2>/dev/null || true
        [ -z "${PACKAGE_MANAGEMENT_REMOVE:-}" ] && identifyOS
        uninstallPackage 'nginx*' || true
        uninstallPackage 'cloudflare-warp' || true
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove || true
        systemctl disable xray-reality psiphon 2>/dev/null || true
        rm -f /etc/systemd/system/xray-reality.service
        rm -f /etc/systemd/system/psiphon.service
        rm -f "$torDomainsFile"
        rm -f "$psiphonBin"
        rm -rf /etc/nginx /usr/local/etc/xray /root/.cloudflare_api \
               /var/lib/psiphon /var/log/psiphon \
               /etc/cron.d/acme-renew /etc/cron.d/clear-logs /etc/cron.d/warp-watchdog \
               /usr/local/bin/warp-watchdog.sh /usr/local/bin/clear-logs.sh \
               /etc/sysctl.d/99-xray.conf
        systemctl daemon-reload
        echo "${green}$(msg remove_done)${reset}"
    fi
}

menu() {
    set +e
    # Первичная очистка экрана
    clear
    while true; do
        local s_nginx s_ws s_reality s_warp s_ssl s_bbr s_f2b s_jail s_cdn s_relay s_psiphon s_tor
        clear
        s_nginx=$(getServiceStatus nginx)
        s_ws=$(getServiceStatus xray)
        s_reality=$(getServiceStatus xray-reality)
        s_warp=$(getWarpStatus)
        s_ssl=$(checkCertExpiry)
        s_bbr=$(getBbrStatus)
        s_f2b=$(getF2BStatus)
        s_jail=$(getWebJailStatus)
        s_cdn=$(getCdnStatus)
        s_relay=$(getRelayStatus)
        s_psiphon=$(getPsiphonStatus)
        s_tor=$(getTorStatus)

        echo -e "${cyan}================================================================${reset}"
        printf "   ${red}VWN — VLESS + WARP + CDN + REALITY${reset}  %s\n" "$(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}================================================================${reset}"
        _pad() { local v="$1" w="$2" vis; vis=$(echo "$v" | sed 's/\x1b\[[0-9;]*m//g'); printf "%s%*s" "$v" $((w - ${#vis})) ""; }
        echo -e "  Nginx:    $(_pad "$s_nginx" 16) │  BBR:     $(_pad "$s_bbr" 14) │  CDN:     $s_cdn"
        echo -e "  XHTTP:    $(_pad "$s_ws" 16) │  F2B:     $(_pad "$s_f2b" 14) │  Relay:   $s_relay"
        echo -e "  Reality:  $(_pad "$s_reality" 16) │  SSL:     $(_pad "$s_ssl" 14) │  Psiphon: $s_psiphon"
        echo -e "  WARP:     $(_pad "$s_warp" 16) │  Jail:    $(_pad "$s_jail" 14) │  Tor:     $s_tor"
        echo -e "${cyan}----------------------------------------------------------------${reset}"

        echo -e "  ${green}1.${reset}  $(msg menu_install)"
        echo -e "  ${green}2.${reset}  $(msg menu_qr)"
        echo -e "  ${green}3.${reset}  $(msg menu_uuid)"
        echo -e "  $(msg menu_sep_config)"
        echo -e "  ${green}4.${reset}  $(msg menu_port)"
        echo -e "  ${green}5.${reset}  $(msg menu_wspath)"
        echo -e "  ${green}6.${reset}  $(msg menu_stub)"
        echo -e "  ${green}7.${reset}  $(msg menu_ssl)"
        echo -e "  ${green}8.${reset}  $(msg menu_domain)"
        echo -e "  $(msg menu_sep_cdn)"
        echo -e "  ${green}9.${reset}  $(msg menu_cdn)"
        echo -e "  ${green}10.${reset} $(msg menu_warp_mode)"
        echo -e "  ${green}11.${reset} $(msg menu_warp_add)"
        echo -e "  ${green}12.${reset} $(msg menu_warp_del)"
        echo -e "  ${green}13.${reset} $(msg menu_warp_edit)"
        echo -e "  ${green}14.${reset} $(msg menu_warp_check)"
        echo -e "  $(msg menu_sep_sec)"
        echo -e "  ${green}15.${reset} $(msg menu_bbr)"
        echo -e "  ${green}16.${reset} $(msg menu_f2b)"
        echo -e "  ${green}17.${reset} $(msg menu_jail)"
        echo -e "  ${green}18.${reset} $(msg menu_ssh)"
        echo -e "  ${green}30.${reset} $(msg menu_watchdog)"
        echo -e "  $(msg menu_sep_logs)"
        echo -e "  ${green}19.${reset} $(msg menu_xray_acc)"
        echo -e "  ${green}20.${reset} $(msg menu_xray_err)"
        echo -e "  ${green}21.${reset} $(msg menu_nginx_acc)"
        echo -e "  ${green}22.${reset} $(msg menu_nginx_err)"
        echo -e "  ${green}23.${reset} $(msg menu_clear_logs)"
        echo -e "  $(msg menu_sep_svc)"
        echo -e "  ${green}24.${reset} $(msg menu_restart)"
        echo -e "  ${green}25.${reset} $(msg menu_update_xray)"
        echo -e "  ${green}26.${reset} $(msg menu_remove)"
        echo -e "  $(msg menu_sep_ufw)"
        echo -e "  ${green}27.${reset} $(msg menu_ufw)"
        echo -e "  ${green}28.${reset} $(msg menu_ssl_cron)"
        echo -e "  ${green}29.${reset} $(msg menu_log_cron)"
        echo -e "  $(msg menu_sep_tun)"
        echo -e "  ${green}31.${reset} $(msg menu_reality)"
        echo -e "  ${green}32.${reset} $(msg menu_relay)"
        echo -e "  ${green}33.${reset} $(msg menu_psiphon)"
        echo -e "  ${green}34.${reset} $(msg menu_tor)"
        echo -e "  ${green}35.${reset} $(msg menu_lang)"
        echo -e "  $(msg menu_sep_tools)"
        echo -e "  ${green}36.${reset} $(msg menu_diag)"
        echo -e "  ${green}37.${reset} $(msg menu_users)"
        echo -e "  ${green}38.${reset} $(msg menu_backup)"
        echo -e "  ${green}39.${reset} $(msg menu_cf_update_ip)"
        echo -e "  ${green}40.${reset} $(msg menu_sub)"
        echo -e "  $(msg menu_sep_exit)"
        echo -e "  ${green}0.${reset}  $(msg menu_exit)"
        echo -e "${cyan}----------------------------------------------------------------${reset}"

        read -rp "$(msg choose)" num
        case $num in
            1)  install ;;
            2)  getQrCode ;;
            3)  modifyXrayUUID ;;
            4)  modifyXrayPort ;;
            5)  modifyXhttpPath ;;
            6)  modifyProxyPassUrl ;;
            7)  getConfigInfo && userDomain="$xray_userDomain" && configCert ;;
            8)  modifyDomain ;;
            9)  toggleCdnMode ;;
            39) setupCloudflareIPs && nginx -t && systemctl reload nginx ;;
            40) rebuildAllSubFiles ;;
            10) toggleWarpMode ;;
            11) addDomainToWarpProxy ;;
            12) deleteDomainFromWarpProxy ;;
            13) nano "$warpDomainsFile" && applyWarpDomains ;;
            14) checkWarpStatus ;;
            15) enableBBR ;;
            16) setupFail2Ban ;;
            17) setupWebJail ;;
            18) changeSshPort ;;
            19) tail -n 80 /var/log/xray/access.log 2>/dev/null || echo "$(msg no_logs)" ;;
            20) tail -n 80 /var/log/xray/error.log 2>/dev/null || echo "$(msg no_logs)" ;;
            21) tail -n 80 /var/log/nginx/access.log 2>/dev/null || echo "$(msg no_logs)" ;;
            22) tail -n 80 /var/log/nginx/error.log 2>/dev/null || echo "$(msg no_logs)" ;;
            23) clearLogs ;;
            24) systemctl restart xray xray-reality nginx warp-svc psiphon tor 2>/dev/null || true
                echo "${green}$(msg all_services_restarted)${reset}" ;;
            25) updateXrayCore ;;
            26) fullRemove ;;
            27) manageUFW ;;
            28) manageSslCron ;;
            29) manageLogClearCron ;;
            30) setupWarpWatchdog ;;
            31) manageReality ;;
            32) manageRelay ;;
            33) managePsiphon ;;
            34) manageTor ;;
            35) selectLang; _initLang ;;
            36) manageDiag ;;
            37) manageUsers ;;
            38) manageBackup ;;
            0)  exit 0 ;;
            *)  echo -e "${red}$(msg invalid)${reset}"; sleep 1 ;;
        esac
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}
