#!/bin/bash
# =================================================================
# relay.sh — Relay: VLESS/VMess/Trojan/SOCKS внешний outbound
# =================================================================

getRelayStatus() {
    if [ ! -f "$relayConfigFile" ]; then
        echo "${red}OFF${reset}"; return
    fi
    source "$relayConfigFile"
    # Определяем режим по конфигу Xray
    local mode="маршрут OFF"
    if [ -f "$configPath" ]; then
        local relay_rule
        relay_rule=$(jq -r '.routing.rules[] | select(.outboundTag=="relay") | if .port == "0-65535" then "Global" elif (.domain | length) > 0 then "Split" else "OFF" end' "$configPath" 2>/dev/null | head -1)
        [ -n "$relay_rule" ] && mode="$relay_rule"
    fi
    case "$mode" in
        Global) echo "${green}ON | Global ($RELAY_PROTOCOL://$RELAY_HOST:$RELAY_PORT)${reset}" ;;
        Split)  echo "${green}ON | Split ($RELAY_PROTOCOL://$RELAY_HOST:$RELAY_PORT)${reset}" ;;
        *)      echo "${yellow}ON | $(msg mode_off) ($RELAY_PROTOCOL://$RELAY_HOST:$RELAY_PORT)${reset}" ;;
    esac
}

parseRelayUrl() {
    local url="$1"
    local protocol host port uuid security sni pbk sid path ws_host net_type

    protocol=$(echo "$url" | grep -oP "^[a-z0-9]+")

    case "$protocol" in
        vless|trojan)
            uuid=$(echo "$url" | grep -oP "(?<=://)[^@]+")
            host=$(echo "$url" | grep -oP "(?<=@)[^:@]+")
            port=$(echo "$url" | grep -oP ":[0-9]+" | grep -oP "[0-9]+" | head -1)
            security=$(echo "$url" | grep -oP "(?<=security=)[^&#]+")
            sni=$(echo "$url" | grep -oP "(?<=sni=)[^&#]+")
            pbk=$(echo "$url" | grep -oP "(?<=pbk=)[^&#]+")
            sid=$(echo "$url" | grep -oP "(?<=sid=)[^&#]+")
            net_type=$(echo "$url" | grep -oP "(?<=type=)[^&#]+")
            path=$(python3 -c "import urllib.parse,re; m=re.search(r'path=([^&#]+)', '$url'); print(urllib.parse.unquote(m.group(1))) if m else print('/')" 2>/dev/null)
            ws_host=$(echo "$url" | grep -oP "(?<=host=)[^&#]+")
            ;;
        socks5|socks)
            protocol="socks"
            host=$(echo "$url" | grep -oP "(?<=://)[^:@/]+" | head -1)
            port=$(echo "$url" | grep -oP "(?<=:)[0-9]+(?=$|/|#)" | tail -1)
            uuid=""; security="none"; net_type="tcp"
            ;;
        vmess)
            local b64 json
            b64=$(echo "$url" | sed 's|vmess://||')
            json=$(echo "$b64" | base64 -d 2>/dev/null)
            host=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('add',''))" 2>/dev/null)
            port=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('port',''))" 2>/dev/null)
            uuid=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
            sni=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sni',''))" 2>/dev/null)
            net_type=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('net','tcp'))" 2>/dev/null)
            path=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('path','/'))" 2>/dev/null)
            ws_host=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('host',''))" 2>/dev/null)
            security=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tls','none'))" 2>/dev/null)
            ;;
        *)
            echo "${red}$(msg relay_unknown_proto): $protocol${reset}"; return 1 ;;
    esac

    [ -z "$host" ] || [ -z "$port" ] && { echo "${red}$(msg relay_parse_fail)${reset}"; return 1; }

    cat > "$relayConfigFile" << RELAYEOF
RELAY_PROTOCOL=${protocol}
RELAY_HOST=${host}
RELAY_PORT=${port}
RELAY_UUID=${uuid}
RELAY_SECURITY=${security:-none}
RELAY_SNI=${sni:-}
RELAY_PBK=${pbk:-}
RELAY_SID=${sid:-}
RELAY_NET=${net_type:-tcp}
RELAY_PATH=${path:-/}
RELAY_WS_HOST=${ws_host:-${host}}
RELAYEOF
    echo "${green}$(msg relay_configured): $protocol://$host:$port${reset}"
}

buildRelayOutbound() {
    [ ! -f "$relayConfigFile" ] && return 1
    source "$relayConfigFile"

    local stream_block=""
    if [ "$RELAY_PROTOCOL" != "socks" ]; then
        case "$RELAY_NET" in
            ws)
                stream_block=", \"streamSettings\": {\"network\": \"ws\", \"security\": \"${RELAY_SECURITY}\", \"wsSettings\": {\"path\": \"${RELAY_PATH}\", \"headers\": {\"Host\": \"${RELAY_WS_HOST}\"}}, \"tlsSettings\": {\"serverName\": \"${RELAY_SNI}\", \"allowInsecure\": false}}"
                ;;
            tcp)
                if [ "$RELAY_SECURITY" = "reality" ]; then
                    stream_block=", \"streamSettings\": {\"network\": \"tcp\", \"security\": \"reality\", \"realitySettings\": {\"serverName\": \"${RELAY_SNI}\", \"publicKey\": \"${RELAY_PBK}\", \"shortId\": \"${RELAY_SID}\", \"fingerprint\": \"chrome\"}}"
                else
                    stream_block=", \"streamSettings\": {\"network\": \"tcp\", \"security\": \"${RELAY_SECURITY}\"}"
                fi
                ;;
            *)
                stream_block=", \"streamSettings\": {\"network\": \"${RELAY_NET}\", \"security\": \"${RELAY_SECURITY}\"}"
                ;;
        esac
    fi

    if [ "$RELAY_PROTOCOL" = "socks" ]; then
        echo "{\"tag\": \"relay\", \"protocol\": \"socks\", \"settings\": {\"servers\": [{\"address\": \"${RELAY_HOST}\", \"port\": ${RELAY_PORT}}]}}"
    elif [ "$RELAY_PROTOCOL" = "vmess" ]; then
        echo "{\"tag\": \"relay\", \"protocol\": \"vmess\", \"settings\": {\"vnext\": [{\"address\": \"${RELAY_HOST}\", \"port\": ${RELAY_PORT}, \"users\": [{\"id\": \"${RELAY_UUID}\", \"alterId\": 0, \"security\": \"auto\"}]}]}${stream_block}}"
    else
        echo "{\"tag\": \"relay\", \"protocol\": \"${RELAY_PROTOCOL}\", \"settings\": {\"vnext\": [{\"address\": \"${RELAY_HOST}\", \"port\": ${RELAY_PORT}, \"users\": [{\"id\": \"${RELAY_UUID}\", \"encryption\": \"none\", \"flow\": \"\"}]}]}${stream_block}}"
    fi
}

applyRelayToConfigs() {
    [ ! -f "$relayConfigFile" ] && { echo "${red}$(msg relay_not_configured)${reset}"; return 1; }
    local relay_outbound
    relay_outbound=$(buildRelayOutbound) || return 1

    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        local has_relay
        has_relay=$(jq '.outbounds[] | select(.tag=="relay")' "$cfg" 2>/dev/null)
        if [ -z "$has_relay" ]; then
            jq --argjson ob "$relay_outbound" '.outbounds += [$ob]' \
                "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
        else
            jq --argjson ob "$relay_outbound" '(.outbounds[] | select(.tag=="relay")) |= $ob' \
                "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
        fi
        local has_rule
        has_rule=$(jq '.routing.rules[] | select(.outboundTag=="relay")' "$cfg" 2>/dev/null)
        if [ -z "$has_rule" ]; then
            jq '.routing.rules = [.routing.rules[0]] + [{"type":"field","domain":[],"outboundTag":"relay"}] + .routing.rules[1:]' \
                "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
        fi
    done
}

applyRelayDomains() {
    [ ! -f "$relayConfigFile" ] && { echo "${red}$(msg relay_not_configured)${reset}"; return 1; }
    [ ! -f "$relayDomainsFile" ] && touch "$relayDomainsFile"
    local domains_json
    domains_json=$(awk 'NF {printf "\"domain:%s\",", $1}' "$relayDomainsFile" | sed 's/,$//')
    applyRelayToConfigs || return 1
    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        jq "(.routing.rules[] | select(.outboundTag == \"relay\")) |= (.domain = [$domains_json] | del(.port))" \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    done
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
    echo "${green}$(msg relay_split_ok)${reset}"
}

toggleRelayGlobal() {
    applyRelayToConfigs || return 1
    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        jq '(.routing.rules[] | select(.outboundTag == "relay")) |= (.port = "0-65535" | del(.domain))' \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    done
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
    echo "${green}$(msg relay_global_ok)${reset}"
}

removeRelayFromConfigs() {
    for cfg in "$configPath" "$realityConfigPath"; do
        [ -f "$cfg" ] || continue
        jq 'del(.outbounds[] | select(.tag=="relay")) | del(.routing.rules[] | select(.outboundTag=="relay"))' \
            "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    done
    systemctl restart xray 2>/dev/null || true
    systemctl restart xray-reality 2>/dev/null || true
}

checkRelayIP() {
    [ ! -f "$relayConfigFile" ] && { echo "${red}$(msg relay_not_configured)${reset}"; return 1; }
    source "$relayConfigFile"
    echo "$(msg relay_real_ip) : $(getServerIP)"
    echo "$(msg relay_checking)"

    local relay_ip
    if [ "$RELAY_PROTOCOL" = "socks" ]; then
        relay_ip=$(curl -s --connect-timeout 8 -x "socks5://$RELAY_HOST:$RELAY_PORT" https://api.ipify.org 2>/dev/null || echo "$(msg unavailable)")
    else
        local relay_outbound
        relay_outbound=$(buildRelayOutbound)
        cat > /tmp/relay_test.json << TESTEOF
{
    "log": {"loglevel": "none"},
    "inbounds": [{
        "port": 19999, "listen": "127.0.0.1",
        "protocol": "socks",
        "settings": {"auth": "noauth", "udp": false}
    }],
    "outbounds": [$relay_outbound]
}
TESTEOF
        /usr/local/bin/xray run -config /tmp/relay_test.json &>/dev/null &
        local xray_pid=$!
        sleep 3
        relay_ip=$(curl -s --connect-timeout 10 -x socks5://127.0.0.1:19999 https://api.ipify.org 2>/dev/null || echo "$(msg unavailable)")
        kill $xray_pid 2>/dev/null
        rm -f /tmp/relay_test.json
    fi
    echo "$(msg relay_ip) : $relay_ip"
}

manageRelay() {
    set +e
    while true; do
        clear
        echo -e "${cyan}$(msg relay_title)${reset}"
        echo -e "$(msg status): $(getRelayStatus)"
        echo ""
        if [ -f "$relayConfigFile" ]; then
            source "$relayConfigFile"
            echo -e "  $(msg relay_server): ${green}$RELAY_PROTOCOL://$RELAY_HOST:$RELAY_PORT${reset}"
            [ -f "$relayDomainsFile" ] && echo -e "  $(msg domains_count): $(wc -l < "$relayDomainsFile")"
        fi
        echo ""
        echo -e "${green}1.${reset} $(msg relay_setup)"
        echo -e "${green}2.${reset} $(msg relay_mode)"
        echo -e "${green}3.${reset} $(msg relay_add)"
        echo -e "${green}4.${reset} $(msg relay_del)"
        echo -e "${green}5.${reset} $(msg relay_edit)"
        echo -e "${green}6.${reset} $(msg relay_check)"
        echo -e "${green}7.${reset} $(msg relay_remove)"
        echo -e "${green}0.${reset} $(msg back)"
        echo ""
        read -rp "$(msg choose)" choice
        case $choice in
            1)
                echo "$(msg relay_paste_url)"
                read -rp "> " relay_url
                [ -z "$relay_url" ] && continue
                parseRelayUrl "$relay_url" || { read -r; continue; }
                applyRelayDomains
                ;;
            2)
                [ ! -f "$relayConfigFile" ] && { echo "${red}$(msg relay_setup_first)${reset}"; read -r; continue; }
                echo "$(msg relay_mode_1)"
                echo "$(msg relay_mode_2)"
                echo "$(msg relay_mode_3)"
                echo "$(msg back)"
                read -rp "Выбор: " mode
                case "$mode" in
                    1) toggleRelayGlobal ;;
                    2) applyRelayDomains ;;
                    3) removeRelayFromConfigs; echo "${green}$(msg relay_off_ok)${reset}" ;;
                    0) continue ;;
                esac
                ;;
            3)
                [ ! -f "$relayConfigFile" ] && { echo "${red}$(msg relay_setup_first)${reset}"; read -r; continue; }
                read -rp "$(msg relay_domain_prompt)" domain
                [ -z "$domain" ] && continue
                echo "$domain" >> "$relayDomainsFile"
                sort -u "$relayDomainsFile" -o "$relayDomainsFile"
                applyRelayDomains
                echo "${green}$(msg relay_domain_added)${reset}"
                ;;
            4)
                [ ! -f "$relayDomainsFile" ] && { echo "$(msg warp_list_empty)"; read -r; continue; }
                nl "$relayDomainsFile"
                read -rp "$(msg warp_domain_del)" num
                [[ "$num" =~ ^[0-9]+$ ]] && sed -i "${num}d" "$relayDomainsFile" && applyRelayDomains
                ;;
            5)
                [ ! -f "$relayDomainsFile" ] && touch "$relayDomainsFile"
                nano "$relayDomainsFile"
                applyRelayDomains
                ;;
            6) checkRelayIP ;;
            7)
                echo -e "${red}$(msg relay_remove_confirm) $(msg yes_no)${reset}"
                read -r confirm
                if [[ "$confirm" == "y" ]]; then
                    removeRelayFromConfigs
                    rm -f "$relayConfigFile"
                    echo "${green}$(msg relay_removed)${reset}"
                fi
                ;;
            0) break ;;
        esac
        [ "${choice}" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}
