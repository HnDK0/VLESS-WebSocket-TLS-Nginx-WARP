#!/bin/bash
# =================================================================
# warp2.sh — WARP-in-WARP: второй WARP туннель поверх первого
# Использует wgcf для генерации WireGuard конфига
# Трафик к Cloudflare WG идёт через первый WARP (SOCKS5:40000)
# Второй WARP доступен как SOCKS5 на 127.0.0.1:40001 (через xray)
# =================================================================

WARP2_WG_CONF="/etc/wireguard/warp2.conf"
WARP2_SERVICE="wg-quick@warp2"
WARP2_XRAY_CONF="/usr/local/etc/xray/warp2-proxy.json"
WARP2_XRAY_SERVICE="/etc/systemd/system/xray-warp2.service"
WARP2_PORT=40001
warp2DomainsFile='/usr/local/etc/xray/warp2_domains.txt'

# Cloudflare WireGuard endpoint
CF_WG_ENDPOINT="162.159.193.1:2408"

getWarp2Status() {
    if systemctl is-active --quiet "$WARP2_SERVICE" 2>/dev/null && \
       systemctl is-active --quiet xray-warp2 2>/dev/null; then
        echo "${green}ON (SOCKS5:${WARP2_PORT})${reset}"
    elif systemctl is-active --quiet "$WARP2_SERVICE" 2>/dev/null; then
        echo "${yellow}WG UP / Proxy OFF${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

installWgcf() {
    if command -v wgcf &>/dev/null; then
        echo "info: wgcf уже установлен."; return 0
    fi
    echo -e "${cyan}Установка wgcf...${reset}"
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch_name="amd64" ;;
        aarch64) arch_name="arm64" ;;
        armv7l)  arch_name="armv7" ;;
        *) echo "${red}Архитектура $arch не поддерживается.${reset}"; return 1 ;;
    esac
    local ver
    ver=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest \
        2>/dev/null | grep -oP '"tag_name": "\K[^"]+' | head -1)
    ver="${ver:-v2.0.12}"
    curl -fsSL -o /usr/local/bin/wgcf \
        "https://github.com/ViRb3/wgcf/releases/download/${ver}/wgcf_${ver#v}_linux_${arch_name}" || {
        echo "${red}Ошибка скачивания wgcf.${reset}"; return 1
    }
    chmod +x /usr/local/bin/wgcf
    echo "${green}wgcf установлен.${reset}"
}

installWireGuard() {
    if command -v wg &>/dev/null; then
        echo "info: wireguard уже установлен."; return 0
    fi
    echo -e "${cyan}Установка WireGuard...${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS
    ${PACKAGE_MANAGEMENT_INSTALL} wireguard-tools || {
        echo "${red}Ошибка установки WireGuard.${reset}"; return 1
    }
}

generateWarp2Config() {
    echo -e "${cyan}Генерация нового WARP аккаунта...${reset}"
    local tmpdir
    tmpdir=$(mktemp -d)
    cd "$tmpdir"

    # Регистрируем новый аккаунт через первый WARP
    # wgcf register использует HTTPS — заворачиваем через первый WARP
    ALL_PROXY="socks5://127.0.0.1:40000" \
    HTTPS_PROXY="socks5://127.0.0.1:40000" \
    wgcf register --accept-tos 2>/dev/null || {
        # Fallback: без прокси (если первый WARP не нужен для регистрации)
        wgcf register --accept-tos 2>/dev/null || {
            echo "${red}Ошибка регистрации WARP аккаунта.${reset}"
            cd /; rm -rf "$tmpdir"; return 1
        }
    }

    ALL_PROXY="socks5://127.0.0.1:40000" \
    HTTPS_PROXY="socks5://127.0.0.1:40000" \
    wgcf generate 2>/dev/null || \
    wgcf generate 2>/dev/null || {
        echo "${red}Ошибка генерации конфига.${reset}"
        cd /; rm -rf "$tmpdir"; return 1
    }

    # Читаем сгенерированный конфиг
    local wg_conf="$tmpdir/wgcf-profile.conf"
    [ ! -f "$wg_conf" ] && { echo "${red}Файл конфига не найден.${reset}"; cd /; rm -rf "$tmpdir"; return 1; }

    local private_key address
    private_key=$(grep "PrivateKey" "$wg_conf" | awk '{print $3}')
    address=$(grep "Address" "$wg_conf" | awk '{print $3}' | head -1)

    # Получаем публичный ключ Cloudflare из конфига
    local public_key
    public_key=$(grep "PublicKey" "$wg_conf" | awk '{print $3}')

    mkdir -p /etc/wireguard

    # Пишем конфиг — endpoint трафик будет идти через таблицу маршрутизации warp2
    # Используем FwMark чтобы избежать рекурсии с первым WARP
    cat > "$WARP2_WG_CONF" << EOF
[Interface]
PrivateKey = ${private_key}
Address = ${address}
DNS = 1.1.1.1
PostUp = ip rule add fwmark 51821 table 51821; ip route add default dev warp2 table 51821; ip route add ${CF_WG_ENDPOINT%:*}/32 via \$(ip route | grep default | awk '{print \$3}' | head -1) table main
PostDown = ip rule del fwmark 51821 table 51821 2>/dev/null; ip route del default dev warp2 table 51821 2>/dev/null; ip route del ${CF_WG_ENDPOINT%:*}/32 table main 2>/dev/null
Table = off

[Peer]
PublicKey = ${public_key}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${CF_WG_ENDPOINT}
PersistentKeepalive = 25
EOF

    cd /; rm -rf "$tmpdir"
    echo "${green}WireGuard конфиг для WARP2 создан.${reset}"
}

setupWarp2ProxyService() {
    # Xray инстанс который слушает на 40001 и проксирует через warp2 интерфейс
    mkdir -p /usr/local/etc/xray

    cat > "$WARP2_XRAY_CONF" << EOF
{
    "log": {"loglevel": "none"},
    "inbounds": [{
        "port": ${WARP2_PORT},
        "listen": "127.0.0.1",
        "protocol": "socks",
        "settings": {"auth": "noauth", "udp": true}
    }],
    "outbounds": [{
        "tag": "warp2-out",
        "protocol": "freedom",
        "settings": {"domainStrategy": "UseIPv4"},
        "streamSettings": {
            "sockopt": {
                "mark": 51821,
                "interface": "warp2"
            }
        }
    }]
}
EOF

    cat > "$WARP2_XRAY_SERVICE" << EOF
[Unit]
Description=Xray WARP2 Proxy
After=network.target ${WARP2_SERVICE}.service
Requires=${WARP2_SERVICE}.service

[Service]
Type=simple
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config ${WARP2_XRAY_CONF}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    echo "${green}Сервис xray-warp2 создан.${reset}"
}

startWarp2() {
    echo -e "${cyan}Запуск WARP2...${reset}"

    # Переименовываем интерфейс в warp2 через PostUp/PostDown конфига
    # wg-quick использует имя файла как имя интерфейса
    systemctl enable "$WARP2_SERVICE"
    systemctl restart "$WARP2_SERVICE"
    sleep 3

    if ip link show warp2 &>/dev/null; then
        echo "${green}WireGuard интерфейс warp2 поднят.${reset}"
    else
        echo "${red}Ошибка: интерфейс warp2 не поднялся.${reset}"
        journalctl -u "$WARP2_SERVICE" -n 20 --no-pager
        return 1
    fi

    systemctl enable xray-warp2
    systemctl restart xray-warp2
    sleep 2

    # Проверка
    local ip
    ip=$(curl -s --connect-timeout 15 \
        -x socks5://127.0.0.1:${WARP2_PORT} \
        https://api.ipify.org 2>/dev/null || echo "")
    if [ -n "$ip" ]; then
        echo "${green}WARP2 работает! IP: $ip${reset}"
    else
        echo "${yellow}WARP2 запущен, но проверка не прошла.${reset}"
    fi
}

applyWarp2Outbound() {
    local warp2_ob="{\"tag\":\"warp2\",\"protocol\":\"socks\",\"settings\":{\"servers\":[{\"address\":\"127.0.0.1\",\"port\":${WARP2_PORT}}]}}"

    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        local has_ob
        has_ob=$(jq '.outbounds[] | select(.tag=="warp2")' "$cfg" 2>/dev/null)
        if [ -z "$has_ob" ]; then
            jq --argjson ob "$warp2_ob" '.outbounds += [$ob]' \
                "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
        fi
        local has_rule
        has_rule=$(jq '.routing.rules[] | select(.outboundTag=="warp2")' "$cfg" 2>/dev/null)
        if [ -z "$has_rule" ]; then
            jq '.routing.rules = [.routing.rules[0]] + [{"type":"field","domain":[],"outboundTag":"warp2"}] + .routing.rules[1:]' \
                "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
        fi
    done
}

applyWarp2Domains() {
    [ ! -f "$warp2DomainsFile" ] && touch "$warp2DomainsFile"
    local domains_json
    domains_json=$(awk 'NF {printf "\"domain:%s\",", $1}' "$warp2DomainsFile" | sed 's/,$//')

    applyWarp2Outbound

    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        jq "(.routing.rules[] | select(.outboundTag == \"warp2\")) |= (.domain = [$domains_json] | del(.port))" \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    done
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
    echo "${green}WARP2 Split применён.${reset}"
}

toggleWarp2Global() {
    applyWarp2Outbound
    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        jq '(.routing.rules[] | select(.outboundTag == "warp2")) |= (.port = "0-65535" | del(.domain))' \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    done
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
    echo "${green}WARP2 Global: весь трафик через WARP2.${reset}"
}

removeWarp2FromConfigs() {
    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        jq 'del(.outbounds[] | select(.tag=="warp2")) | del(.routing.rules[] | select(.outboundTag=="warp2"))' \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    done
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
}

checkWarp2IP() {
    echo "Реальный IP сервера  : $(getServerIP)"
    local warp1_ip
    warp1_ip=$(curl -s --connect-timeout 8 -x socks5://127.0.0.1:40000 https://api.ipify.org 2>/dev/null || echo "Недоступен")
    echo "IP через WARP1       : $warp1_ip"
    echo "Проверка через WARP2..."
    local ip
    ip=$(curl -s --connect-timeout 15 -x socks5://127.0.0.1:${WARP2_PORT} https://api.ipify.org 2>/dev/null || echo "Недоступен")
    echo "IP через WARP2       : $ip"
}

removeWarp2() {
    echo -e "${red}Удалить WARP2? (y/n)${reset}"
    read -r confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop xray-warp2 "$WARP2_SERVICE" 2>/dev/null || true
        systemctl disable xray-warp2 "$WARP2_SERVICE" 2>/dev/null || true
        rm -f "$WARP2_XRAY_SERVICE" "$WARP2_XRAY_CONF" "$WARP2_WG_CONF" "$warp2DomainsFile"
        systemctl daemon-reload
        removeWarp2FromConfigs
        echo "${green}WARP2 удалён.${reset}"
    fi
}

installWarp2() {
    echo -e "${cyan}=== Установка WARP-in-WARP ===${reset}"
    echo -e "${yellow}Требуется: первый WARP должен быть активен (порт 40000).${reset}"
    echo ""

    # Проверяем первый WARP
    if ! curl -s --connect-timeout 5 -x socks5://127.0.0.1:40000 https://api.ipify.org &>/dev/null; then
        echo "${red}Первый WARP недоступен на порту 40000. Сначала настройте WARP (пункт 10 главного меню).${reset}"
        return 1
    fi
    echo "${green}Первый WARP активен.${reset}"

    installWireGuard || return 1
    installWgcf || return 1
    generateWarp2Config || return 1
    setupWarp2ProxyService
    startWarp2
    applyWarp2Domains

    echo -e "\n${green}WARP-in-WARP установлен!${reset}"
    echo "Добавьте домены в список (пункт 3) для Split режима."
    echo "${yellow}Примечание: IP будет другим Cloudflare адресом — страну выбрать нельзя.${reset}"
}

manageWarp2() {
    set +e
    while true; do
        clear
        echo -e "${cyan}=== Управление WARP-in-WARP ===${reset}"
        echo -e "Статус: $(getWarp2Status)"
        echo ""
        if [ -f "$WARP2_WG_CONF" ]; then
            echo -e "  WireGuard: warp2 интерфейс"
            echo -e "  SOCKS5:    127.0.0.1:$WARP2_PORT"
            [ -f "$warp2DomainsFile" ] && echo -e "  Доменов:   $(wc -l < "$warp2DomainsFile")"
        fi
        echo ""
        echo -e "${green}1.${reset} Установить WARP2"
        echo -e "${green}2.${reset} Переключить режим (Global/Split)"
        echo -e "${green}3.${reset} Добавить домен в список"
        echo -e "${green}4.${reset} Удалить домен из списка"
        echo -e "${green}5.${reset} Редактировать список доменов (Nano)"
        echo -e "${green}6.${reset} Проверить IP (Real / WARP1 / WARP2)"
        echo -e "${green}7.${reset} Перезапустить"
        echo -e "${green}8.${reset} Логи WireGuard"
        echo -e "${green}9.${reset} Логи Xray-WARP2"
        echo -e "${green}10.${reset} Удалить WARP2"
        echo -e "${green}0.${reset} Назад"
        echo ""
        read -rp "Выберите: " choice
        case $choice in
            1)  installWarp2 ;;
            2)
                [ ! -f "$WARP2_WG_CONF" ] && { echo "${red}Сначала установите WARP2 (п.1)${reset}"; read -r; continue; }
                echo "1) Global — весь трафик через WARP2"
                echo "2) Split — только список доменов"
                read -rp "Выбор: " mode
                case "$mode" in
                    1) toggleWarp2Global ;;
                    2) applyWarp2Domains ;;
                esac
                ;;
            3)
                [ ! -f "$WARP2_WG_CONF" ] && { echo "${red}Сначала установите WARP2 (п.1)${reset}"; read -r; continue; }
                read -rp "Домен (например netflix.com): " domain
                [ -z "$domain" ] && continue
                echo "$domain" >> "$warp2DomainsFile"
                sort -u "$warp2DomainsFile" -o "$warp2DomainsFile"
                applyWarp2Domains
                echo "${green}Домен $domain добавлен.${reset}"
                ;;
            4)
                [ ! -f "$warp2DomainsFile" ] && { echo "Список пуст"; read -r; continue; }
                nl "$warp2DomainsFile"
                read -rp "Номер для удаления: " num
                [[ "$num" =~ ^[0-9]+$ ]] && sed -i "${num}d" "$warp2DomainsFile" && applyWarp2Domains
                ;;
            5)
                [ ! -f "$warp2DomainsFile" ] && touch "$warp2DomainsFile"
                nano "$warp2DomainsFile"
                applyWarp2Domains
                ;;
            6)  checkWarp2IP ;;
            7)
                systemctl restart "$WARP2_SERVICE" xray-warp2 && echo "${green}Перезапущен.${reset}"
                ;;
            8)  journalctl -u "$WARP2_SERVICE" -n 50 --no-pager ;;
            9)  journalctl -u xray-warp2 -n 50 --no-pager ;;
            10) removeWarp2 ;;
            0)  break ;;
        esac
        echo -e "\n${cyan}Нажмите Enter...${reset}"
        read -r
    done
}
