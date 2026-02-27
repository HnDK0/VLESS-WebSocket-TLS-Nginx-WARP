#!/bin/bash
# =================================================================
# core.sh — Общие переменные, утилиты, статус-функции
# =================================================================

VWN_VERSION="3.0"
VWN_LIB="/usr/local/lib/vwn"

# Цвета
red=$(tput setaf 1)$(tput bold)
green=$(tput setaf 2)$(tput bold)
yellow=$(tput setaf 3)$(tput bold)
cyan=$(tput setaf 6)$(tput bold)
reset=$(tput sgr0)

# Пути конфигов
configPath='/usr/local/etc/xray/config.json'
realityConfigPath='/usr/local/etc/xray/reality.json'
nginxPath='/etc/nginx/conf.d/xray.conf'
cf_key_file="/root/.cloudflare_api"
warpDomainsFile='/usr/local/etc/xray/warp_domains.txt'
relayDomainsFile='/usr/local/etc/xray/relay_domains.txt'
relayConfigFile='/usr/local/etc/xray/relay.conf'
psiphonDomainsFile='/usr/local/etc/xray/psiphon_domains.txt'
psiphonConfigFile='/usr/local/etc/xray/psiphon.json'
psiphonBin='/usr/local/bin/psiphon-tunnel-core'
torDomainsFile='/usr/local/etc/xray/tor_domains.txt'
warp2DomainsFile='/usr/local/etc/xray/warp2_domains.txt'

getWarp2Status() {
    if systemctl is-active --quiet "wg-quick@warp2" 2>/dev/null &&        systemctl is-active --quiet xray-warp2 2>/dev/null; then
        echo "${green}ON${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

getTorStatus() {
    if systemctl is-active --quiet tor 2>/dev/null; then
        local country="Авто"
        [ -f /etc/tor/torrc ] && grep -q "^ExitNodes" /etc/tor/torrc 2>/dev/null &&             country=$(grep "^ExitNodes" /etc/tor/torrc | grep -oP '\{[A-Z]+\}' | tr -d '{}' | head -1)
        echo "${green}ON ($country)${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

# ============================================================
# СИСТЕМА
# ============================================================

isRoot() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "${red}Запустите скрипт от root!${reset}"
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
    local pkg="$1"
    if ${PACKAGE_MANAGEMENT_INSTALL} "$pkg" &>/dev/null; then
        echo "info: $pkg installed."
    else
        echo "warn: Fixing dependencies for $pkg..."
        dpkg --configure -a 2>/dev/null || true
        ${PACKAGE_MANAGEMENT_UPDATE} &>/dev/null || true
        if ${PACKAGE_MANAGEMENT_INSTALL} "$pkg"; then
            echo "info: $pkg installed after fix."
        else
            echo "${red}error: Installation of $pkg failed.${reset}"
            return 1
        fi
    fi
}

uninstallPackage() {
    ${PACKAGE_MANAGEMENT_REMOVE} "$1" && echo "info: $1 uninstalled."
}

run_task() {
    local msg="$1"; shift
    echo -e "\n${yellow}>>> $msg${reset}"
    if eval "$@"; then
        echo -e "[${green} DONE ${reset}] $msg"
    else
        echo -e "[${red} FAIL ${reset}] $msg"
        return 1
    fi
}

setupAlias() {
    ln -sf "$VWN_LIB/../bin/vwn" /usr/local/bin/vwn 2>/dev/null || true
    echo -e "${green}Команда 'vwn' доступна.${reset}"
}

generateRandomPath() {
    echo "/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 12)"
}

# ============================================================
# СЕТЬ
# ============================================================

getServerIP() {
    local ip
    for url in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://checkip.amazonaws.com"; do
        ip=$(curl -s --connect-timeout 5 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"; return
        fi
    done
    ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    echo "${ip:-UNKNOWN}"
}

# ============================================================
# СТАТУС СЕРВИСОВ
# ============================================================

getServiceStatus() {
    if systemctl is-active --quiet "$1"; then
        echo "${green}RUNNING${reset}"
    else
        echo "${red}STOPPED${reset}"
    fi
}

getWarpStatusRaw() {
    if command -v warp-cli &>/dev/null; then
        warp-cli --accept-tos status 2>/dev/null | grep -q "Connected" && echo "ACTIVE" || echo "OFF"
    else
        echo "NOT_INSTALLED"
    fi
}

getBbrStatus() {
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr" \
        && echo "${green}ON${reset}" || echo "${red}OFF${reset}"
}

getF2BStatus() {
    systemctl is-active --quiet fail2ban 2>/dev/null \
        && echo "${green}ON${reset}" || echo "${red}OFF${reset}"
}

getWebJailStatus() {
    if [ -f /etc/fail2ban/filter.d/nginx-probe.conf ]; then
        fail2ban-client status nginx-probe &>/dev/null \
            && echo "${green}PROTECTED${reset}" || echo "${yellow}OFF${reset}"
    else
        echo "${red}NO${reset}"
    fi
}

getCdnStatus() {
    [ -f /etc/nginx/conf.d/cloudflare_whitelist.conf ] \
        && echo "${green}ON${reset}" || echo "${red}OFF${reset}"
}

checkCertExpiry() {
    if [ -f /etc/nginx/cert/cert.pem ]; then
        local expire_date expire_epoch now_epoch days_left
        expire_date=$(openssl x509 -enddate -noout -in /etc/nginx/cert/cert.pem | cut -d= -f2)
        expire_epoch=$(date -d "$expire_date" +%s)
        now_epoch=$(date +%s)
        days_left=$(( (expire_epoch - now_epoch) / 86400 ))
        if   [ "$days_left" -le 0  ]; then echo "${red}SSL: EXPIRED!${reset}"
        elif [ "$days_left" -lt 15 ]; then echo "${red}SSL: $days_left d${reset}"
        else echo "${green}SSL: OK ($days_left d)${reset}"; fi
    else
        echo "${red}SSL: MISSING${reset}"
    fi
}
