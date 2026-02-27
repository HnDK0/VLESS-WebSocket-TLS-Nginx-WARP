#!/bin/bash
# =================================================================
# nginx.sh — Nginx конфиг, CDN, SSL сертификаты
# =================================================================

setNginxCert() {
    [ ! -d '/etc/nginx/cert' ] && mkdir -p '/etc/nginx/cert'
    if [ ! -f /etc/nginx/cert/default.crt ]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout /etc/nginx/cert/default.key \
            -out /etc/nginx/cert/default.crt \
            -subj "/CN=localhost" &>/dev/null
    fi
}

writeNginxConfig() {
    local xrayPort="$1"
    local domain="$2"
    local proxyUrl="$3"
    local wsPath="$4"

    local proxy_host
    proxy_host=$(echo "$proxyUrl" | sed 's|https://||;s|http://||;s|/.*||')

    setNginxCert

    cat > /etc/nginx/nginx.conf << 'NGINXMAIN'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    server_tokens off;
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/xml+rss;
    include /etc/nginx/conf.d/*.conf;
}
NGINXMAIN

    cat > /etc/nginx/conf.d/default.conf << 'DEFAULTCONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl default_server;
    ssl_certificate     /etc/nginx/cert/default.crt;
    ssl_certificate_key /etc/nginx/cert/default.key;
    server_name _;
    return 444;
}
DEFAULTCONF

    cat > "$nginxPath" << EOF
server {
    listen 443 ssl http2;
    server_name $domain;

    ssl_certificate     /etc/nginx/cert/cert.pem;
    ssl_certificate_key /etc/nginx/cert/cert.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    # Буферизация для WebSocket
    proxy_buffering off;
    proxy_buffer_size 4k;

    location $wsPath {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:$xrayPort;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_connect_timeout 10s;
    }

    location / {
        proxy_pass $proxyUrl;
        proxy_set_header Host $proxy_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_ssl_server_name on;
        proxy_read_timeout 60s;
    }

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;
}
EOF
}

setupCloudflareIPs() {
    echo -e "${cyan}$(msg cf_ips_setup)${reset}"
    local tmp_r tmp_w
    tmp_r=$(mktemp) && tmp_w=$(mktemp) || return 1
    trap 'rm -f "$tmp_r" "$tmp_w"' RETURN

    cat > "$tmp_r" << 'HDR'
# Cloudflare real IP restore
HDR
    cat > "$tmp_w" << 'GEOHDR'
# Cloudflare IP whitelist
geo $realip_remote_addr $cloudflare_ip {
    default 0;
GEOHDR

    local ok=0
    for t in v4 v6; do
        local result
        result=$(curl -fsSL --connect-timeout 10 "https://www.cloudflare.com/ips-$t" 2>/dev/null) || continue
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            echo "set_real_ip_from $ip;" >> "$tmp_r"
            echo "    $ip 1;" >> "$tmp_w"
            ok=1
        done < <(echo "$result" | grep -E '^[0-9a-fA-F:.]+(/[0-9]+)?$')
    done

    [ "$ok" -eq 0 ] && { echo "${red}$(msg cf_ips_fail)${reset}"; return 1; }

    echo "real_ip_header CF-Connecting-IP;" >> "$tmp_r"
    echo "real_ip_recursive on;" >> "$tmp_r"
    echo "}" >> "$tmp_w"

    mkdir -p /etc/nginx/conf.d
    mv -f "$tmp_r" /etc/nginx/conf.d/cloudflare_real_ips.conf
    mv -f "$tmp_w" /etc/nginx/conf.d/cloudflare_whitelist.conf

    for inc in cloudflare_real_ips cloudflare_whitelist; do
        if ! grep -q "${inc}" /etc/nginx/nginx.conf 2>/dev/null; then
            sed -i "/^http {/a\\    include /etc/nginx/conf.d/${inc}.conf;" /etc/nginx/nginx.conf
        fi
    done

    nginx -t 2>/dev/null || { echo "${red}$(msg nginx_syntax_err)${reset}"; nginx -t; return 1; }
    echo "${green}$(msg cf_ips_ok)${reset}"
}

toggleCdnMode() {
    if [ -f /etc/nginx/conf.d/cloudflare_whitelist.conf ]; then
        echo -e "${yellow}$(msg cdn_disable_confirm) $(msg yes_no)${reset}"
        read -r confirm
        if [[ "$confirm" == "y" ]]; then
            rm -f /etc/nginx/conf.d/cloudflare_whitelist.conf
            rm -f /etc/nginx/conf.d/cloudflare_real_ips.conf
            sed -i '/cloudflare_real_ips\|cloudflare_whitelist/d' /etc/nginx/nginx.conf 2>/dev/null || true
            sed -i '/cloudflare_ip.*!=.*1/d' "$nginxPath" 2>/dev/null || true
            nginx -t && systemctl reload nginx
            echo "${green}$(msg cdn_disabled)${reset}"
        fi
    else
        echo -e "${cyan}$(msg cdn_enabling)${reset}"
        setupCloudflareIPs || return 1
        local wsPath
        wsPath=$(jq -r ".inbounds[0].streamSettings.wsSettings.path" "$configPath" 2>/dev/null)
        if [ -n "$wsPath" ] && [ "$wsPath" != "null" ]; then
            if ! grep -q "cloudflare_ip" "$nginxPath" 2>/dev/null; then
                python3 - "$nginxPath" "$wsPath" << 'PYEOF'
import sys, re
path, wspath = sys.argv[1], sys.argv[2]
with open(path, 'r') as f: content = f.read()
cf_check = '    if ($cloudflare_ip != 1) { return 444; }\n\n'
pattern = r'(\s+location ' + re.escape(wspath) + r'\s*\{)'
new_content = re.sub(pattern, cf_check + r'\1', content, count=1)
with open(path, 'w') as f: f.write(new_content)
PYEOF
            fi
        fi
        nginx -t || { echo "${red}$(msg nginx_syntax_err)${reset}"; nginx -t; return 1; }
        systemctl reload nginx
        echo "${green}$(msg cdn_enabled)${reset}"
    fi
}

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
    if [[ -z "${userDomain:-}" ]]; then
        read -rp "$(msg ssl_enter_domain)" userDomain
    fi
    [ -z "$userDomain" ] && { echo "${red}$(msg ssl_domain_empty)${reset}"; return 1; }

    echo -e "\n${cyan}$(msg ssl_method)${reset}"
    echo "$(msg ssl_method_1)"
    echo "$(msg ssl_method_2)"
    read -rp "$(msg ssl_your_choice)" cert_method

    installPackage "socat" || true
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl -fsSL https://get.acme.sh | sh -s email="acme@${userDomain}"
    fi

    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    if [ "$cert_method" == "1" ]; then
        [ -f "$cf_key_file" ] && source "$cf_key_file"
        if [[ -z "${CF_Email:-}" || -z "${CF_Key:-}" ]]; then
            read -rp "$(msg ssl_cf_email)" CF_Email
            read -rp "$(msg ssl_cf_key)" CF_Key
            printf "export CF_Email='%s'\nexport CF_Key='%s'\n" "$CF_Email" "$CF_Key" > "$cf_key_file"
            chmod 600 "$cf_key_file"
        fi
        export CF_Email CF_Key
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$userDomain" --force
    else
        openPort80
        ~/.acme.sh/acme.sh --issue --standalone -d "$userDomain" \
            --pre-hook "/usr/local/bin/vwn open-80" \
            --post-hook "/usr/local/bin/vwn close-80" \
            --force
        closePort80
    fi

    mkdir -p /etc/nginx/cert
    ~/.acme.sh/acme.sh --install-cert -d "$userDomain" \
        --key-file /etc/nginx/cert/cert.key \
        --fullchain-file /etc/nginx/cert/cert.pem \
        --reloadcmd "systemctl reload nginx"

    echo "${green}$(msg ssl_success) $userDomain${reset}"
}
