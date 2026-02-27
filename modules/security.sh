#!/bin/bash
# =================================================================
# security.sh — UFW, BBR, Fail2Ban, WebJail, SSH
# =================================================================

changeSshPort() {
    read -rp "Введите новый SSH порт [22]: " new_ssh_port
    if ! [[ "$new_ssh_port" =~ ^[0-9]+$ ]] || [ "$new_ssh_port" -lt 1 ] || [ "$new_ssh_port" -gt 65535 ]; then
        echo "${red}Некорректный порт.${reset}"; return 1
    fi
    ufw allow "$new_ssh_port"/tcp comment 'SSH'
    sed -i "s/^#\?Port [0-9]*/Port $new_ssh_port/" /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh
    echo "${green}SSH порт изменен на $new_ssh_port.${reset}"
    echo "${yellow}Закройте старый порт: ufw delete allow 22/tcp${reset}"
}

enableBBR() {
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        echo "${yellow}BBR уже активен.${reset}"; return
    fi
    grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    grep -q "default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    sysctl -p
    echo "${green}BBR включен.${reset}"
}

setupFail2Ban() {
    echo -e "${cyan}Настройка Fail2Ban...${reset}"
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
    echo "${green}Fail2Ban настроен (SSH на порту $ssh_port).${reset}"
}

setupWebJail() {
    echo -e "${cyan}Настройка Web-Jail...${reset}"
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
    echo "${green}Web-Jail активирован.${reset}"
}

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
        echo -e "${green}5.${reset} Сбросить UFW"
        echo -e "${green}0.${reset} Назад"
        read -rp "Выберите: " choice
        case $choice in
            1)
                read -rp "Порт: " port
                read -rp "Протокол [tcp/udp/any]: " proto
                [ "$proto" = "any" ] && proto=""
                [ -n "$port" ] && ufw allow "${port}${proto:+/}${proto}" && echo "${green}Порт $port открыт${reset}"
                read -r ;;
            2)
                read -rp "Порт для закрытия: " port
                [ -n "$port" ] && ufw delete allow "$port" && echo "${green}Порт $port закрыт${reset}"
                read -r ;;
            3) echo "y" | ufw enable && echo "${green}UFW включен${reset}"; read -r ;;
            4) ufw disable && echo "${green}UFW выключен${reset}"; read -r ;;
            5)
                echo -e "${red}Удалить ВСЕ правила? (y/n)${reset}"
                read -r confirm
                [[ "$confirm" == "y" ]] && ufw --force reset && echo "${green}UFW сброшен${reset}"
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
    echo "${green}Системные параметры применены (Anti-Ping, IPv6 отключён).${reset}"
}
