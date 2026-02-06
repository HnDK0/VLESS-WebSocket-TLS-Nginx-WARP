#!/bin/bash

# =================================================================
# Xray VLESS + WebSocket + TLS + Nginx + WARP + CDN
# Улучшенный установщик с поддержкой Cloudflare CDN
# =================================================================

# Цвета для вывода
red=$(tput setaf 1 && tput bold)
green=$(tput setaf 2 && tput bold)
yellow=$(tput setaf 3 && tput bold)
cyan=$(tput setaf 6 && tput bold)
reset=$(tput sgr0)

# Пути
configPath='/usr/local/etc/xray/config.json'
nginxPath='/etc/nginx/conf.d/xray.conf'
cf_key_file="/root/.cloudflare_api"
warpDomainsFile='/usr/local/etc/xray/warp_domains.txt'
script_path=$(readlink -f "$0")

# --- ХУКИ ДЛЯ ACME.SH ---
case "$1" in
    "open-80")
        ufw allow from any to any port 80 proto tcp comment 'ACME temp' &>/dev/null
        exit 0
        ;;
    "close-80")
        ufw status numbered | grep 'ACME temp' | awk -F"[][]" '{print $2}' | sort -rn | while read -r n; do
            echo "y" | ufw delete "$n" &>/dev/null
        done
        exit 0
        ;;
esac

isRoot() {
    if [[ "$EUID" -ne '0' ]]; then
        echo "${red}error: You must run this script as root!${reset}"
        exit 1
    fi
}

identifyOS() {
    if [[ "$(uname)" != 'Linux' ]]; then
        echo "error: This operating system is not supported."
        exit 1
    fi
    if [[ "$(type -P apt)" ]]; then
        PACKAGE_MANAGEMENT_INSTALL='apt -y --no-install-recommends install'
        PACKAGE_MANAGEMENT_REMOVE='apt purge -y'
        PACKAGE_MANAGEMENT_UPDATE='apt update'
    elif [[ "$(type -P dnf)" ]]; then
        PACKAGE_MANAGEMENT_INSTALL='dnf -y install'
        PACKAGE_MANAGEMENT_REMOVE='dnf remove -y'
        PACKAGE_MANAGEMENT_UPDATE='dnf update'
    elif [[ "$(type -P yum)" ]]; then
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
    local package_name="$1"
    local required="${2:-1}"
    if ${PACKAGE_MANAGEMENT_INSTALL} "$package_name"; then
        echo "info: $package_name is installed."
    else
        echo "warn: Installation of $package_name failed, trying to fix..."
        dpkg --configure -a 2>/dev/null
        ${PACKAGE_MANAGEMENT_UPDATE}
        if ${PACKAGE_MANAGEMENT_INSTALL} "$package_name"; then
            echo "info: $package_name is installed after fix."
        else
            echo "${red}error: Installation of $package_name failed.${reset}"
            [[ $required -eq 1 ]] && exit 1
        fi
    fi
}

uninstallPackage() {
    ${PACKAGE_MANAGEMENT_REMOVE} "$1" && echo "info: $1 uninstalled."
}

run_task() {
    local msg="$1"
    shift
    echo -e "\n${yellow}>>> ЗАПУСК: $msg${reset}"
    echo "--------------------------------------------------"
    if eval "$@"; then
        echo "--------------------------------------------------"
        echo -e "[${green} DONE ${reset}] - $msg\n"
    else
        echo "--------------------------------------------------"
        echo -e "[${red} FAIL ${reset}] - $msg"
        exit 1
    fi
}

checkCertExpiry() {
    if [ -f /etc/nginx/cert/cert.pem ]; then
        local expire_date=$(openssl x509 -enddate -noout -in /etc/nginx/cert/cert.pem | cut -d= -f2)
        local expire_epoch=$(date -d "$expire_date" +%s)
        local now_epoch=$(date +%s)
        local days_left=$(( (expire_epoch - now_epoch) / 86400 ))
        
        if [ $days_left -le 0 ]; then
            echo "${red}SSL: EXPIRED!${reset}"
        elif [ $days_left -lt 15 ]; then
            echo "${red}SSL: $days_left days${reset}"
        else
            echo "${green}SSL: OK ($days_left d)${reset}"
        fi
    else
        echo "${red}SSL: MISSING${reset}"
    fi
}

getServiceStatus() {
    if systemctl is-active --quiet "$1"; then
        echo "${green}RUNNING${reset}"
    else
        echo "${red}STOPPED${reset}"
    fi
}

getWarpStatusRaw() {
    if command -v warp-cli &>/dev/null; then
        if warp-cli --accept-tos status 2>/dev/null | grep -q "Connected"; then
            echo "ACTIVE"
        else
            echo "OFF"
        fi
    else
        echo "NOT_INSTALLED"
    fi
}

getBbrStatus() {
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        echo "${green}ON${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

getF2BStatus() {
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo "${green}ON${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

getWebJailStatus() {
    if [ -f /etc/fail2ban/filter.d/nginx-probe.conf ] 2>/dev/null; then
        if fail2ban-client status nginx-probe &>/dev/null; then
            echo "${green}PROTECTED${reset}"
        else
            echo "${yellow}OFF${reset}"
        fi
    else
        echo "${red}NO${reset}"
    fi
}

getCdnStatus() {
    if [ -f /etc/nginx/conf.d/cloudflare_whitelist.conf ] 2>/dev/null; then
        echo "${green}ON${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

setupAlias() {
    local script_full_path=$(readlink -f "$0")
    chmod +x "$script_full_path"
    ln -sf "$script_full_path" /usr/local/bin/vwn
    echo -e "${green}Команда 'vwn' создана!${reset}"
}

generateRandomPath() {
    echo "/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 10)"
}

setNginxCert() {
    [ ! -d '/etc/nginx/cert' ] && mkdir -p '/etc/nginx/cert'
    if [ ! -f /etc/nginx/cert/default.crt ]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout /etc/nginx/cert/default.key -out /etc/nginx/cert/default.crt \
            -subj "/CN=localhost" &>/dev/null
    fi
}

# --- Cloudflare CDN ---
setupCloudflareIPs() {
    echo -e "${cyan}Настройка Cloudflare IP...${reset}"
    local cf_script="/etc/nginx/cloudflareips.sh"
    
    cat > "$cf_script" << 'CFEOF'
#!/bin/bash
[[ $EUID -ne 0 ]] && exec sudo "$0" "$@"
R=/etc/nginx/conf.d; [ -d $R ] || mkdir -p $R || exit 1
tmp_r=$(mktemp) && tmp_w=$(mktemp) || exit 1; trap 'rm -f "$tmp_r" "$tmp_w"' EXIT
echo "geo \$realip_remote_addr \$cloudflare_ip { default 0;" >"$tmp_w"
for t in v4 v6; do
  curl -fsSL --connect-timeout 9 "https://www.cloudflare.com/ips-$t" | \
  grep -E '^[0-9a-fA-F:.]+(/[0-9]+)?$' | while read -r ip; do
    echo "set_real_ip_from $ip;" >>"$tmp_r"
    echo "    $ip 1;" >>"$tmp_w"
  done || { echo "Cloudflare failed $t"; exit 1; }
done
echo "real_ip_header X-Forwarded-For;" >>"$tmp_r"
echo "}" >>"$tmp_w"
mv -f "$tmp_r" "$R/cloudflare_real_ips.conf" && mv -f "$tmp_w" "$R/cloudflare_whitelist.conf"
CFEOF
    
    chmod +x "$cf_script"
    bash "$cf_script" &>/dev/null
    
    # Добавляем include в nginx.conf
    if ! grep -q "cloudflare_whitelist" /etc/nginx/nginx.conf 2>/dev/null; then
        sed -i '/http {/a\    include /etc/nginx/conf.d/cloudflare_whitelist.conf;' /etc/nginx/nginx.conf 2>/dev/null || true
    fi
    
    echo "${green}Cloudflare IPs настроены.${reset}"
}

toggleCdnMode() {
    if [ -f /etc/nginx/conf.d/cloudflare_whitelist.conf ]; then
        echo -e "${yellow}CDN режим активен. Отключить? (y/n)${reset}"
        read -r confirm
        if [[ "$confirm" == "y" ]]; then
            rm -f /etc/nginx/conf.d/cloudflare_whitelist.conf
            rm -f /etc/nginx/conf.d/cloudflare_real_ips.conf
            sed -i '/cloudflare_whitelist/d' /etc/nginx/nginx.conf 2>/dev/null || true
            # Убираем проверку из xray.conf
            sed -i '/cloudflare_ip.*!=.*1/d' $nginxPath 2>/dev/null || true
            systemctl restart nginx
            echo "${green}CDN режим отключен. Прямой доступ разрешен.${reset}"
        fi
    else
        echo -e "${cyan}Включение CDN режима...${reset}"
        setupCloudflareIPs
        # Добавляем проверку в xray.conf
        local wsPath=$(jq -r ".inbounds[0].streamSettings.wsSettings.path" $configPath 2>/dev/null)
        if [ -n "$wsPath" ] && [ "$wsPath" != "null" ]; then
            # Вставляем проверку перед location ws
            sed -i "/location $wsPath/i\\        if (\\\$cloudflare_ip != 1) { return 444; }" $nginxPath 2>/dev/null || true
        fi
        systemctl restart nginx
        echo "${green}CDN режим включен! Только Cloudflare IP имеют доступ.${reset}"
    fi
}

# --- WARP ---
applyWarpDomains() {
    [ ! -f "$warpDomainsFile" ] && echo -e "openai.com\nchatgpt.com\ncloudflare.com" > "$warpDomainsFile"
    local domains_json=$(awk 'NF {printf "\"domain:%s\",", $1}' "$warpDomainsFile" | sed 's/,$//')
    jq "(.routing.rules[] | select(.outboundTag == \"warp\")) |= (.domain = [$domains_json] | del(.port))" $configPath > 'config.tmp' && mv 'config.tmp' $configPath
    systemctl restart xray
}


toggleWarpMode() {
    echo "Выберите режим работы WARP:"
    echo "1) Весь трафик через WARP (Global)"
    echo "2) Только выбранные домены (Split)"
    read -rp "Ваш выбор: " warp_mode
    
    if [ "$warp_mode" == "1" ]; then
        jq '(.routing.rules[] | select(.outboundTag == "warp")) |= (.port = "0-65535" | del(.domain))' $configPath > 'config.tmp' && mv 'config.tmp' $configPath
        echo "${green}Включен режим: Global (Весь трафик через WARP)${reset}"
    elif [ "$warp_mode" == "2" ]; then
        applyWarpDomains
        echo "${green}Включен режим: Split (Только список доменов через WARP)${reset}"
    else
        echo "${red}Отмена.${reset}"
    fi
    systemctl restart xray
}

checkWarpStatus() {
    echo "--------------------------------------------------"
    local real_ip=$(curl -s --connect-timeout 5 ip.sb || echo "Error")
    local warp_ip=$(curl -s --connect-timeout 5 -x socks5://127.0.0.1:40000 ip.sb 2>/dev/null || echo "Error/Offline")
    echo "Реальный IP сервера: $real_ip"
    echo "IP через WARP SOCKS: $warp_ip"
    echo "--------------------------------------------------"
}

addDomainToWarpProxy() {
    read -rp "Домен для WARP (например, netflix.com): " domain
    [ ! -f "$warpDomainsFile" ] && touch "$warpDomainsFile"
    if [ -n "$domain" ] && ! grep -q "^$domain$" "$warpDomainsFile"; then
        echo "$domain" >> "$warpDomainsFile"
        sort -u "$warpDomainsFile" -o "$warpDomainsFile"
        applyWarpDomains
        echo "${green}Домен $domain добавлен.${reset}"
    fi
}

deleteDomainFromWarpProxy() {
    if [ ! -f "$warpDomainsFile" ]; then echo "Список пуст"; return; fi
    echo "Текущие домены в WARP:"
    nl "$warpDomainsFile"
    read -rp "Введите номер для удаления: " num
    if [[ "$num" =~ ^[0-9]+$ ]]; then
        sed -i "${num}d" "$warpDomainsFile"
        applyWarpDomains
        echo "${green}Домен удален.${reset}"
    fi
}

# --- SSL ---
openPort80() {
    ufw status | grep -q inactive && return
    ufw allow from any to any port 80 proto tcp comment 'ACME temp'
}

closePort80() {
    ufw status | grep -q inactive && return
    ufw status numbered | grep 'ACME temp' | awk -F"[][]" '{print $2}' | sort -rn | while read -r n; do
        echo "y" | ufw delete "$n"
    done
}

configCert() {
    if [[ -z "$userDomain" ]]; then
        read -rp "Введите домен для выпуска SSL: " userDomain
    fi

    echo -e "\n${cyan}Метод SSL:${reset}"
    echo "1) Cloudflare DNS API (порт 80 закрыт)"
    echo "2) Standalone (временно открыть порт 80)"
    read -rp "Ваш выбор: " cert_method

    installPackage "socat"
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl https://get.acme.sh | sh -s email=acme@$(hostname).com
    fi
    
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    if [ "$cert_method" == "1" ]; then
        [ -f "$cf_key_file" ] && source "$cf_key_file"
        if [[ -z "$CF_Email" || -z "$CF_Key" ]]; then
            echo "${green}Настройка Cloudflare DNS API:${reset}"
            read -rp "Cloudflare Email: " CF_Email
            read -rp "Cloudflare Global API Key: " CF_Key
            echo "export CF_Email='$CF_Email'" > "$cf_key_file"
            echo "export CF_Key='$CF_Key'" >> "$cf_key_file"
            chmod 600 "$cf_key_file"
        fi
        export CF_Email="$CF_Email"
        export CF_Key="$CF_Key"
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$userDomain" --force
    else
        openPort80
        ~/.acme.sh/acme.sh --issue --standalone -d "$userDomain" \
            --pre-hook "vwn open-80" --post-hook "vwn close-80" --force
        closePort80
    fi
    
    ~/.acme.sh/acme.sh --install-cert -d "$userDomain" \
        --key-file /etc/nginx/cert/cert.key \
        --fullchain-file /etc/nginx/cert/cert.pem \
        --reloadcmd "systemctl restart nginx"
    
    echo "${green}SSL успешно настроен для $userDomain${reset}"
}

# --- Установка компонентов ---
installXray() {
    command -v xray &>/dev/null && return
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

installWarp() {
    command -v warp-cli &>/dev/null && return
    if command -v apt &>/dev/null; then
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
    else
        curl -fsSl https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | tee /etc/yum.repos.d/cloudflare-warp.repo
    fi
    ${PACKAGE_MANAGEMENT_UPDATE}
    installPackage "cloudflare-warp"
}

configWarp() {
    systemctl enable warp-svc && systemctl restart warp-svc
    sleep 3
    
    # Повторные попытки регистрации
    local attempts=0
    while [ $attempts -lt 3 ]; do
        warp-cli --accept-tos registration new && break
        attempts=$((attempts + 1))
        sleep 2
    done
    
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos connect
    sleep 3
    
    # Проверка что SOCKS5 работает
    local warp_check=$(curl -s --connect-timeout 5 -x socks5://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace/ 2>/dev/null | grep 'warp=')
    if [[ "$warp_check" == *"warp=on"* ]] || [[ "$warp_check" == *"warp=plus"* ]]; then
        echo "${green}WARP успешно подключен!${reset}"
    else
        echo "${yellow}WARP запущен, но проверка не удалась. Продолжаем...${reset}"
    fi
    echo "WARP Status: $warp_check"
}

# --- Конфиги ---
writeXrayConfig() {
    local xrayPort=$1
    local wsPath=$2
    mkdir -p /usr/local/etc/xray /var/log/xray
    
    cat > $configPath <<EOF
{
    "log": {
        "access": "/var/log/xray/access.log",
        "error": "/var/log/xray/error.log",
        "loglevel": "warning"
    },
    "inbounds": [{
        "port": $xrayPort,
        "listen": "127.0.0.1",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$(cat /proc/sys/kernel/random/uuid)"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "ws",
            "wsSettings": {"path": "$wsPath"}
        }
    }],
    "outbounds": [
        {"tag": "free", "protocol": "freedom"},
        {"tag": "warp", "protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": 40000}]}}
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {"type": "field", "domain": ["domain:openai.com", "domain:chatgpt.com", "domain:oaistatic.com", "domain:oaiusercontent.com"], "outboundTag": "warp"},
            {"type": "field", "port": "0-65535", "outboundTag": "free"}
        ]
    }
}
EOF
}

writeNginxConfig() {
    local xrayPort=$1
    local domain=$2
    local proxyUrl=$3
    local wsPath=$4
    setNginxCert
    
    cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events { worker_connections 1024; }

http {
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" \$status \$body_bytes_sent';
    access_log /var/log/nginx/access.log main;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include /etc/nginx/conf.d/*.conf;
}
EOF

    cat > /etc/nginx/conf.d/default.conf <<EOF
server {
    listen 80 default_server;
    listen 443 ssl default_server;
    ssl_certificate /etc/nginx/cert/default.crt;
    ssl_certificate_key /etc/nginx/cert/default.key;
    server_name _;
    return 444;
}
EOF

    cat > $nginxPath <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $domain;

    ssl_certificate /etc/nginx/cert/cert.pem;
    ssl_certificate_key /etc/nginx/cert/cert.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location $wsPath {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$xrayPort;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location / {
        proxy_ssl_server_name on;
        proxy_pass $proxyUrl;
    }
}
EOF
}

# --- Информация о конфиге ---
getConfigInfo() {
    xray_uuid=$(jq -r ".inbounds[0].settings.clients[0].id" $configPath 2>/dev/null)
    xray_userDomain=$(grep -m 1 -oP "server_name\s+\K\S+" $nginxPath 2>/dev/null | head -n 1 | tr -d ';')
    [ -z "$xray_userDomain" ] && xray_userDomain=$(curl -s ip.sb 2>/dev/null)
    xray_path=$(jq -r ".inbounds[0].streamSettings.wsSettings.path" $configPath 2>/dev/null)
}

getShareUrl() {
    getConfigInfo
    local encoded_path=$(echo "$xray_path" | sed 's/\//%2F/g')
    echo "vless://$xray_uuid@$xray_userDomain:443?encryption=none&security=tls&sni=$xray_userDomain&type=ws&host=$xray_userDomain&path=$encoded_path#$xray_userDomain"
}

getQrCode() {
    command -v qrencode &>/dev/null || installPackage "qrencode"
    local url=$(getShareUrl)
    qrencode -t ANSI "${url}"
    echo "${green}$url${reset}"
}

# --- Изменение параметров ---
modifyXrayUUID() {
    local new_uuid=$(cat /proc/sys/kernel/random/uuid)
    jq ".inbounds[0].settings.clients[0].id = \"$new_uuid\"" $configPath > 'config.tmp' && mv 'config.tmp' $configPath
    systemctl restart xray
    echo "${green}New UUID: $new_uuid${reset}"
}

modifyXrayPort() {
    local oldPort=$(jq ".inbounds[0].port" $configPath)
    read -rp "New Xray Port: " xrayPort
    jq ".inbounds[0].port = $xrayPort" $configPath > 'config.tmp' && mv 'config.tmp' $configPath
    sed -i "s/127.0.0.1:${oldPort}/127.0.0.1:${xrayPort}/" $nginxPath
    systemctl restart xray nginx
}

modifyWsPath() {
    local oldPath=$(jq -r ".inbounds[0].streamSettings.wsSettings.path" $configPath)
    read -rp "New Path (start with /, or Enter for random): " wsPath
    [ -z "$wsPath" ] && wsPath=$(generateRandomPath)
    [[ ! $wsPath =~ ^/ ]] && wsPath="/$wsPath"
    
    sed -i "s@location $oldPath@location $wsPath@" $nginxPath
    jq ".inbounds[0].streamSettings.wsSettings.path = \"$wsPath\"" $configPath > 'config.tmp' && mv 'config.tmp' $configPath
    systemctl restart xray nginx
    echo "${green}New Path: $wsPath${reset}"
}

modifyProxyPassUrl() {
    read -rp "New Proxy Pass URL (e.g. https://google.com): " newUrl
    local oldUrl=$(grep "proxy_pass" $nginxPath | grep -v "127.0.0.1" | awk '{print $2}' | tr -d ';')
    sed -i "s@$oldUrl@$newUrl@" $nginxPath
    systemctl restart nginx
}

modifyDomain() {
    getConfigInfo
    echo "Текущий домен: $xray_userDomain"
    read -rp "Введите новый домен: " new_domain
    [ -z "$new_domain" ] && return
    sed -i "s/server_name $xray_userDomain;/server_name $new_domain;/" $nginxPath
    userDomain=$new_domain
    configCert
    systemctl restart nginx xray
}

# --- Безопасность ---
changeSshPort() {
    echo "${yellow}Не забудьте открыть новый порт в UFW!${reset}"
    read -rp "Введите новый SSH порт: " new_ssh_port
    if [[ "$new_ssh_port" =~ ^[0-9]+$ ]]; then
        sed -i "s/^#\?Port [0-9]*/Port $new_ssh_port/" /etc/ssh/sshd_config
        ufw allow "$new_ssh_port"/tcp 2>/dev/null
        systemctl restart ssh
        echo "${green}Порт SSH изменен на $new_ssh_port.${reset}"
    fi
}

enableBBR() {
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo "${green}BBR включен.${reset}"
    else
        echo "${yellow}BBR уже активен.${reset}"
    fi
}

setupFail2Ban() {
    echo -e "${cyan}Настройка Fail2Ban...${reset}"
    installPackage "fail2ban"
    local ssh_port=$(grep "Port " /etc/ssh/sshd_config | awk '{print $2}' || echo "22")
    
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = $ssh_port
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
EOF
    systemctl restart fail2ban && systemctl enable fail2ban
    echo "${green}Fail2Ban настроен.${reset}"
}

setupWebJail() {
    echo -e "${cyan}Настройка Web-Jail...${reset}"
    [ ! -f /etc/fail2ban/jail.local ] && setupFail2Ban
    
    cat > /etc/fail2ban/filter.d/nginx-probe.conf <<EOF
[Definition]
failregex = ^<HOST>.*GET.*(php|admin|wp-login|config|.env|root|mysql|setup).* 404
            ^<HOST>.*GET.*(\.git|\.php|\.sql).* 404
ignoreregex =
EOF

    cat >> /etc/fail2ban/jail.local <<EOF

[nginx-probe]
enabled = true
port = http,https
filter = nginx-probe
logpath = /var/log/nginx/access.log
maxretry = 2
bantime = 24h
EOF
    systemctl restart fail2ban
    echo "${green}Web-Jail активирован.${reset}"
}

# --- Логи ---
clearLogs() {
    echo -e "${cyan}Очистка логов...${reset}"
    [ -f /var/log/xray/access.log ] && > /var/log/xray/access.log
    [ -f /var/log/xray/error.log ] && > /var/log/xray/error.log
    [ -f /var/log/nginx/access.log ] && > /var/log/nginx/access.log
    [ -f /var/log/nginx/error.log ] && > /var/log/nginx/error.log
    journalctl --vacuum-size=100M &>/dev/null
    echo "${green}Логи очищены.${reset}"
}

setupLogrotate() {
    cat > /etc/logrotate.d/xray <<EOF
/var/log/xray/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
    echo "${green}Авто-ротация логов настроена.${reset}"
}

# --- Автообновление SSL ---
setupSslCron() {
    echo -e "${cyan}Настройка автообновления SSL...${reset}"
    # Создаем cron задачу для acme.sh с хуками (раз в 35 дней)
    local cron_job="0 3 */35 * * root /root/.acme.sh/acme.sh --cron --home /root/.acme.sh --pre-hook 'vwn open-80' --post-hook 'vwn close-80' >> /var/log/acme_cron.log 2>&1"
    
    # Удаляем старые записи acme.sh если есть
    crontab -l 2>/dev/null | grep -v "acme.sh" | crontab - 2>/dev/null
    
    # Добавляем новую
    (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
    
    echo "${green}Автообновление SSL настроено (раз в 35 дней в 3:00).${reset}"
    echo "${cyan}Хуки: open-80 перед обновлением, close-80 после.${reset}"
}

removeSslCron() {
    crontab -l 2>/dev/null | grep -v "acme.sh" | crontab -
    echo "${green}Автообновление SSL отключено.${reset}"
}

checkSslCronStatus() {
    if crontab -l 2>/dev/null | grep -q "acme.sh"; then
        echo "${green}ВКЛЮЧЕНО${reset}"
    else
        echo "${red}ВЫКЛЮЧЕНО${reset}"
    fi
}

manageSslCron() {
    while true; do
        clear
        local status=$(checkSslCronStatus | sed 's/\x1b\[[0-9;]*m//g')
        echo -e "${cyan}=== Управление автообновлением SSL ===${reset}"
        echo -e "Статус: $status"
        echo ""
        echo -e "${green}1.${reset} Включить автообновление (с хуками UFW)"
        echo -e "${green}2.${reset} Выключить автообновление"
        echo -e "${green}3.${reset} Показать текущие cron задачи"
        echo -e "${green}0.${reset} Назад"
        echo ""
        read -rp "Выберите: " choice
        case $choice in
            1) setupSslCron; read -r ;;
            2) removeSslCron; read -r ;;
            3) crontab -l | grep acme.sh || echo "Нет задач acme.sh"; read -r ;;
            0) break ;;
        esac
    done
}

# --- Автоочистка логов ---
setupLogClearCron() {
    echo -e "${cyan}Настройка автоочистки логов...${reset}"
    # Создаем скрипт для очистки
    cat > /usr/local/bin/clear-logs.sh << 'EOF'
#!/bin/bash
[ -f /var/log/xray/access.log ] && > /var/log/xray/access.log
[ -f /var/log/xray/error.log ] && > /var/log/xray/error.log
[ -f /var/log/nginx/access.log ] && > /var/log/nginx/access.log
[ -f /var/log/nginx/error.log ] && > /var/log/nginx/error.log
journalctl --vacuum-size=100M &>/dev/null
EOF
    chmod +x /usr/local/bin/clear-logs.sh
    
    # Добавляем cron задачу (раз в неделю по воскресеньям в 4:00)
    local cron_job="0 4 * * 0 root /usr/local/bin/clear-logs.sh"
    
    # Удаляем старые записи clear-logs если есть
    crontab -l 2>/dev/null | grep -v "clear-logs" | crontab - 2>/dev/null
    
    # Добавляем новую
    (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
    
    echo "${green}Автоочистка логов настроена (раз в неделю, воскресенье 4:00).${reset}"
}

removeLogClearCron() {
    crontab -l 2>/dev/null | grep -v "clear-logs" | crontab -
    rm -f /usr/local/bin/clear-logs.sh
    echo "${green}Автоочистка логов отключена.${reset}"
}

checkLogClearCronStatus() {
    if crontab -l 2>/dev/null | grep -q "clear-logs"; then
        echo "${green}ВКЛЮЧЕНО${reset}"
    else
        echo "${red}ВЫКЛЮЧЕНО${reset}"
    fi
}

manageLogClearCron() {
    while true; do
        clear
        local status=$(checkLogClearCronStatus | sed 's/\x1b\[[0-9;]*m//g')
        echo -e "${cyan}=== Управление автоочисткой логов ===${reset}"
        echo -e "Статус: $status"
        echo ""
        echo -e "${green}1.${reset} Включить автоочистку (раз в неделю)"
        echo -e "${green}2.${reset} Выключить автоочистку"
        echo -e "${green}3.${reset} Показать текущие cron задачи"
        echo -e "${green}0.${reset} Назад"
        echo ""
        read -rp "Выберите: " choice
        case $choice in
            1) setupLogClearCron; read -r ;;
            2) removeLogClearCron; read -r ;;
            3) crontab -l | grep clear-logs || echo "Нет задач очистки логов"; read -r ;;
            0) break ;;
        esac
    done
}

# --- Управление UFW ---
manageUFW() {
    while true; do
        clear
        echo -e "${cyan}=== Управление UFW Firewall ===${reset}"
        echo ""
        ufw status verbose 2>/dev/null || echo "UFW не активен"
        echo ""
        echo -e "${green}1.${reset} Открыть порт"
        echo -e "${green}2.${reset} Закрыть порт"
        echo -e "${green}3.${reset} Включить UFW"
        echo -e "${green}4.${reset} Выключить UFW"
        echo -e "${green}5.${reset} Сбросить UFW (все правила)"
        echo -e "${green}0.${reset} Назад"
        echo ""
        read -rp "Выберите: " choice
        case $choice in
            1)
                read -rp "Введите порт для открытия (например, 8080): " port
                read -rp "Протокол [tcp/udp/both]: " proto
                [[ "$proto" == "both" ]] && proto=""
                [[ -n "$port" ]] && ufw allow ${port}${proto:+/}$proto && echo "${green}Порт $port открыт${reset}"
                read -r
                ;;
            2)
                read -rp "Введите порт для закрытия: " port
                [[ -n "$port" ]] && ufw delete allow $port && echo "${green}Порт $port закрыт${reset}"
                read -r
                ;;
            3) echo "y" | ufw enable && echo "${green}UFW включен${reset}"; read -r ;;
            4) ufw disable && echo "${green}UFW выключен${reset}"; read -r ;;
            5) 
                echo -e "${red}ВНИМАНИЕ: Это удалит ВСЕ правила! Продолжить? (y/n)${reset}"
                read -r confirm
                [[ "$confirm" == "y" ]] && ufw --force reset && echo "${green}UFW сброшен${reset}"
                read -r
                ;;
            0) break ;;
        esac
    done
}

# --- Установка ---
prepareSoftware() {
    identifyOS
    echo "--- [1/3] Подготовка системы ---"
    run_task "Чистка пакетов" "rm -f /var/lib/dpkg/lock* && dpkg --configure -a 2>/dev/null || true"
    run_task "Обновление репозиториев" "${PACKAGE_MANAGEMENT_UPDATE}"
    
    echo "--- [2/3] Установка компонентов ---"
    for p in tar gpg unzip nginx jq nano ufw socat curl qrencode; do
        run_task "Установка $p" installPackage "$p"
    done
    
    run_task "Установка Xray-core" installXray
    run_task "Установка Cloudflare WARP" installWarp

    echo "--- [3/3] Безопасность ---"
    run_task "Настройка UFW (22, 443)" "ufw allow 22/tcp && ufw allow 443/tcp && ufw allow 443/udp && echo 'y' | ufw enable"
    run_task "Защита (Anti-Ping)" "sysctl -w net.ipv4.icmp_echo_ignore_all=1 && sysctl -p &>/dev/null"
}

install() {
    isRoot
    clear
    echo "${green}>>> Установка Xray VLESS + WARP + CDN <<<${reset}"
    prepareSoftware
    
    echo -e "\n${green}--- Настройка параметров ---${reset}"
    read -rp "Введите Домен (vpn.example.com): " userDomain
    read -rp "Порт Xray [16500]: " xrayPort; [ -z "$xrayPort" ] && xrayPort=16500
    wsPath=$(generateRandomPath)
    read -rp "Сайт-заглушка [https://httpbin.org/]: " proxyUrl; [ -z "$proxyUrl" ] && proxyUrl='https://httpbin.org/'
    
    echo -e "\n${green}--- Финализация ---${reset}"
    run_task "Создание конфигов" "writeXrayConfig '$xrayPort' '$wsPath' && writeNginxConfig '$xrayPort' '$userDomain' '$proxyUrl' '$wsPath'"
    run_task "Настройка WARP" configWarp
    run_task "Выпуск SSL сертификата" "userDomain='$userDomain' configCert"
    run_task "Применение правил WARP" applyWarpDomains
    run_task "Настройка ротации логов" setupLogrotate
    run_task "Настройка автоочистки логов" setupLogClearCron
    run_task "Настройка автообновления SSL" setupSslCron
    
    systemctl restart xray nginx
    echo -e "\n${green}Установка завершена!${reset}"
    getQrCode
}

# --- Меню ---
menu() {
    while true; do
        clear
        local s_nginx=$(getServiceStatus nginx | sed 's/\x1b\[[0-9;]*m//g')
        local s_xray=$(getServiceStatus xray | sed 's/\x1b\[[0-9;]*m//g')
        local s_warp=$(getWarpStatusRaw)
        local s_ssl=$(checkCertExpiry | sed 's/\x1b\[[0-9;]*m//g')
        local s_bbr=$(getBbrStatus | sed 's/\x1b\[[0-9;]*m//g')
        local s_f2b=$(getF2BStatus | sed 's/\x1b\[[0-9;]*m//g')
        local s_jail=$(getWebJailStatus | sed 's/\x1b\[[0-9;]*m//g')
        local s_cdn=$(getCdnStatus | sed 's/\x1b\[[0-9;]*m//g')

        echo -e "${cyan}================================================================${reset}"
        echo -e "   ${red}XRAY VLESS + WARP + CDN${reset} | $(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}================================================================${reset}"
        echo -e "  NGINX: $s_nginx  |  XRAY: $s_xray  |  WARP: ${green}$s_warp${reset}"
        echo -e "  $s_ssl  |  BBR: $s_bbr  |  F2B: $s_f2b"
        echo -e "  WebJail: $s_jail  |  CDN: $s_cdn"
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
        echo -e "\t—————————————— UFW, SSL и Logs ————————————"
        echo -e "\t${green}27.${reset} Управление UFW (открыть/закрыть порты)"
        echo -e "\t${green}28.${reset} Управление автообновлением SSL"
        echo -e "\t${green}29.${reset} Управление автоочисткой логов"
        echo -e "\t—————————————— Выход ————————————————————"
        echo -e "\t${green}0.${reset}   Выйти"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        
        read -rp "Выберите пункт: " num
        case $num in
            1) install ;;
            2) getQrCode ;;
            3) modifyXrayUUID ;;
            4) modifyXrayPort ;;
            5) modifyWsPath ;;
            6) modifyProxyPassUrl ;;
            7) getConfigInfo && userDomain=$xray_userDomain && configCert ;;
            8) modifyDomain ;;
            9) toggleCdnMode ;;
            10) toggleWarpMode ;;
            11) addDomainToWarpProxy ;;
            12) deleteDomainFromWarpProxy ;;
            13) nano "$warpDomainsFile" && applyWarpDomains ;;
            14) checkWarpStatus ;;
            15) enableBBR ;;
            16) setupFail2Ban ;;
            17) setupWebJail ;;
            18) changeSshPort ;;
            19) tail -n 50 /var/log/xray/access.log ;;
            20) tail -n 50 /var/log/xray/error.log ;;
            21) tail -n 50 /var/log/nginx/access.log ;;
            22) tail -n 50 /var/log/nginx/error.log ;;
            23) clearLogs ;;
            24) systemctl restart xray nginx warp-svc ;;
            25) bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install ;;
            26) 
                echo -e "${red}Уверены? Удалит Xray, Nginx, WARP и все конфиги! (y/n)${reset}"
                read -r confirm
                if [[ "$confirm" == "y" ]]; then
                    systemctl stop nginx xray warp-svc
                    warp-cli disconnect 2>/dev/null
                    uninstallPackage 'nginx*'
                    uninstallPackage 'cloudflare-warp'
                    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove
                    rm -rf /etc/nginx /usr/local/etc/xray /root/.cloudflare_api "$warpDomainsFile"
                    echo "${green}Удаление завершено.${reset}"
                fi
                ;;
            27) manageUFW ;;
            28) manageSslCron ;;
            29) manageLogClearCron ;;
            0) exit 0 ;;
            *) echo -e "${red}Неверный пункт!${reset}"; sleep 1 ;;
        esac
        echo -e "\n${cyan}Нажмите Enter...${reset}"
        read -r
    done
}

isRoot
setupAlias
menu "$@"
