#!/bin/bash
# =================================================================
# security.sh — UFW, BBR, Fail2Ban, WebJail, SSH
# =================================================================

changeSshPort() {
    read -rp "$(msg ssh_new_port)" new_ssh_port
    if ! [[ "$new_ssh_port" =~ ^[0-9]+$ ]] || [ "$new_ssh_port" -lt 1 ] || [ "$new_ssh_port" -gt 65535 ]; then
        echo "${red}$(msg invalid_port)${reset}"; return 1
    fi
    ufw allow "$new_ssh_port"/tcp comment 'SSH'
    sed -i "s/^#\?Port [0-9]*/Port $new_ssh_port/" /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh
    echo "${green}$(msg ssh_changed) $new_ssh_port.${reset}"
    echo "${yellow}$(msg ssh_close_old)${reset}"
}

enableBBR() {
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        echo "${yellow}$(msg bbr_active)${reset}"; return
    fi
    grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    grep -q "default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    sysctl -p
    echo "${green}$(msg bbr_enabled)${reset}"
}

setupFail2Ban() {
    echo -e "${cyan}$(msg f2b_setup)${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS
    ${PACKAGE_MANAGEMENT_INSTALL} "fail2ban" &>/dev/null

    local ssh_port
    ssh_port=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -1)
    ssh_port="${ssh_port:-22}"

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 2h
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
port     = $ssh_port
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 24h
EOF
    systemctl restart fail2ban && systemctl enable fail2ban
    echo "${green}$(msg f2b_ok) $ssh_port).${reset}"
}

setupWebJail() {
    echo -e "${cyan}$(msg webjail_setup)${reset}"
    [ ! -f /etc/fail2ban/jail.local ] && setupFail2Ban

    cat > /etc/fail2ban/filter.d/nginx-probe.conf << 'EOF'
[Definition]
failregex = ^<HOST> - .* "(GET|POST|HEAD) .*(\.php|wp-login|admin|\.env|\.git|config\.js|setup\.cgi|xmlrpc).*" (400|403|404|405) \d+
ignoreregex = ^<HOST> - .* "(GET|POST) /favicon.ico.*"
EOF

    if ! grep -q "\[nginx-probe\]" /etc/fail2ban/jail.local; then
        cat >> /etc/fail2ban/jail.local << 'EOF'

[nginx-probe]
enabled  = true
port     = http,https
filter   = nginx-probe
logpath  = /var/log/nginx/access.log
maxretry = 5
bantime  = 24h
EOF
    fi
    systemctl restart fail2ban
    echo "${green}$(msg webjail_ok)${reset}"
}

manageUFW() {
    while true; do
        clear
        echo -e "${cyan}$(msg ufw_title)${reset}"
        echo ""
        ufw status verbose 2>/dev/null || echo "$(msg ufw_inactive)"
        echo ""
        echo -e "${green}1.${reset} $(msg ufw_open_port)"
        echo -e "${green}2.${reset} $(msg ufw_close_port)"
        echo -e "${green}3.${reset} $(msg ufw_enable)"
        echo -e "${green}4.${reset} $(msg ufw_disable)"
        echo -e "${green}5.${reset} $(msg ufw_reset)"
        echo -e "${green}0.${reset} $(msg back)"
        read -rp "$(msg choose)" choice
        case $choice in
            1)
                read -rp "$(msg ufw_port_prompt)" port
                read -rp "$(msg ufw_proto_prompt)" proto
                [ "$proto" = "any" ] && proto=""
                [ -n "$port" ] && ufw allow "${port}${proto:+/}${proto}" && echo "${green}$(msg ufw_port_opened) $port${reset}"
                read -r ;;
            2)
                read -rp "$(msg ufw_close_prompt)" port
                [ -n "$port" ] && ufw delete allow "$port" && echo "${green}$(msg ufw_port_closed) $port${reset}"
                read -r ;;
            3) echo "y" | ufw enable && echo "${green}$(msg ufw_enabled)${reset}"; read -r ;;
            4) ufw disable && echo "${green}$(msg ufw_disabled)${reset}"; read -r ;;
            5)
                echo -e "${red}$(msg ufw_reset_confirm) $(msg yes_no)${reset}"
                read -r confirm
                [[ "$confirm" == "y" ]] && ufw --force reset && echo "${green}$(msg ufw_reset_ok)${reset}"
                read -r ;;
            0) break ;;
        esac
    done
}

applySysctl() {
    cat > /etc/sysctl.d/99-xray.conf << 'SYSCTL'
net.ipv4.icmp_echo_ignore_all = 1
net.ipv6.icmp.echo_ignore_all = 1
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSCTL
    sysctl --system &>/dev/null
    sysctl -p /etc/sysctl.d/99-xray.conf &>/dev/null
    echo "${green}$(msg sysctl_ok)${reset}"
}
