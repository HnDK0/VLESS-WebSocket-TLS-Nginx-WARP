#!/bin/bash
# =================================================================
# menu.sh — Главное меню и функция установки
# =================================================================

prepareSoftware() {
    identifyOS
    echo "--- [1/3] Подготовка системы ---"
    run_task "Чистка пакетов" "rm -f /var/lib/dpkg/lock* && dpkg --configure -a 2>/dev/null || true"
    run_task "Обновление репозиториев" "${PACKAGE_MANAGEMENT_UPDATE}"

    echo "--- [2/3] Установка компонентов ---"
    for p in tar gpg unzip nginx jq nano ufw socat curl qrencode python3; do
        run_task "Установка $p" "installPackage $p" || true
    done
    run_task "Установка Xray-core"      installXray
    run_task "Установка Cloudflare WARP" installWarp

    echo "--- [3/3] Безопасность ---"
    run_task "Настройка UFW" "ufw allow 22/tcp && ufw allow 443/tcp && ufw allow 443/udp && echo 'y' | ufw enable"
    run_task "Системные параметры" applySysctl
}

install() {
    isRoot
    clear
    identifyOS
    echo "${green}>>> Установка Xray VLESS + WARP + CDN + Reality <<<${reset}"
    prepareSoftware

    echo -e "\n${green}--- Настройка параметров ---${reset}"
    read -rp "Введите Домен (vpn.example.com): " userDomain
    [ -z "$userDomain" ] && { echo "${red}Домен обязателен!${reset}"; return 1; }
    read -rp "Порт Xray [16500]: " xrayPort
    [ -z "$xrayPort" ] && xrayPort=16500
    wsPath=$(generateRandomPath)
    read -rp "Сайт-заглушка [https://httpbin.org/]: " proxyUrl
    [ -z "$proxyUrl" ] && proxyUrl='https://httpbin.org/'

    echo -e "\n${green}--- Установка ---${reset}"
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

    echo -e "\n${green}Установка завершена!${reset}"
    getQrCode
}

fullRemove() {
    echo -e "${red}Удалить Xray, Nginx, WARP, Psiphon и все конфиги? (y/n)${reset}"
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
        echo "${green}Удаление завершено.${reset}"
    fi
}

menu() {
    set +e
    # Первичная очистка экрана
    clear
    while true; do
        local s_nginx s_xray s_warp s_ssl s_bbr s_f2b s_jail s_cdn s_reality s_relay s_psiphon
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
        # Перемещаем курсор в начало без очистки — нет мигания
        tput cup 0 0

        echo -e "${cyan}================================================================${reset}"
        echo -e "   ${red}XRAY VLESS + WARP + CDN + REALITY${reset} | $(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}================================================================${reset}"
        echo -e "  NGINX: $s_nginx  |  XRAY: $s_xray  |  WARP: $s_warp"
        echo -e "  $s_ssl  |  BBR: $s_bbr  |  F2B: $s_f2b"
        echo -e "  WebJail: $s_jail  |  CDN: $s_cdn  |  Reality: $s_reality"
        echo -e "  Relay: $s_relay  |  Psiphon: $s_psiphon  |  Tor: $s_tor"
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
        echo -e "\t—————————————— Туннели ——————————————————"
        echo -e "\t${green}31.${reset} Управление VLESS + Reality"
        echo -e "\t${green}32.${reset} Управление Relay (внешний сервер)"
        echo -e "\t${green}33.${reset} Управление Psiphon"
        echo -e "\t${green}34.${reset} Управление Tor"
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
            19) tail -n 80 /var/log/xray/access.log 2>/dev/null || echo "Нет логов" ;;
            20) tail -n 80 /var/log/xray/error.log 2>/dev/null || echo "Нет логов" ;;
            21) tail -n 80 /var/log/nginx/access.log 2>/dev/null || echo "Нет логов" ;;
            22) tail -n 80 /var/log/nginx/error.log 2>/dev/null || echo "Нет логов" ;;
            23) clearLogs ;;
            24) systemctl restart xray xray-reality nginx warp-svc psiphon tor 2>/dev/null || true
                echo "${green}Все сервисы перезапущены.${reset}" ;;
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
            0)  exit 0 ;;
            *)  echo -e "${red}Неверный пункт!${reset}"; sleep 1 ;;
        esac
        # Для подменю после возврата — сразу перерисовываем без Enter
        case $num in
            31|32|33|34) tput clear; continue ;;
        esac
        echo -e "\n${cyan}Нажмите Enter...${reset}"
        read -r
    done
}
