#!/bin/bash
# =================================================================
# menu.sh — Главное меню и функция установки
# =================================================================

prepareSoftware() {
    identifyOS
    echo "--- [1/3] $(msg install_version) ---"
    run_task "Чистка пакетов" "rm -f /var/lib/dpkg/lock* && dpkg --configure -a 2>/dev/null || true"
    run_task "Обновление репозиториев" "${PACKAGE_MANAGEMENT_UPDATE}"

    echo "--- [2/3] $(msg install_done) ---"
    for p in tar gpg unzip nginx jq nano ufw socat curl qrencode python3; do
        run_task "Установка $p" "installPackage $p" || true
    done
    run_task "Установка Xray-core"      installXray
    run_task "Установка Cloudflare WARP" installWarp

    echo "--- [3/3] $(msg menu_sep_sec) ---"
    run_task "Настройка UFW" "ufw allow 22/tcp && ufw allow 443/tcp && ufw allow 443/udp && echo 'y' | ufw enable"
    run_task "Системные параметры" applySysctl
}

install() {
    isRoot
    clear
    identifyOS
    echo "${green}$(msg install_xray_title)${reset}"
    prepareSoftware

    echo -e "\n${green}--- $(msg install_version) ---${reset}"
    read -rp "$(msg enter_domain_vpn)" userDomain
    [ -z "$userDomain" ] && { echo "${red}$(msg domain_required)${reset}"; return 1; }
    read -rp "$(msg enter_xray_port)" xrayPort
    [ -z "$xrayPort" ] && xrayPort=16500
    wsPath=$(generateRandomPath)
    read -rp "$(msg enter_stub_url)" proxyUrl
    [ -z "$proxyUrl" ] && proxyUrl='https://httpbin.org/'

    echo -e "\n${green}---${reset}"
    run_task "Создание конфига Xray"   "writeXrayConfig '$xrayPort' '$wsPath'"
    run_task "Создание конфига Nginx"  "writeNginxConfig '$xrayPort' '$userDomain' '$proxyUrl' '$wsPath'"
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
        local s_nginx s_xray s_warp s_ssl s_bbr s_f2b s_jail s_cdn s_reality s_relay s_psiphon
        clear
        s_nginx=$(getServiceStatus nginx)
        s_xray=$(getServiceStatus xray)
        s_warp=$(getWarpStatus)
        s_ssl=$(checkCertExpiry)
        s_bbr=$(getBbrStatus)
        s_f2b=$(getF2BStatus)
        s_jail=$(getWebJailStatus)
        s_cdn=$(getCdnStatus)
        s_reality=$(getRealityStatus)
        s_relay=$(getRelayStatus)
        s_psiphon=$(getPsiphonStatus)
        s_tor=$(getTorStatus)

        echo -e "${cyan}================================================================${reset}"
        echo -e "   ${red}XRAY VLESS + WARP + CDN + REALITY${reset} | $(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}================================================================${reset}"
        echo -e "  NGINX: $s_nginx  |  XRAY: $s_xray  |  WARP: $s_warp"
        echo -e "  $s_ssl  |  BBR: $s_bbr  |  F2B: $s_f2b"
        echo -e "  WebJail: $s_jail  |  CDN: $s_cdn  |  Reality: $s_reality"
        echo -e "  Relay: $s_relay  |  Psiphon: $s_psiphon  |  Tor: $s_tor"
        echo -e "${cyan}----------------------------------------------------------------${reset}"

        echo -e "\t${green}1.${reset}  $(msg menu_install)"
        echo -e "\t${green}2.${reset}  $(msg menu_qr)"
        echo -e "\t${green}3.${reset}  $(msg menu_uuid)"
        echo -e "\t$(msg menu_sep_config)"
        echo -e "\t${green}4.${reset}  $(msg menu_port)"
        echo -e "\t${green}5.${reset}  $(msg menu_wspath)"
        echo -e "\t${green}6.${reset}  $(msg menu_stub)"
        echo -e "\t${green}7.${reset}  $(msg menu_ssl)"
        echo -e "\t${green}8.${reset}  $(msg menu_domain)"
        echo -e "\t$(msg menu_sep_cdn)"
        echo -e "\t${green}9.${reset}  $(msg menu_cdn)"
        echo -e "\t${green}10.${reset} $(msg menu_warp_mode)"
        echo -e "\t${green}11.${reset} $(msg menu_warp_add)"
        echo -e "\t${green}12.${reset} $(msg menu_warp_del)"
        echo -e "\t${green}13.${reset} $(msg menu_warp_edit)"
        echo -e "\t${green}14.${reset} $(msg menu_warp_check)"
        echo -e "\t$(msg menu_sep_sec)"
        echo -e "\t${green}15.${reset} $(msg menu_bbr)"
        echo -e "\t${green}16.${reset} $(msg menu_f2b)"
        echo -e "\t${green}17.${reset} $(msg menu_jail)"
        echo -e "\t${green}18.${reset} $(msg menu_ssh)"
        echo -e "\t${green}30.${reset} $(msg menu_watchdog)"
        echo -e "\t$(msg menu_sep_logs)"
        echo -e "\t${green}19.${reset} $(msg menu_xray_acc)"
        echo -e "\t${green}20.${reset} $(msg menu_xray_err)"
        echo -e "\t${green}21.${reset} $(msg menu_nginx_acc)"
        echo -e "\t${green}22.${reset} $(msg menu_nginx_err)"
        echo -e "\t${green}23.${reset} $(msg menu_clear_logs)"
        echo -e "\t$(msg menu_sep_svc)"
        echo -e "\t${green}24.${reset} $(msg menu_restart)"
        echo -e "\t${green}25.${reset} $(msg menu_update_xray)"
        echo -e "\t${green}26.${reset} $(msg menu_remove)"
        echo -e "\t$(msg menu_sep_ufw)"
        echo -e "\t${green}27.${reset} $(msg menu_ufw)"
        echo -e "\t${green}28.${reset} $(msg menu_ssl_cron)"
        echo -e "\t${green}29.${reset} $(msg menu_log_cron)"
        echo -e "\t$(msg menu_sep_tun)"
        echo -e "\t${green}31.${reset} $(msg menu_reality)"
        echo -e "\t${green}32.${reset} $(msg menu_relay)"
        echo -e "\t${green}33.${reset} $(msg menu_psiphon)"
        echo -e "\t${green}34.${reset} $(msg menu_tor)"
        echo -e "\t${green}35.${reset} $(msg menu_lang)"
        echo -e "\t$(msg menu_sep_exit)"
        echo -e "\t${green}0.${reset}  $(msg menu_exit)"
        echo -e "${cyan}----------------------------------------------------------------${reset}"

        read -rp "$(msg choose)" num
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
            0)  exit 0 ;;
            *)  echo -e "${red}$(msg invalid)${reset}"; sleep 1 ;;
        esac
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}
