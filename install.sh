#!/bin/bash
# =================================================================
# install.sh — Установщик VWN (Xray VLESS + WARP + CDN + Reality)
# Использование:
#   bash install.sh          — первая установка
#   bash install.sh --update — обновить модули (конфиги не трогает)
# =================================================================

set -e

VWN_LIB="/usr/local/lib/vwn"
VWN_BIN="/usr/local/bin/vwn"
GITHUB_RAW="https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main"

# Цвета
red=$(tput setaf 1 && tput bold 2>/dev/null || echo "")
green=$(tput setaf 2 && tput bold 2>/dev/null || echo "")
cyan=$(tput setaf 6 && tput bold 2>/dev/null || echo "")
reset=$(tput sgr0 2>/dev/null || echo "")

MODULES="lang core xray nginx warp reality relay psiphon tor security logs menu"
UPDATE_ONLY=false

# Парсим аргументы
for arg in "$@"; do
    case "$arg" in
        --update) UPDATE_ONLY=true ;;
    esac
done

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "${red}$(msg run_as_root)${reset}"
        exit 1
    fi
}

check_os() {
    if ! command -v apt &>/dev/null && ! command -v dnf &>/dev/null && ! command -v yum &>/dev/null; then
        echo "${red}$(msg os_unsupported)${reset}"
        exit 1
    fi
}

install_deps() {
    echo -e "${cyan}$(msg install_deps)${reset}"
    if command -v apt &>/dev/null; then
        apt-get update -qq
        apt-get install -y --no-install-recommends curl jq bash coreutils 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf install -y curl jq bash 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum install -y curl jq bash 2>/dev/null || true
    fi
}

download_modules() {
    echo -e "${cyan}$(msg install_modules)${reset}"
    mkdir -p "$VWN_LIB"

    for module in $MODULES; do
        echo -n "  $(msg loading) ${module}.sh... "
        if curl -fsSL --connect-timeout 15 \
            "${GITHUB_RAW}/modules/${module}.sh" \
            -o "${VWN_LIB}/${module}.sh" 2>/dev/null; then
            echo "${green}OK${reset}"
        else
            echo "${red}$(msg error)${reset}"
            echo "$(msg module_fail) ${module}.sh"
            return 1
        fi
        chmod 644 "${VWN_LIB}/${module}.sh"
    done
}

install_vwn_binary() {
    echo -e "${cyan}$(msg install_vwn)${reset}"
    curl -fsSL --connect-timeout 15 \
        "${GITHUB_RAW}/vwn" \
        -o "$VWN_BIN" 2>/dev/null || {
        # Fallback: создаём загрузчик локально
        cat > "$VWN_BIN" << 'VWNEOF'
#!/bin/bash
VWN_LIB="/usr/local/lib/vwn"
case "${1:-}" in
    "open-80")
        ufw status | grep -q inactive && exit 0
        ufw allow from any to any port 80 proto tcp comment 'ACME temp' &>/dev/null; exit 0 ;;
    "close-80")
        ufw status | grep -q inactive && exit 0
        ufw status numbered | grep 'ACME temp' | awk -F"[][]" '{print $2}' | sort -rn | while read -r n; do
            echo "y" | ufw delete "$n" &>/dev/null; done; exit 0 ;;
    "update")
        bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh) --update
        exit 0 ;;
esac
for module in core xray nginx warp reality relay psiphon tor security logs menu; do
    [ -f "$VWN_LIB/${module}.sh" ] && source "$VWN_LIB/${module}.sh" || { echo "ERROR: module $module not found"; exit 1; }
done
isRoot
menu "$@"
VWNEOF
    }
    chmod +x "$VWN_BIN"
    echo "${green}vwn $(msg installed_in) $VWN_BIN${reset}"
}

show_version() {
    # Получаем версию из core.sh
    local ver
    ver=$(grep 'VWN_VERSION=' "$VWN_LIB/core.sh" 2>/dev/null | head -1 | grep -oP '"[^"]+"' | tr -d '"')
    echo "${ver:-unknown}"
}

main() {
    check_root
    check_os

    echo -e "${cyan}================================================================${reset}"
    if $UPDATE_ONLY; then
        echo -e "   $(msg update_title)"
    else
        echo -e "   $(msg install_title)"
    fi
    echo -e "${cyan}================================================================${reset}"
    echo ""

    install_deps

    if $UPDATE_ONLY; then
        echo -e "${cyan}$(msg update_modules)${reset}"
        download_modules || exit 1
        install_vwn_binary
        echo -e "\n${green}$(msg update_done): $(show_version)${reset}"
        echo "$(msg run_vwn)"
    else
        download_modules || exit 1
        install_vwn_binary

        echo -e "\n${green}================================================================${reset}"
        echo -e "   $(msg install_done) $VWN_LIB"
        echo -e "   $(msg install_version): $(show_version)"
        echo -e "${green}================================================================${reset}"
        echo ""
        echo -e "$(msg launching_menu)\n"
        sleep 1
        exec "$VWN_BIN"
    fi
}

main "$@"
